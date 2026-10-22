import Testing
@testable import NoirEngine

/// 在真实时钟下运行播放会话，验证起播、时钟推进、跳转与渲染器状态。
@Suite(.serialized) struct PlaybackSessionTests {
    func open(_ file: String) async throws -> PlaybackSession {
        let session = PlaybackSession()
        _ = try await session.open(source: FileByteSource(url: TestMedia.url(file)))
        return session
    }

    @Test("起播后时钟正常推进", arguments: ["hdr10-hevc-truehd51.mkv", "hlg-hevc-eac351.mkv", "sdr-h264-aac51.mp4", "sdr-hevc-dts51.mkv"])
    func playbackClockAdvances(file: String) async throws {
        let session = try await open(file)
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .seconds(2))

        let (stats, finished) = await session.snapshot()
        let now = session.currentTime
        #expect(now > 1.5 && now < 2.5, "\(file) 播放 2 秒后时钟应在 2 秒附近，实际 \(now)")
        #expect(!finished)
        #expect(stats.lastError == nil, "\(file)：\(stats.lastError ?? "")")
        #expect(!stats.videoRendererStatus.hasPrefix("失败"), "\(file) 视频：\(stats.videoRendererStatus)")
        #expect(!stats.audioRendererStatus.hasPrefix("失败"), "\(file) 音频：\(stats.audioRendererStatus)")
        #expect(stats.videoBuffered > 0.2, "\(file) 视频缓冲 \(stats.videoBuffered)")
    }

    @Test("跳转后从目标时间继续播放") func seekResumesAtTarget() async throws {
        let session = try await open("hdr10-hevc-truehd51.mkv")
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .milliseconds(500))
        session.seek(to: 6.3)
        try await Task.sleep(for: .milliseconds(1000))
        let now = session.currentTime
        // 跳转后 1 秒内恢复播放：时钟应已越过目标时间并持续推进
        #expect(now > 6.3 && now < 7.4, "跳到 6.3 秒后 1 秒，时钟应在 6.3–7.4 之间，实际 \(now)")
        #expect(await session.snapshot().stats.lastError == nil)
    }

    @Test("暂停时时钟停止") func pauseStopsClock() async throws {
        let session = try await open("sdr-hevc-flac71.mkv")
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .milliseconds(800))
        session.pause()
        try await Task.sleep(for: .milliseconds(100))
        let paused = session.currentTime
        try await Task.sleep(for: .milliseconds(500))
        #expect(abs(session.currentTime - paused) < 0.01)
    }

    @Test("播放中切换音轨") func switchAudioTrack() async throws {
        let session = try await open("hdr10-multi-audio.mkv")
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .milliseconds(800))
        for id in [2, 3, 1] { // E-AC3、AAC、TrueHD
            session.selectAudioTrack(id)
            try await Task.sleep(for: .milliseconds(800))
            let stats = await session.snapshot().stats
            #expect(stats.lastError == nil, "切到流 \(id)：\(stats.lastError ?? "")")
            #expect(!stats.audioRendererStatus.hasPrefix("失败"))
        }
        // 切换会从当前位置重新定位（长 GOP 片源需从关键帧解码），只校验切换后时钟持续推进
        let settled = session.currentTime
        try await Task.sleep(for: .milliseconds(500))
        #expect(settled > 1.5)
        #expect(session.currentTime - settled > 0.4)
    }

    @Test("播放至结尾") func reachesEnd() async throws {
        let session = try await open("sdr-hevc-alac20.mkv")
        defer { session.close() }
        session.seek(to: 9)
        session.play()
        try await Task.sleep(for: .seconds(2))
        #expect(await session.snapshot().finished)
    }
}
