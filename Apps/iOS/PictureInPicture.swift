import AVKit
import NoirEngine
import Observation
import Synchronization

/// 画中画：基于播放会话的 AVSampleBufferDisplayLayer，播放控制回传给 PlayerController。
/// 字幕是独立图层，不随画面进入画中画窗口。
@MainActor @Observable
final class PictureInPicture: NSObject {
    private(set) var isActive = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var player: PlayerController?
    @ObservationIgnored private weak var layer: AVSampleBufferDisplayLayer?
    /// 系统可能在任意线程查询播放状态，先在主线程缓存
    private struct State {
        var duration: Double = 0
        var paused = true
        /// 用户点了画中画窗口的「还原」按钮
        var restoring = false
    }
    @ObservationIgnored private nonisolated let state = Mutex(State())

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// 绑定当前会话的显示图层；每次打开片源时图层都会重建
    func attach(_ layer: AVSampleBufferDisplayLayer?, player: PlayerController) {
        guard layer !== self.layer else { return }
        controller?.stopPictureInPicture()
        controller = nil
        self.layer = layer
        self.player = player
        invalidate()
        guard let layer, Self.isSupported else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // 播放中回到桌面时自动进入画中画
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
    }

    func start() {
        controller?.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    /// 播放状态或时长变化后通知系统刷新画中画窗口的控件
    func invalidate() {
        state.withLock {
            $0.duration = player?.duration ?? 0
            $0.paused = !(player?.isPlaying ?? false)
        }
        controller?.invalidatePlaybackState()
    }
}

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        state.withLock { $0.paused = !playing }
        Task { @MainActor in
            playing ? player?.play() : player?.pause()
            invalidate()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: state.withLock(\.duration), preferredTimescale: 600))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        state.withLock(\.paused)
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
    ) {
        let seconds = skipInterval.seconds
        Task { @MainActor in player?.skip(by: seconds) }
        completionHandler()
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        state.withLock { $0.restoring = false }
        Task { @MainActor in isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let restoring = state.withLock { state in
            defer { state.restoring = false }
            return state.restoring
        }
        Task { @MainActor in
            isActive = false
            // 直接关闭画中画窗口（而非还原到 App）时暂停，与系统播放器一致
            if !restoring { player?.pause() }
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 播放界面在画中画期间一直保留，无需重建
        state.withLock { $0.restoring = true }
        completionHandler(true)
    }
}
