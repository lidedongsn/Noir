import Foundation

/// 网络片源：读取经由磁盘块缓存，缺失的块通过 RangeTransport 下载。
///
/// 读取位置即播放位置，从它往后按顺序并行预缓存（距离由 prefetchLimit 限制，nil 为直到末尾）。
/// 读取的数据尚未下载时，该块优先下载并阻塞等待；跳到远处时，取消已不需要的下载。
/// 线程安全：可变状态由 condition 保护。
public final class RemoteByteSource: ByteSource, @unchecked Sendable {
    public let cache: BlockCache
    private let transport: RangeTransport
    private let condition = NSCondition()

    // 以下由 condition 保护
    private var position: Int64 = 0
    /// 正在读取等待的块，优先下载
    private var urgent: Int?
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var prefetchLimit: Int64?
    /// 这部影片最多占用的缓存；超出时先删看过的部分，再删最远的预缓存
    private var budget: Int64?
    private var keepBehind: Int64 = 64 << 20
    /// 片源码率（字节/秒）；已知时，缓存充足后限速预缓存
    private var pace: Double?
    /// 限速时下一块最早开始下载的时刻
    private var nextPacedStart = Date.distantPast
    private var wakeScheduled = false

    /// 往后缓存超过这么多秒后限速
    private static let comfortSeconds = 30.0
    /// 限速后的下载速度为码率的倍数
    private static let pacedRate = 2.0
    private var prefetching = true
    private var concurrency = 3
    private var dataHandler: (@Sendable () -> Void)?
    private var closed = false
    private var lastError: Error?
    /// 最近一次下载失败的块，读取等待该块时据此立即报错，不在没有网络时反复重试
    private var failedBlock: Int?
    /// 下载失败后暂停到此时刻再重试
    private var retryAt = Date.distantPast
    private var meter = RateMeter()

    /// 读取等待数据的最长时间
    private static let readTimeout: TimeInterval = 30

    public var size: Int64? { cache.size }

    public init(cache: BlockCache, transport: RangeTransport) {
        self.cache = cache
        self.transport = transport
    }

    deinit {
        for task in inFlight.values { task.cancel() }
        cache.save()
    }

    // MARK: - 配置

    /// 预缓存距离（字节）：nil 为直到末尾；0 只下载读取所需的块
    public func setPrefetchLimit(_ bytes: Int64?) {
        update { $0.prefetchLimit = bytes }
    }

    /// 是否预缓存；关闭时只下载读取所需的块（如截图），正在进行的预缓存下载随之取消
    public func setPrefetching(_ enabled: Bool) {
        update { $0.prefetching = enabled }
    }

    /// 缓存占用上限（字节），nil 为不限；keepBehind 为回拖时保留的已看部分
    public func setCacheBudget(_ bytes: Int64?, keepBehind: Int64 = 64 << 20) {
        update {
            $0.budget = bytes
            $0.keepBehind = keepBehind
            $0.trim()
        }
    }

    /// 设置片源码率（字节/秒）。往后缓存超过约 30 秒后，预缓存降为单连接、约 2 倍码率：
    /// 持续高速写盘会拖慢播放时从缓存读取（读取在播放队列上），而这时多缓存也没有必要那么快
    public func setPacing(bytesPerSecond: Double?) {
        update { $0.pace = bytesPerSecond }
    }

    public func setConcurrency(_ count: Int) {
        update { $0.concurrency = max(1, count) }
    }

    /// 停止所有下载；之后的读取只能读到已缓存的部分
    public func close() {
        condition.lock()
        closed = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        condition.broadcast()
        condition.unlock()
        cache.save()
    }

    /// 网络恢复（或允许使用的网络变化）后立即重试下载
    public func retryNow() {
        update { $0.retryAt = .distantPast }
    }

    // MARK: - 状态

    /// 最近的下载速度（字节/秒）
    public var downloadRate: Double {
        condition.withLock { meter.rate }
    }

    /// 最近一次下载错误；下载成功后清除
    public var error: Error? {
        condition.withLock { lastError }
    }

    // MARK: - ByteSource

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let deadline = Date.now + Self.readTimeout
        condition.lock()
        defer { condition.unlock() }
        let block = cache.block(containing: offset)
        if cache.block(containing: position) != block || position > offset {
            position = offset
        }
        while true {
            if let n = try cache.read(at: offset, into: buffer) {
                position = offset + Int64(n)
                if urgent == block { urgent = nil }
                schedule()
                return n
            }
            if closed { throw NetworkError.offline }
            if failedBlock == block {
                failedBlock = nil
                urgent = nil
                throw lastError ?? NetworkError.offline
            }
            urgent = block
            schedule()
            guard condition.wait(until: deadline) else {
                urgent = nil
                throw lastError ?? NetworkError.offline
            }
        }
    }

    public func availableBytes(from offset: Int64) -> Int64? {
        let available = cache.contiguousBytes(from: offset)
        // 剩余部分已全部可读时视为到达末尾，不必再缓冲
        return offset + available >= cache.size ? .max : available
    }

    public func prepare(from offset: Int64) {
        update { source in
            // 跳转时解封装器可能先读了文件末尾的索引，读取位置停在别处；以将要读取的位置为准
            if source.cache.block(containing: source.position) != source.cache.block(containing: offset) {
                source.position = offset
            }
        }
    }

    public func setDataHandler(_ handler: (@Sendable () -> Void)?) {
        update { $0.dataHandler = handler }
    }

    // MARK: - 下载调度

    private func update(_ change: (RemoteByteSource) -> Void) {
        condition.lock()
        change(self)
        schedule()
        condition.unlock()
    }

    /// 超出缓存上限时删除离读取位置最远的块：先删读取位置之前（保留 keepBehind），再删最远的预缓存。需持有 condition
    private func trim() {
        guard let budget else { return }
        var excess = cache.cachedBytes - budget
        guard excess > 0 else { return }
        let current = cache.block(containing: position)
        let behind = Int(keepBehind / Int64(cache.blockSize))
        let present = cache.presentBlocks
        // 删除顺序：最早看过的在前，然后是最远的预缓存
        let order = present.filter { $0 < current - behind } + present.filter { $0 > current }.reversed()
        for block in order where excess > 0 {
            excess -= Int64(cache.range(ofBlock: block).count)
            cache.evict(block: block)
        }
    }

    /// 需在持有 condition 时调用
    private func schedule() {
        guard !closed else { return }
        let first = cache.block(containing: position)
        let last: Int
        if !prefetching || prefetchLimit == 0 {
            last = first
        } else if let limit = prefetchLimit {
            last = cache.block(containing: min(position + limit, cache.size - 1))
        } else {
            last = cache.blockCount - 1
        }
        // 需要的块：读取等待的块优先，然后从读取位置往后
        var wanted = cache.missingBlocks(from: first, through: last, limit: concurrency + 2)
        if let urgent, !cache.contains(block: urgent) {
            wanted.removeAll { $0 == urgent }
            wanted.insert(urgent, at: 0)
        }
        // 取消已不需要的下载（跳到了别处）
        for (block, task) in inFlight where !wanted.contains(block) {
            task.cancel()
            inFlight[block] = nil
        }
        // 下载失败后等待一会儿再重试，读取等待的块除外
        let waiting = Date.now < retryAt
        // 往后缓存充足时限速：单连接，按约 2 倍码率的间隔开始下一块
        var limit = concurrency
        var paced = false
        if let pace, urgent == nil, Double(cache.contiguousBytes(from: position)) > pace * Self.comfortSeconds {
            limit = 1
            paced = true
            if Date.now < nextPacedStart {
                wake(at: nextPacedStart)
                return
            }
        }
        for block in wanted where inFlight.count < limit && inFlight[block] == nil {
            if waiting, block != urgent { continue }
            inFlight[block] = Task.detached(priority: .utility) { [weak self] in
                await self?.download(block)
            }
            if paced, let pace {
                nextPacedStart = .now + Double(cache.blockSize) / (pace * Self.pacedRate)
            }
        }
    }

    /// 到时间后重新调度（限速等待），同一时间只安排一次
    private func wake(at date: Date) {
        guard !wakeScheduled else { return }
        wakeScheduled = true
        let delay = max(date.timeIntervalSinceNow, 0.01)
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.update { $0.wakeScheduled = false }
        }
    }

    private func download(_ block: Int) async {
        do {
            let data = try await transport.fetch(cache.range(ofBlock: block))
            try Task.checkCancellation()
            try cache.write(block: block, data: data)
            finished(block, bytes: data.count)
        } catch {
            // 被取消的下载已从 inFlight 移除，该块可能已重新开始下载，不再处理
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            failed(block, error: error)
        }
    }

    private func finished(_ block: Int, bytes: Int) {
        condition.lock()
        meter.add(bytes: bytes)
        trim()
        lastError = nil
        if failedBlock == block { failedBlock = nil }
        inFlight[block] = nil
        let handler = dataHandler
        condition.broadcast()
        schedule()
        condition.unlock()
        handler?()
    }

    private func failed(_ block: Int, error: Error) {
        condition.lock()
        inFlight[block] = nil
        lastError = error
        failedBlock = block
        retryAt = .now + 2
        condition.broadcast()
        condition.unlock()
        // 到时间后重新调度
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.update { _ in }
        }
    }
}

/// 下载速度：最近几秒内的平均值
private struct RateMeter {
    private var samples: [(time: Date, bytes: Int)] = []

    mutating func add(bytes: Int) {
        samples.append((.now, bytes))
        samples.removeAll { $0.time < .now - 5 }
    }

    var rate: Double {
        guard let first = samples.first else { return 0 }
        let span = max(Date.now.timeIntervalSince(first.time), 1)
        return Double(samples.reduce(0) { $0 + $1.bytes }) / span
    }
}
