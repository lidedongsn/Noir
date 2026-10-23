import Foundation
import Synchronization
import Testing
@testable import NoirEngine

/// 模拟网络：从本地文件按范围读取，可设置带宽、延迟与断网
final class FakeTransport: RangeTransport {
    private let data: Data
    private let state: Mutex<State>

    struct State {
        /// 字节/秒；nil 为不限速
        var bandwidth: Double?
        var latency: Duration = .milliseconds(5)
        var offline = false
        var requests: [Range<Int64>] = []
    }

    init(file: String, bandwidth: Double? = nil) throws {
        data = try Data(contentsOf: TestMedia.url(file))
        state = Mutex(State(bandwidth: bandwidth))
    }

    var size: Int64 { Int64(data.count) }
    var requests: [Range<Int64>] { state.withLock { $0.requests } }

    func set(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }

    func fetch(_ range: Range<Int64>) async throws -> Data {
        let (latency, bandwidth, offline) = state.withLock { state in
            state.requests.append(range)
            return (state.latency, state.bandwidth, state.offline)
        }
        try await Task.sleep(for: latency)
        if offline { throw NetworkError.offline }
        if let bandwidth {
            try await Task.sleep(for: .seconds(Double(range.count) / bandwidth))
        }
        // 传输途中断网同样失败
        if state.withLock({ $0.offline }) { throw NetworkError.offline }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "noir-tests-\(UUID().uuidString)")
}

@Suite struct BlockCacheTests {
    @Test("写入、读取与重新打开后保留") func writeReadReopen() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let size: Int64 = 10_000
        let bytes = Data((0..<Int(size)).map { UInt8($0 % 251) })
        do {
            let cache = try BlockCache(directory: dir, size: size, version: "v1", blockSize: 4096)
            #expect(cache.blockCount == 3)
            #expect(cache.range(ofBlock: 2) == 8192..<10_000)
            try cache.write(block: 0, data: bytes.subdata(in: 0..<4096))
            try cache.write(block: 2, data: bytes.subdata(in: 8192..<10_000))
            #expect(cache.contiguousBytes(from: 100) == 3996)
            #expect(cache.contiguousBytes(from: 5000) == 0)
            #expect(cache.contiguousBytes(from: 9000) == 1000)
            var buffer = [UInt8](repeating: 0, count: 8000)
            let n = try buffer.withUnsafeMutableBytes { try cache.read(at: 1000, into: $0) }
            // 只读到第一块末尾
            #expect(n == 3096)
            #expect(Array(buffer[0..<3096]) == Array(bytes[1000..<4096]))
            let missing = try buffer.withUnsafeMutableBytes { try cache.read(at: 5000, into: $0) }
            #expect(missing == nil)
            #expect(cache.missingBlocks(from: 0, through: 2, limit: 5) == [1])
            #expect(cache.cachedBytes == 4096 + 1808)
        }
        // 重新打开：已下载的块保留
        let reopened = try BlockCache(directory: dir, size: size, version: "v1", blockSize: 4096)
        #expect(reopened.contains(block: 0) && !reopened.contains(block: 1) && reopened.contains(block: 2))
        // 服务器上的文件变了：清空
        let changed = try BlockCache(directory: dir, size: size, version: "v2", blockSize: 4096)
        #expect(changed.cachedBytes == 0)
    }

    @Test("下载完成后移出为普通文件") func moveCompleted() throws {
        let dir = temporaryDirectory()
        let out = temporaryDirectory().appendingPathExtension("bin")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: out)
        }
        let bytes = Data((0..<5000).map { UInt8($0 % 7) })
        let cache = try BlockCache(directory: dir, size: 5000, version: "v", blockSize: 4096)
        try cache.write(block: 1, data: bytes.subdata(in: 4096..<5000))
        #expect(throws: (any Error).self) { try cache.moveCompletedFile(to: out) }
        try cache.write(block: 0, data: bytes.subdata(in: 0..<4096))
        try cache.moveCompletedFile(to: out)
        #expect(try Data(contentsOf: out) == bytes)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("超出上限时先清理最久没用的") func pruneOldest() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var dirs: [URL] = []
        for i in 0..<3 {
            let dir = root.appending(path: "\(i)")
            let cache = try BlockCache(directory: dir, size: 1 << 20, version: "v", blockSize: 1 << 20)
            try cache.write(block: 0, data: Data(repeating: 1, count: 1 << 20))
            try FileManager.default.setAttributes([.modificationDate: Date.now - Double(100 - i)], ofItemAtPath: dir.path)
            dirs.append(dir)
        }
        // 最旧的 0 号正在播放，不能删
        BlockCache.prune(root: root, limit: Int64(2.5 * Double(1 << 20)), keep: [dirs[0]])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["0", "2"])
    }
}

@Suite struct RemoteByteSourceTests {
    func make(_ transport: FakeTransport, blockSize: Int = 64 << 10) throws -> (RemoteByteSource, URL) {
        let dir = temporaryDirectory()
        let cache = try BlockCache(directory: dir, size: transport.size, version: "v", blockSize: blockSize)
        return (RemoteByteSource(cache: cache, transport: transport), dir)
    }

    @Test("顺序读出的数据与原文件一致，并预缓存到末尾") func readsAndPrefetches() async throws {
        let transport = try FakeTransport(file: "sdr-hevc-flac71.mkv")
        let (source, dir) = try make(transport)
        defer { source.close(); try? FileManager.default.removeItem(at: dir) }
        var buffer = [UInt8](repeating: 0, count: 100_000)
        let n = try buffer.withUnsafeMutableBytes { try source.read(at: 1_000_000, into: $0) }
        #expect(n > 0)
        let original = try Data(contentsOf: TestMedia.url("sdr-hevc-flac71.mkv"))
        #expect(Array(buffer[0..<n]) == Array(original[1_000_000..<(1_000_000 + n)]))
        // 读取位置之后一直预缓存到文件末尾，之前的部分不下载
        try await waitUntil(seconds: 5) { source.availableBytes(from: 1_000_000) == .max }
        #expect(source.cache.contiguousBytes(from: 0) == 0)
    }

    @Test("关闭预缓存时只下载读取需要的块") func noPrefetch() async throws {
        let transport = try FakeTransport(file: "sdr-hevc-flac71.mkv")
        let (source, dir) = try make(transport)
        defer { source.close(); try? FileManager.default.removeItem(at: dir) }
        source.setPrefetching(false)
        var buffer = [UInt8](repeating: 0, count: 1000)
        _ = try buffer.withUnsafeMutableBytes { try source.read(at: 0, into: $0) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(transport.requests.count == 1)
    }

    @Test("限制预缓存距离") func prefetchLimit() async throws {
        let transport = try FakeTransport(file: "sdr-hevc-flac71.mkv")
        let (source, dir) = try make(transport)
        defer { source.close(); try? FileManager.default.removeItem(at: dir) }
        source.setPrefetchLimit(256 << 10)
        var buffer = [UInt8](repeating: 0, count: 1000)
        _ = try buffer.withUnsafeMutableBytes { try source.read(at: 0, into: $0) }
        try await Task.sleep(for: .milliseconds(300))
        // 第 0 块加往后 256 KB：共 5 块
        #expect(source.cache.cachedBytes == 5 * (64 << 10))
    }

    @Test("缓存超出上限时删除看过的部分，占用不超过上限") func rollingBudget() async throws {
        let transport = try FakeTransport(file: "sdr-hevc-flac71.mkv")
        let (source, dir) = try make(transport)
        defer { source.close(); try? FileManager.default.removeItem(at: dir) }
        let budget: Int64 = 1 << 20
        source.setCacheBudget(budget, keepBehind: 128 << 10)
        source.setPrefetchLimit(budget - (256 << 10))
        let original = try Data(contentsOf: TestMedia.url("sdr-hevc-flac71.mkv"))
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 200_000)
        while offset < transport.size {
            let n = try buffer.withUnsafeMutableBytes { try source.read(at: offset, into: $0) }
            #expect(Array(buffer[0..<n]) == Array(original[Int(offset)..<Int(offset) + n]))
            offset += Int64(n)
            // 刚下载完、尚未清理的块可能短暂超出，最多为并行下载的块数
            #expect(source.cache.cachedBytes <= budget + 3 * (64 << 10), "缓存占用 \(source.cache.cachedBytes) 超过上限")
        }
        // 开头早已删除，末尾仍在
        #expect(!source.cache.contains(block: 0))
        #expect(source.cache.contains(block: source.cache.blockCount - 1))
        // 删除的块释放了磁盘空间
        let allocated = try dir.appending(path: "data").resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        #expect(Int64(allocated) <= budget + (64 << 10), "实际占用磁盘 \(allocated)")
    }

    @Test("读完文件末尾的索引后，按将要读取的位置下载") func prepareMovesPrefetch() async throws {
        // MKV 跳转先读文件末尾的索引，读取位置停在末尾；播放层据将要读取的位置检查缓存，数据不足时通知片源
        let transport = try FakeTransport(file: "sdr-hevc-flac71.mkv")
        let (source, dir) = try make(transport)
        defer { source.close(); try? FileManager.default.removeItem(at: dir) }
        source.setPrefetchLimit(256 << 10)
        var buffer = [UInt8](repeating: 0, count: 1000)
        _ = try buffer.withUnsafeMutableBytes { try source.read(at: transport.size - 1000, into: $0) }
        try await Task.sleep(for: .milliseconds(100))
        let middle = transport.size / 2
        #expect(source.availableBytes(from: middle) == 0)
        source.prepare(from: middle)
        try await waitUntil(seconds: 2) { (source.availableBytes(from: middle) ?? 0) >= 256 << 10 }
    }

    @Test("断网时读取未缓存的数据立即报错，恢复后可读") func offline() async throws {
        let transport = try FakeTransport(file: "sdr-hevc-flac71.mkv")
        let (source, dir) = try make(transport)
        defer { source.close(); try? FileManager.default.removeItem(at: dir) }
        transport.set { $0.offline = true }
        var buffer = [UInt8](repeating: 0, count: 1000)
        let start = Date.now
        #expect(throws: NetworkError.offline) {
            try buffer.withUnsafeMutableBytes { _ = try source.read(at: 0, into: $0) }
        }
        #expect(Date.now.timeIntervalSince(start) < 1, "没有网络时不应等到超时")
        transport.set { $0.offline = false }
        source.retryNow()
        let n = try buffer.withUnsafeMutableBytes { try source.read(at: 0, into: $0) }
        #expect(n == 1000)
    }
}

/// 等待条件成立，超时则记录失败
func waitUntil(seconds: Double, isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async throws {
    let deadline = Date.now + seconds
    while !(await condition()) {
        guard Date.now < deadline else {
            Issue.record("等待超时")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// 通过模拟网络播放：网速充足时与本地一致，网速不足或断网时缓冲，音画位置保持一致。
/// 与其他实时播放测试同组串行，避免同时硬解多路 4K 互相拖慢
extension PlaybackSessionTests {
    @Suite struct NetworkPlaybackTests {
        func open(_ transport: FakeTransport) async throws -> (PlaybackSession, RemoteByteSource, URL) {
            let dir = temporaryDirectory()
            let cache = try BlockCache(directory: dir, size: transport.size, version: "v", blockSize: 256 << 10)
            let source = RemoteByteSource(cache: cache, transport: transport)
            let session = PlaybackSession()
            _ = try await session.open(source: source)
            return (session, source, dir)
        }

        @Test("网速充足时时钟正常推进") func fastNetwork() async throws {
            let transport = try FakeTransport(file: "hdr10-hevc-truehd51.mkv", bandwidth: 50_000_000)
            let (session, source, dir) = try await open(transport)
            defer { session.close(); source.close(); try? FileManager.default.removeItem(at: dir) }
            session.play()
            try await waitUntil(seconds: 1) { session.currentTime > 0 }
            let started = session.currentTime
            try await Task.sleep(for: .seconds(1.5))
            let advanced = session.currentTime - started
            let stats = await session.snapshot().stats
            #expect(advanced > 1.35 && advanced < 1.65, "起播后 1.5 秒时钟应推进约 1.5 秒，实际 \(advanced)")
            #expect(!stats.buffering)
            #expect(stats.lastError == nil, "\(stats.lastError ?? "")")
            #expect(stats.videoBuffered > 0.2)
        }

        @Test("网速低于码率时缓冲，时钟不会跑过已缓存的数据") func slowNetwork() async throws {
            // 片源约 1.6 MB/s，网速只给一半
            let transport = try FakeTransport(file: "hdr10-hevc-truehd51.mkv", bandwidth: 800_000)
            let (session, source, dir) = try await open(transport)
            defer { session.close(); source.close(); try? FileManager.default.removeItem(at: dir) }
            session.play()
            var sawBuffering = false
            var last = session.currentTime
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(100))
                let stats = await session.snapshot().stats
                sawBuffering = sawBuffering || stats.buffering
                let now = session.currentTime
                #expect(now >= last - 0.001, "时钟不应倒退")
                last = now
                #expect(stats.lastError == nil, "\(stats.lastError ?? "")")
            }
            #expect(sawBuffering, "网速不足时应进入缓冲")
            #expect(last > 0.5, "缓冲后应继续播放，实际 \(last)")
            // 6 秒只下载了约 4.8 MB，约 3 秒的内容
            #expect(last < 4.5, "时钟不应超过已下载的内容，实际 \(last)")
            #expect(!(await session.snapshot().finished))
        }

        @Test("跳到未缓存的位置后正常播放，往回跳只读缓存") func seekOverNetwork() async throws {
            let transport = try FakeTransport(file: "hdr10-hevc-truehd51.mkv", bandwidth: 4_000_000)
            let (session, source, dir) = try await open(transport)
            defer { session.close(); source.close(); try? FileManager.default.removeItem(at: dir) }
            session.play()
            try await Task.sleep(for: .milliseconds(500))
            session.seek(to: 7)
            try await waitUntil(seconds: 4) { session.currentTime > 7.3 }
            #expect(await session.snapshot().stats.lastError == nil)
            // 往回跳到开头：开头已缓存，不再下载
            let before = transport.requests.filter { $0.lowerBound < 1 << 20 }.count
            session.seek(to: 0.2)
            try await waitUntil(seconds: 2) { session.currentTime > 0.5 && session.currentTime < 2 }
            #expect(transport.requests.filter { $0.lowerBound < 1 << 20 }.count == before)
        }

        @Test("断网后播完已缓存的部分暂停，恢复网络后继续") func offlineThenOnline() async throws {
            let transport = try FakeTransport(file: "hdr10-hevc-truehd51.mkv", bandwidth: 50_000_000)
            let (session, source, dir) = try await open(transport)
            defer { session.close(); source.close(); try? FileManager.default.removeItem(at: dir) }
            // 只缓存约 5 秒的内容后断网
            source.setPrefetchLimit(8 << 20)
            session.play()
            try await Task.sleep(for: .milliseconds(300))
            transport.set { $0.offline = true }
            try await waitUntil(seconds: 10) { await session.snapshot().stats.buffering }
            let stalled = session.currentTime
            try await Task.sleep(for: .milliseconds(500))
            #expect(abs(session.currentTime - stalled) < 0.01, "缓冲中时钟应停止")
            #expect(stalled > 1.5, "应先播完已缓存的部分，实际 \(stalled)")

            transport.set { $0.offline = false }
            source.retryNow()
            try await waitUntil(seconds: 6) { session.currentTime > stalled + 0.5 }
            let stats = await session.snapshot().stats
            #expect(!stats.buffering)
            #expect(stats.lastError == nil, "\(stats.lastError ?? "")")
        }
    }
}
