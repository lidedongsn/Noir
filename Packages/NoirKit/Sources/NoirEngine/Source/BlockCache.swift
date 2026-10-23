import Foundation
import Synchronization

/// 网络片源的磁盘块缓存：目录下的稀疏数据文件 data、已下载块记录 blocks 与版本信息 meta.json。
///
/// 文件按固定大小分块。块完整写入数据文件后才标记为已下载，记录每隔几块落盘一次；
/// 进程意外退出时最多丢失最近几块的标记（重新下载即可），不会把不完整的块当作已下载。
/// 线程安全。
public final class BlockCache: Sendable {
    public static let defaultBlockSize = 4 << 20

    public let directory: URL
    public let blockSize: Int
    public let size: Int64
    public let blockCount: Int
    private let fd: Int32
    private let state: Mutex<State>

    private struct State {
        var present: [Bool]
        var presentCount: Int
        /// 自上次落盘后新标记的块数
        var unsaved = 0
    }

    private struct Meta: Codable {
        var size: Int64
        var version: String
        var blockSize: Int
    }

    /// 打开或创建缓存。version 标识服务器上的文件版本（如大小与修改时间），与已有缓存不一致时清空重建。
    public init(directory: URL, size: Int64, version: String, blockSize: Int = defaultBlockSize) throws {
        self.directory = directory
        self.size = size
        self.blockSize = blockSize
        blockCount = Int((size + Int64(blockSize) - 1) / Int64(blockSize))
        let fm = FileManager.default
        let metaURL = directory.appending(path: "meta.json")
        let meta = Meta(size: size, version: version, blockSize: blockSize)
        let existing = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        if existing?.size != size || existing?.version != version || existing?.blockSize != blockSize {
            try? fm.removeItem(at: directory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(meta).write(to: metaURL)
        }
        let dataPath = directory.appending(path: "data").path
        fd = open(dataPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var present = [Bool](repeating: false, count: blockCount)
        if let saved = try? Data(contentsOf: directory.appending(path: "blocks")), saved.count == blockCount {
            for (i, byte) in saved.enumerated() { present[i] = byte != 0 }
        }
        state = Mutex(State(present: present, presentCount: present.count { $0 }))
        // 访问时间用于按最近使用清理
        try? fm.setAttributes([.modificationDate: Date.now], ofItemAtPath: directory.path)
    }

    deinit {
        save()
        close(fd)
    }

    /// 第 index 块的字节范围
    public func range(ofBlock index: Int) -> Range<Int64> {
        let start = Int64(index) * Int64(blockSize)
        return start..<min(start + Int64(blockSize), size)
    }

    public func block(containing offset: Int64) -> Int {
        Int(offset / Int64(blockSize))
    }

    public func contains(block index: Int) -> Bool {
        state.withLock { $0.present[index] }
    }

    public var cachedBytes: Int64 {
        let count = state.withLock { $0.presentCount }
        guard count > 0 else { return 0 }
        // 只有最后一块可能不满
        let last = blockCount - 1
        let lastSize = range(ofBlock: last).count
        return contains(block: last)
            ? Int64(count - 1) * Int64(blockSize) + Int64(lastSize)
            : Int64(count) * Int64(blockSize)
    }

    public var isComplete: Bool {
        state.withLock { $0.presentCount == blockCount }
    }

    /// 写入一整块数据并标记为已下载
    public func write(block index: Int, data: Data) throws {
        let range = range(ofBlock: index)
        precondition(data.count == range.count, "块大小不符")
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(range.lowerBound) + off_t(written))
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += n
            }
        }
        let shouldSave = state.withLock { state -> Bool in
            guard !state.present[index] else { return false }
            state.present[index] = true
            state.presentCount += 1
            state.unsaved += 1
            return state.unsaved >= 8 || state.presentCount == blockCount
        }
        if shouldSave { save() }
    }

    /// 从 offset 起连续已下载的字节数
    public func contiguousBytes(from offset: Int64) -> Int64 {
        guard offset < size else { return 0 }
        var index = block(containing: offset)
        state.withLock { state in
            while index < blockCount, state.present[index] { index += 1 }
        }
        return max(0, min(Int64(index) * Int64(blockSize), size) - offset)
    }

    /// 读取已下载的部分；offset 所在的块未下载时返回 nil，读到末尾返回 0
    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int? {
        guard offset < size else { return 0 }
        let available = min(Int64(buffer.count), contiguousBytes(from: offset))
        guard available > 0 else { return nil }
        let n = pread(fd, buffer.baseAddress, Int(available), off_t(offset))
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return n
    }

    /// 已下载的块序号
    public var presentBlocks: [Int] {
        state.withLock { state in state.present.indices.filter { state.present[$0] } }
    }

    /// 删除一块：先取消标记，再释放数据文件中对应的磁盘空间
    public func evict(block index: Int) {
        let removed = state.withLock { state -> Bool in
            guard state.present[index] else { return false }
            state.present[index] = false
            state.presentCount -= 1
            state.unsaved += 1
            return true
        }
        guard removed else { return }
        let range = range(ofBlock: index)
        // 打洞要求按文件系统块对齐；最后一块不足整块时向下取整
        let length = range.count / 4096 * 4096
        guard length > 0 else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(range.lowerBound), fp_length: off_t(length))
        _ = fcntl(fd, F_PUNCHHOLE, &hole)
    }

    /// 从 first 块往后（含）尚未下载的块，最多 limit 个
    public func missingBlocks(from first: Int, through last: Int, limit: Int) -> [Int] {
        guard first < blockCount, limit > 0 else { return [] }
        var result: [Int] = []
        state.withLock { state in
            for i in first...min(last, blockCount - 1) where !state.present[i] {
                result.append(i)
                if result.count == limit { break }
            }
        }
        return result
    }

    /// 已下载块记录落盘
    public func save() {
        let bytes = state.withLock { state -> [UInt8] in
            state.unsaved = 0
            return state.present.map { $0 ? 1 : 0 }
        }
        try? Data(bytes).write(to: directory.appending(path: "blocks"), options: .atomic)
    }

    /// 已下载完整时，把数据文件移动到 destination（同一卷上为重命名，不复制），并删除缓存目录
    public func moveCompletedFile(to destination: URL) throws {
        guard isComplete else { throw CocoaError(.fileReadCorruptFile) }
        fsync(fd)
        try FileManager.default.moveItem(at: directory.appending(path: "data"), to: destination)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - 空间管理

extension BlockCache {
    /// root 下所有缓存占用的字节数（按实际分配的磁盘空间）
    public static func usage(root: URL) -> Int64 {
        entries(root: root).reduce(0) { $0 + $1.bytes }
    }

    /// 按最近使用清理，直到总占用不超过 limit；keep 中的缓存目录（正在播放或下载）不删
    public static func prune(root: URL, limit: Int64, keep: Set<URL> = []) {
        let keepPaths = Set(keep.map(\.standardizedFileURL.path))
        var total = usage(root: root)
        // 最久没用的在前
        for entry in entries(root: root).sorted(by: { $0.used < $1.used }) where total > limit {
            guard !keepPaths.contains(entry.url.standardizedFileURL.path) else { continue }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    private static func entries(root: URL) -> [(url: URL, bytes: Int64, used: Date)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return dirs.map { dir in
            let used = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            let bytes = files.reduce(Int64(0)) { sum, file in
                sum + Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            }
            return (dir, bytes, used)
        }
    }
}
