import AVFoundation
import CFFmpeg

/// 播放会话：管理单个片源的解封装、解码与系统渲染器。
///
/// 数据流：Demuxer 拆分数据包 → 视频包零拷贝包成 CMSampleBuffer，经 VideoDecoder（VideoToolbox 硬解）按显示顺序输出画面，
/// 交给 AVSampleBufferVideoRenderer 按时送显（含 HDR），
/// 音频包经 AudioDecoder 交给 AVSampleBufferAudioRenderer；两者挂在同一个 AVSampleBufferRenderSynchronizer 上同步。
/// 渲染器按需拉取数据（requestMediaDataWhenReady），解封装与解码都在 queue 上进行。
///
/// 线程约定：带 `// queue` 标记的状态只在 queue 上访问，因此标为 @unchecked Sendable。
final class PlaybackSession: @unchecked Sendable {
    struct Opened: Sendable {
        var info: MediaInfo
        var videoTrackID: Int?
        var audioTrackID: Int?
    }

    let displayLayer = AVSampleBufferDisplayLayer()
    let subtitleLayer = SubtitleLayer()
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "noir.playback", qos: .userInteractive)

    private struct VideoTrack {
        var index: Int
        var format: CMVideoFormatDescription
        var timeBase: AVRational
        var decoder: VideoDecoder
    }

    private struct AudioTrack {
        var index: Int
        var decoder: AudioDecoder
    }

    private var demuxer: Demuxer?                    // queue
    private var video: VideoTrack?                   // queue
    private var audio: AudioTrack?                   // queue
    private var subtitle: (index: Int, decoder: SubtitleDecoder)? // queue
    private var videoPackets = FIFO<Packet>()        // queue
    private var audioPackets = FIFO<Packet>()        // queue
    private var audioSamples = FIFO<CMSampleBuffer>() // queue
    private var endOfStream = false                  // queue
    /// 视频解码器已输出全部画面
    private var videoDrained = false                 // queue
    /// 跳转目标：之前的视频帧仅解码不显示，之前的音频丢弃
    private var target = CMTime.zero                 // queue
    /// 期望的播放速率；0 为暂停
    private var desiredRate: Float = 0               // queue
    /// 打开或跳转后处于预缓冲阶段，待渲染器缓冲就绪后起播
    private var awaitingPreroll = false              // queue
    private var videoPrimed = false                  // queue
    private var audioPrimed = false                  // queue
    private var lastVideoPTS = CMTime.invalid        // queue
    private var lastAudioPTS = CMTime.invalid        // queue
    private var lastError: String?                   // queue
    private var timeObserver: Any?

    init() {
        videoRenderer = displayLayer.sampleBufferRenderer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        // 播放速率由会话显式控制，禁止同步器在缓冲不足时自动延迟起播
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        // 字幕按播放时钟刷新；时间跳变（跳转、起停）时同样回调
        let layer = subtitleLayer
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { time in
            layer.update(time: time.seconds)
        }
    }

    // MARK: - 对外接口（任意线程调用）

    var currentTime: Double {
        synchronizer.currentTime().seconds
    }

    func open(source: ByteSource) async throws -> Opened {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.openOnQueue(source: source))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func play() {
        queue.async { self.setRate(1) }
    }

    func pause() {
        queue.async { self.setRate(0) }
    }

    func seek(to seconds: Double) {
        queue.async { self.seekOnQueue(to: seconds) }
    }

    func selectAudioTrack(_ id: Int) {
        queue.async { self.selectAudioOnQueue(id) }
    }

    /// 选择内封字幕流并将解码结果写入 track；stream 为 nil 时停止读取内封字幕。
    func selectSubtitle(stream: Int?, track: SubtitleTrack?) {
        queue.async { self.selectSubtitleOnQueue(stream: stream, track: track) }
    }

    /// 获取统计数据；finished 表示片源已读完且播放已到达末尾。
    func snapshot() async -> (stats: PlaybackStats, finished: Bool) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.snapshotOnQueue()) }
        }
    }

    func close() {
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        queue.sync {
            stopFeeding()
            synchronizer.setRate(0, time: .zero)
            videoRenderer.flush()
            audioRenderer.flush()
            demuxer = nil
            video = nil
            audio = nil
            subtitle = nil
            clearBuffers()
        }
    }

    // MARK: - 打开

    private func openOnQueue(source: ByteSource) throws -> Opened {
        let demuxer = try Demuxer(source: source)
        self.demuxer = demuxer
        let info = demuxer.info

        // 视频：选择第一条系统可解码的轨道
        for track in info.videoTracks {
            let stream = demuxer.stream(track.id)
            let par = UnsafePointer(stream.pointee.codecpar!)
            if let format = try? VideoFormat.make(par),
               let decoder = try? VideoDecoder(format: format, reorderDepth: VideoDecoder.reorderDepth(par)) {
                video = VideoTrack(index: track.id, format: format, timeBase: stream.pointee.time_base, decoder: decoder)
                break
            }
        }
        // 音频：优先选择默认轨道，否则选择第一条可处理的轨道
        let candidates = info.audioTracks.filter { $0.route != .unsupported }
        if let track = candidates.first(where: \.isDefault) ?? candidates.first {
            audio = try? AudioTrack(index: track.id, decoder: AudioDecoders.make(stream: demuxer.stream(track.id)))
        }
        guard video != nil || audio != nil else {
            throw VideoFormatError.unsupportedCodec(info.videoTracks.first?.codec ?? "无可播放的轨道")
        }

        selectStreams()
        synchronizer.setRate(0, time: .zero)
        beginPreroll(at: .zero)
        return Opened(info: info, videoTrackID: video?.index, audioTrackID: audio?.index)
    }

    private func selectStreams() {
        demuxer?.select(streams: Set([video?.index, audio?.index, subtitle?.index].compactMap { $0 }))
    }

    // MARK: - 播放控制

    private func setRate(_ rate: Float) {
        desiredRate = rate
        // 预缓冲期间仅记录目标速率，起播时生效
        guard !awaitingPreroll else { return }
        synchronizer.rate = rate
    }

    private func seekOnQueue(to seconds: Double) {
        guard let demuxer else { return }
        let duration = demuxer.info.duration ?? .greatestFiniteMagnitude
        let clamped = min(max(seconds, 0), max(duration - 0.1, 0))

        stopFeeding()
        synchronizer.setRate(0, time: CMTime(seconds: clamped, preferredTimescale: 90_000))
        videoRenderer.flush()
        audioRenderer.flush()
        video?.decoder.flush()
        audio?.decoder.flush()
        subtitle?.decoder.flush()
        clearBuffers()
        do {
            try demuxer.seek(to: clamped)
        } catch {
            lastError = "\(error)"
        }
        beginPreroll(at: CMTime(seconds: clamped, preferredTimescale: 90_000))
    }

    private func selectAudioOnQueue(_ id: Int) {
        guard let demuxer, id != audio?.index else { return }
        do {
            audio = AudioTrack(index: id, decoder: try AudioDecoders.make(stream: demuxer.stream(id)))
        } catch {
            lastError = "\(error)"
            return
        }
        selectStreams()
        // 从当前位置重新定位，使新音轨与画面同步
        seekOnQueue(to: synchronizer.currentTime().seconds)
    }

    private func selectSubtitleOnQueue(stream: Int?, track: SubtitleTrack?) {
        guard stream != subtitle?.index else { return }
        guard let demuxer, let stream, let track else {
            subtitle = nil
            selectStreams()
            return
        }
        do {
            subtitle = (stream, try SubtitleDecoder(stream: demuxer.stream(stream), track: track))
        } catch {
            lastError = "\(error)"
            return
        }
        selectStreams()
        // 已读入缓冲的位置之前不会再读到该字幕流，从当前位置重新定位以补齐
        seekOnQueue(to: synchronizer.currentTime().seconds)
    }

    // MARK: - 数据供给

    private func beginPreroll(at time: CMTime) {
        target = time
        endOfStream = false
        videoDrained = false
        awaitingPreroll = true
        videoPrimed = video == nil
        audioPrimed = audio == nil
        startFeeding()
    }

    private func startFeeding() {
        if video != nil {
            videoRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedVideo() }
        }
        if audio != nil {
            audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feedAudio() }
        }
    }

    private func stopFeeding() {
        videoRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
    }

    private func clearBuffers() {
        videoPackets.removeAll()
        audioPackets.removeAll()
        audioSamples.removeAll()
        lastVideoPTS = .invalid
        lastAudioPTS = .invalid
    }

    /// 渲染器只接收约 0.1 秒的已解码画面，另行保持若干帧解码余量，播放队列短暂繁忙时不致断供
    private static let decodeAhead = 6

    private func feedVideo() {
        guard let video else { return }
        while videoRenderer.isReadyForMoreMediaData {
            while !videoDrained, video.decoder.bufferedCount() <= video.decoder.reorderDepth + Self.decodeAhead {
                guard let packet = nextPacket(stream: video.index) else {
                    video.decoder.finish()
                    videoDrained = true
                    break
                }
                do {
                    try video.decoder.decode(SampleBuffers.video(
                        packet: packet, format: video.format, timeBase: video.timeBase
                    ))
                } catch {
                    // 单帧解码失败不中断播放
                    lastError = "\(error)"
                }
            }
            guard let frame = video.decoder.nextFrame(draining: videoDrained) else {
                if videoDrained { videoRenderer.stopRequestingMediaData() }
                break
            }
            // 跳转目标之前的画面只解码不显示
            guard frame.pts >= target else { continue }
            do {
                videoRenderer.enqueue(try video.decoder.sampleBuffer(for: frame))
                lastVideoPTS = frame.pts
            } catch {
                lastError = "\(error)"
            }
        }
        videoPrimed = true
        startIfPrimed()
    }

    private func feedAudio() {
        guard let audio else { return }
        while audioRenderer.isReadyForMoreMediaData {
            if let sample = audioSamples.pop() {
                audioRenderer.enqueue(sample)
                lastAudioPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                continue
            }
            guard let packet = nextPacket(stream: audio.index) else {
                audioRenderer.stopRequestingMediaData()
                break
            }
            do {
                for sample in try audio.decoder.decode(packet) where trimToTarget(sample) {
                    audioSamples.push(sample)
                }
            } catch {
                // 单个数据包解码失败不中断播放
                lastError = "\(error)"
            }
        }
        audioPrimed = true
        startIfPrimed()
    }

    /// 处理跳转目标之前的音频：完全早于目标的样本丢弃，跨越目标的样本裁剪开头。返回是否保留该样本。
    private func trimToTarget(_ sample: CMSampleBuffer) -> Bool {
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        let end = start + CMSampleBufferGetDuration(sample)
        guard start.isValid, start < target else { return true }
        guard end.isValid, end > target else { return false }
        let trim = target - start
        CMSetAttachment(
            sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
            value: CMTimeCopyAsDictionary(trim, allocator: kCFAllocatorDefault),
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return true
    }

    /// 获取指定流的下一个数据包；读到的其他流数据包暂存至对应队列。
    private func nextPacket(stream index: Int) -> Packet? {
        while true {
            if index == video?.index, let packet = videoPackets.pop() { return packet }
            if index == audio?.index, let packet = audioPackets.pop() { return packet }
            guard !endOfStream, let demuxer else { return nil }
            do {
                guard let packet = try demuxer.readPacket() else {
                    endOfStream = true
                    continue
                }
                // find_stream_info 期间缓存的数据包不受 discard 影响，需按流序号分拣
                if packet.streamIndex == video?.index {
                    videoPackets.push(packet)
                } else if packet.streamIndex == audio?.index {
                    audioPackets.push(packet)
                } else if packet.streamIndex == subtitle?.index {
                    subtitle?.decoder.decode(packet)
                }
            } catch {
                lastError = "\(error)"
                endOfStream = true
            }
        }
    }

    private func startIfPrimed() {
        guard awaitingPreroll, videoPrimed, audioPrimed else { return }
        awaitingPreroll = false
        synchronizer.setRate(desiredRate, time: target)
    }

    // MARK: - 统计

    private func snapshotOnQueue() -> (stats: PlaybackStats, finished: Bool) {
        let now = synchronizer.currentTime()
        func ahead(_ pts: CMTime) -> Double {
            pts.isValid ? max(0, (pts - now).seconds) : 0
        }
        var stats = PlaybackStats()
        stats.videoBuffered = ahead(video?.decoder.bufferedUntil ?? lastVideoPTS)
        stats.audioBuffered = ahead(lastAudioPTS)
        stats.videoRendererStatus = describe(videoRenderer.status, videoRenderer.error)
        stats.audioRendererStatus = describe(audioRenderer.status, audioRenderer.error)
        stats.outputChannels = audio?.decoder.outputChannels
        stats.audioRoute = audio?.decoder.route
        stats.lastError = lastError

        let lastPTS = [lastVideoPTS, lastAudioPTS].filter(\.isValid).max()
        let finished = endOfStream && videoPackets.isEmpty && audioPackets.isEmpty && audioSamples.isEmpty
            && (lastPTS.map { now >= $0 } ?? true)
        return (stats, finished)
    }

    private func describe(_ status: AVQueuedSampleBufferRenderingStatus, _ error: Error?) -> String {
        switch status {
        case .rendering: "渲染中"
        case .failed: "失败：\(error?.localizedDescription ?? "未知错误")"
        default: "待机"
        }
    }
}
