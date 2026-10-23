import Foundation
import Testing
@testable import NoirEngine

/// 与其他实时播放测试同组串行
extension PlaybackSessionTests {
    /// 用 rclone 在本机提供 TestMedia 的 WebDAV 服务，测试列目录、认证、分段读取与播放。
    /// 需要安装 rclone（brew install rclone），未安装时跳过。
    @Suite(.enabled(if: WebDAVServer.rclone != nil, "未安装 rclone"))
    struct WebDAVTests {
        @Test("列出目录") func listDirectory() async throws {
            let server = try WebDAVServer()
            defer { server.stop() }
            let entries = try await server.client().list(server.root)
            let video = try #require(entries.first { $0.name == "hdr10-hevc-truehd51.mkv" })
            #expect(!video.isDirectory)
            #expect(video.size == Int64(try Data(contentsOf: TestMedia.url(video.name)).count))
            #expect(video.modified != nil)
            #expect(!entries.contains { $0.url.path() == server.root.path() }, "不应包含目录自身")
            let info = try await server.client().info(video.url)
            #expect(info.size == video.size)
        }

        @Test("密码错误时报认证失败") func wrongPassword() async throws {
            let server = try WebDAVServer()
            defer { server.stop() }
            await #expect(throws: NetworkError.unauthorized) {
                try await WebDAVClient(client: HTTPClient(username: "noir", password: "wrong")).list(server.root)
            }
        }

        @Test("通过 WebDAV 播放并完整缓存，与原文件一致") func playAndCache() async throws {
            let server = try WebDAVServer()
            defer { server.stop() }
            let webdav = server.client()
            let entry = try await webdav.info(server.root.appending(path: "sdr-h264-aac51.mp4"))
            let dir = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let cache = try BlockCache(directory: dir, size: try #require(entry.size), version: entry.version)
            let source = RemoteByteSource(cache: cache, transport: webdav.transport(for: entry.url))
            defer { source.close() }
            let session = PlaybackSession()
            defer { session.close() }
            _ = try await session.open(source: source)
            session.play()
            try await waitUntil(seconds: 3) { session.currentTime > 1 }
            #expect(await session.snapshot().stats.lastError == nil)
            try await waitUntil(seconds: 10) { cache.isComplete }
            let out = dir.deletingLastPathComponent().appending(path: "\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            source.close()
            try cache.moveCompletedFile(to: out)
            #expect(try Data(contentsOf: out) == Data(contentsOf: TestMedia.url("sdr-h264-aac51.mp4")))
        }
    }
}

extension PlaybackSessionTests.WebDAVTests {
    @Test("网络影片截图，并自动加载同目录的同名字幕") @MainActor func thumbnailAndSubtitles() async throws {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: TestMedia.url("sdr-h264-aac51.mp4"), to: folder.appending(path: "影片 1.mp4"))
        try Data("1\n00:00:01,000 --> 00:00:03,000\n你好，世界\n".utf8).write(to: folder.appending(path: "影片 1.chs.srt"))
        let server = try WebDAVServer(directory: folder)
        defer { server.stop() }
        let webdav = server.client()
        let entry = try #require(try await webdav.list(server.root).first { $0.name == "影片 1.mp4" })

        let cacheDir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let thumbCache = try BlockCache(directory: cacheDir.appending(path: "t"), size: entry.size!, version: entry.version)
        let thumbSource = RemoteByteSource(cache: thumbCache, transport: webdav.transport(for: entry.url))
        thumbSource.setPrefetching(false)
        let result = try await Task.detached { try Thumbnailer.make(source: thumbSource, maxWidth: 320) }.value
        thumbSource.close()
        #expect(result.image != nil)
        #expect(result.info.duration ?? 0 > 5)
        // 截图只读取需要的部分
        #expect(thumbCache.cachedBytes < entry.size!)

        let player = PlayerController()
        defer { player.close() }
        let cache = try BlockCache(directory: cacheDir.appending(path: "p"), size: entry.size!, version: entry.version)
        player.open(remote: entry, webdav: webdav, cache: cache)
        try await waitUntil(seconds: 5) { player.phase == .ready }
        #expect(player.title == "影片 1")
        #expect(player.subtitleTracks.contains { $0.isExternal && $0.title == "chs" })
        #expect(player.subtitleTrack?.isExternal == true, "中文外挂字幕应默认选中")
        try await waitUntil(seconds: 3) { player.currentTime > 0.5 }
    }
}

/// 本机 rclone WebDAV 服务
final class WebDAVServer {
    static let rclone = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"].first {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    let process = Process()
    let root: URL

    init(directory: URL = TestMedia.directory) throws {
        let port = Int.random(in: 20_000..<40_000)
        root = URL(string: "http://127.0.0.1:\(port)/")!
        process.executableURL = URL(filePath: Self.rclone!)
        process.arguments = ["serve", "webdav", directory.path, "--addr", "127.0.0.1:\(port)",
                             "--user", "noir", "--pass", "secret", "--read-only"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // 等待端口就绪
        let deadline = Date.now + 5
        while Date.now < deadline {
            var request = URLRequest(url: root)
            request.httpMethod = "OPTIONS"
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var ready = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                ready = response != nil
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if ready { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NetworkError.offline
    }

    func client() -> WebDAVClient {
        WebDAVClient(client: HTTPClient(username: "noir", password: "secret"))
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}
