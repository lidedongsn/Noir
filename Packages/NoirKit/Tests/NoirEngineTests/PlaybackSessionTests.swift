import Testing
@testable import NoirEngine

/// 在真实时钟下运行播放会话，验证起播、时钟推进、跳转与渲染器状态。
@Suite(.serialized) struct PlaybackSessionTests {
    func open(_ file: String) async throws -> PlaybackSession {
        let session = PlaybackSession()
        _ = try await session.open(source: FileByteSource(url: TestMedia.url(file)))
        return session
    }

    @Test("起播后时钟正常推进", arguments: ["hdr10-hevc-truehd51.mkv", "hlg-hevc-eac351.mkv", "sdr-h264-aac51.mp4", "sdr-hevc-dts51.mkv", "dv-p5.mkv"])
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

    @Test("续播：打开时直接从指定位置开始") func openAtStartTime() async throws {
        let session = PlaybackSession()
        defer { session.close() }
        _ = try await session.open(source: FileByteSource(url: TestMedia.url("hdr10-hevc-truehd51.mkv")), startTime: 6.3)
        // 打开完成即已定位，不经过开头
        #expect(abs(session.currentTime - 6.3) < 0.01, "打开后时钟应在 6.3 秒，实际 \(session.currentTime)")
        session.play()
        try await Task.sleep(for: .milliseconds(1000))
        let now = session.currentTime
        #expect(now > 6.3 && now < 7.4, "从 6.3 秒起播 1 秒后应在 6.3–7.4 之间，实际 \(now)")
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

    @Test("后台仅播放声音，回到前台恢复画面") func suspendAndResumeVideo() async throws {
        let session = try await open("hdr10-hevc-truehd51.mkv")
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .milliseconds(600))
        session.suspendVideo()
        try await Task.sleep(for: .milliseconds(1500))
        // 画面停止解码后声音继续，时钟照常推进
        let suspended = await session.snapshot().stats
        #expect(session.currentTime > 1.8)
        #expect(suspended.audioBuffered > 0.2)
        #expect(suspended.videoBuffered < 0.5, "暂停画面后视频缓冲应耗尽，实际 \(suspended.videoBuffered)")

        session.resumeVideo()
        try await Task.sleep(for: .milliseconds(1200))
        let resumed = await session.snapshot().stats
        #expect(resumed.videoBuffered > 0.2, "恢复后应重新解码画面，实际 \(resumed.videoBuffered)")
        #expect(resumed.lastError == nil, "\(resumed.lastError ?? "")")
        // 恢复画面需从关键帧重新定位，只校验恢复后时钟持续推进
        let settled = session.currentTime
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.currentTime - settled > 0.4)
    }

    /// 锁屏后系统作废了硬件解码会话，解锁恢复画面时不能卡住，播放与暂停照常响应
    @Test("锁屏期间解码会话被作废，解锁后恢复") func resumeAfterInvalidation() async throws {
        let session = try await open("hdr10-hevc-truehd51.mkv")
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .milliseconds(600))
        session.suspendVideo()
        session.invalidateVideoDecoder()
        try await Task.sleep(for: .milliseconds(800))
        let beforeResume = session.currentTime
        session.resumeVideo()
        // 恢复画面时声音不中断：时钟持续推进，没有重新缓冲造成的停顿
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.currentTime - beforeResume > 0.45, "恢复画面时时钟不应停顿，0.5 秒内推进 \(session.currentTime - beforeResume)")
        try await Task.sleep(for: .milliseconds(700))

        let stats = await session.snapshot().stats
        #expect(stats.videoBuffered > 0.2, "恢复后应重新解码画面，实际 \(stats.videoBuffered)")
        let playing = session.currentTime
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.currentTime - playing > 0.3, "恢复后时钟应继续推进")
        session.pause()
        try await Task.sleep(for: .milliseconds(100))
        let paused = session.currentTime
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(session.currentTime - paused) < 0.01, "暂停应生效")
    }

    /// 前台播放中解码会话被作废（例如系统中断）：声音不中断，画面自动重建
    @Test("播放中解码会话被作废后自动恢复") func recoverWhilePlaying() async throws {
        let session = try await open("hdr10-hevc-truehd51.mkv")
        defer { session.close() }
        session.play()
        try await Task.sleep(for: .milliseconds(600))
        session.invalidateVideoDecoder()
        try await Task.sleep(for: .milliseconds(2500))
        let stats = await session.snapshot().stats
        #expect(stats.videoBuffered > 0.2, "应自动重建解码并恢复画面，实际 \(stats.videoBuffered)")
        let now = session.currentTime
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.currentTime - now > 0.3)
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
