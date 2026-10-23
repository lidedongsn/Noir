import AVFoundation
import Observation

/// 面向界面层的播放器控制器。状态在主线程读写，解封装与解码在 PlaybackSession 的队列中执行。
@MainActor @Observable
public final class PlayerController {
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var info: MediaInfo?
    public private(set) var title: String?
    public private(set) var isPlaying = false
    public private(set) var currentTime: Double = 0
    public private(set) var videoTrackID: Int?
    public private(set) var audioTrackID: Int?
    public private(set) var stats = PlaybackStats()
    /// 当前会话的显示图层，每次打开片源时重建
    public private(set) var displayLayer: AVSampleBufferDisplayLayer?
    public private(set) var subtitleLayer: SubtitleLayer?
    /// 内封与外挂字幕轨道
    public private(set) var subtitleTracks: [SubtitleTrackInfo] = []
    public private(set) var subtitleTrackID: Int?
    /// 能否读取片源所在文件夹；沙盒未授权时无法自动加载同名外挂字幕
    public private(set) var canReadSourceFolder = true
    public private(set) var sourceURL: URL?
    public private(set) var subtitleError: String?
    /// 底部被控制条遮挡的高度，字幕据此上移
    public var subtitleBottomInset: CGFloat = 0 {
        didSet { subtitleLayer?.bottomInset = subtitleBottomInset }
    }

    public var duration: Double { info?.duration ?? 0 }
    public var videoTrack: VideoTrackInfo? { info?.videoTracks.first { $0.id == videoTrackID } }
    public var audioTrack: AudioTrackInfo? { info?.audioTracks.first { $0.id == audioTrackID } }
    public var subtitleTrack: SubtitleTrackInfo? { subtitleTracks.first { $0.id == subtitleTrackID } }

    private var session: PlaybackSession?
    private var scopedURL: URL?
    private var ticker: Task<Void, Never>?
    private var subtitleStores: [Int: SubtitleTrack] = [:]
    private var externalSubtitleURLs: Set<URL> = []
    private var lastSubtitleTrackID: Int?
    private var nextExternalID = SubtitleTrackInfo.externalIDBase

    public init() {}

    /// 打开片源并开始播放；startTime 用于续播
    public func open(url: URL, startTime: Double = 0) {
        close()
        phase = .loading
        title = url.deletingPathExtension().lastPathComponent
        sourceURL = url
        if url.startAccessingSecurityScopedResource() { scopedURL = url }

        let session = PlaybackSession()
        self.session = session
        displayLayer = session.displayLayer
        subtitleLayer = session.subtitleLayer
        session.subtitleLayer.bottomInset = subtitleBottomInset
        Task {
            do {
                let opened = try await session.open(source: try FileByteSource(url: url), startTime: startTime)
                guard self.session === session else { return }
                info = opened.info
                currentTime = session.currentTime
                videoTrackID = opened.videoTrackID
                audioTrackID = opened.audioTrackID
                subtitleTracks = opened.info.subtitleTracks
                session.subtitleLayer.videoSize = videoTrack?.displaySize ?? .zero
                await loadSiblingSubtitles()
                guard self.session === session else { return }
                selectSubtitleTrack(ExternalSubtitles.preferred(subtitleTracks)?.id)
                phase = .ready
                play()
                startTicker()
            } catch {
                guard self.session === session else { return }
                phase = .failed(Self.describe(error))
            }
        }
    }

    public func close() {
        ticker?.cancel()
        ticker = nil
        session?.close()
        session = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        displayLayer = nil
        subtitleLayer = nil
        subtitleTracks = []
        subtitleTrackID = nil
        subtitleStores = [:]
        externalSubtitleURLs = []
        lastSubtitleTrackID = nil
        subtitleError = nil
        canReadSourceFolder = true
        sourceURL = nil
        info = nil
        isPlaying = false
        currentTime = 0
        stats = PlaybackStats()
        phase = .idle
    }

    public func play() {
        guard let session else { return }
        // 播放结束后再次播放时从头开始
        if duration > 0, currentTime >= duration - 0.5 { session.seek(to: 0) }
        session.play()
        isPlaying = true
    }

    public func pause() {
        session?.pause()
        isPlaying = false
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        session?.seek(to: clamped)
    }

    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// 暂停画面解码，声音继续播放（iOS 后台播放时调用）
    public func suspendVideo() {
        session?.suspendVideo()
    }

    /// 恢复画面解码；系统作废了解码会话时同样从当前位置恢复（iOS 回到前台时调用）
    public func resumeVideo() {
        session?.resumeVideo()
    }

    public func selectAudioTrack(_ id: Int) {
        guard id != audioTrackID else { return }
        audioTrackID = id
        session?.selectAudioTrack(id)
    }

    // MARK: - 字幕

    /// 选择字幕轨道；nil 为关闭字幕
    public func selectSubtitleTrack(_ id: Int?) {
        let track = id.flatMap(subtitleStore)
        subtitleTrackID = track != nil ? id : nil
        if let id = subtitleTrackID { lastSubtitleTrackID = id }
        guard let session else { return }
        session.subtitleLayer.track = track
        let embedded = track.flatMap { $0.info.isExternal ? nil : $0.info.id }
        session.selectSubtitle(stream: embedded, track: embedded != nil ? track : nil)
    }

    /// 字幕开关：关闭时恢复上次的轨道，没有则选择默认轨道
    public func toggleSubtitles() {
        if subtitleTrackID != nil {
            selectSubtitleTrack(nil)
        } else {
            let fallback = ExternalSubtitles.preferred(subtitleTracks) ?? subtitleTracks.first { $0.format != nil }
            selectSubtitleTrack(lastSubtitleTrackID ?? fallback?.id)
        }
    }

    /// 添加外挂字幕文件并选中第一个
    public func addSubtitleFiles(_ urls: [URL]) {
        Task {
            let added = await loadSubtitleFiles(urls)
            if let first = added.first { selectSubtitleTrack(first) }
        }
    }

    /// 重新查找同名外挂字幕（获得文件夹访问权限后调用）
    public func reloadSiblingSubtitles() {
        Task {
            await loadSiblingSubtitles()
            if subtitleTrackID == nil { selectSubtitleTrack(ExternalSubtitles.preferred(subtitleTracks)?.id) }
        }
    }

    private func loadSiblingSubtitles() async {
        guard let sourceURL else { return }
        do {
            let urls = try ExternalSubtitles.siblings(of: sourceURL)
            canReadSourceFolder = true
            _ = await loadSubtitleFiles(urls)
        } catch {
            canReadSourceFolder = false
        }
    }

    /// 解析外挂字幕，返回新增轨道的 ID
    private func loadSubtitleFiles(_ urls: [URL]) async -> [Int] {
        let session = self.session
        var added: [Int] = []
        for url in urls where !externalSubtitleURLs.contains(url.standardizedFileURL) {
            let info = ExternalSubtitles.info(for: url, video: sourceURL, id: nextExternalID)
            let result = await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try SubtitleText.load(url: url, info: info) }
            }.value
            guard self.session === session else { return [] }
            switch result {
            case .success(let track):
                nextExternalID += 1
                externalSubtitleURLs.insert(url.standardizedFileURL)
                subtitleStores[track.info.id] = track
                subtitleTracks.append(track.info)
                added.append(track.info.id)
            case .failure(let error):
                subtitleError = "\(error)"
            }
        }
        return added
    }

    /// 获取轨道的数据存储；内封轨道在首次选择时创建，跳转与切换后保留已读取的字幕
    private func subtitleStore(_ id: Int) -> SubtitleTrack? {
        if let track = subtitleStores[id] { return track }
        guard let info = subtitleTracks.first(where: { $0.id == id }), info.format != nil, !info.isExternal else {
            return nil
        }
        let track = SubtitleTrack(info: info, script: info.header.map(ASSScript.init(header:)) ?? .plainText)
        subtitleStores[id] = track
        return track
    }

    private static func describe(_ error: Error) -> String {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .EPERM, .EACCES: return "没有读取这个文件的权限，请通过「打开…」或拖入窗口来选择文件"
            case .ENOENT: return "文件不存在"
            default: break
            }
        }
        return "\(error)"
    }

    /// 定期刷新播放时间与统计数据
    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.session else { return }
                self.currentTime = session.currentTime
                let snapshot = await session.snapshot()
                guard !Task.isCancelled, self.session === session else { return }
                self.stats = snapshot.stats
                if snapshot.finished, self.isPlaying {
                    self.pause()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
