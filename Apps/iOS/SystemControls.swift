import AVFoundation
import MediaPlayer
import NoirEngine
import SwiftUI

// MARK: - 亮度与音量

/// 屏幕亮度
@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    static var value: Double {
        get { Double(screen?.brightness ?? 0.5) }
        set { screen?.brightness = CGFloat(min(max(newValue, 0), 1)) }
    }
}

/// 系统音量。iOS 没有直接设置系统音量的接口，通过 MPVolumeView 内部的滑块调整；
/// 该视图在界面中时，系统不再弹出自带的音量提示。
@MainActor
enum SystemVolume {
    fileprivate static let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 40, height: 40))

    static var value: Double {
        get { Double(AVAudioSession.sharedInstance().outputVolume) }
        set {
            guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
            slider.value = Float(min(max(newValue, 0), 1))
            slider.sendActions(for: .valueChanged)
        }
    }
}

/// 放入播放界面，使 SystemVolume 生效并隐藏系统音量提示
struct VolumeViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        host.addSubview(SystemVolume.view)
        // 几乎透明但不隐藏，隐藏时系统仍会显示音量提示
        SystemVolume.view.alpha = 0.01
        return host
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

// MARK: - 锁屏与控制中心

/// 锁屏、控制中心与耳机线控的「正在播放」信息与远程控制
@MainActor
final class NowPlaying {
    private weak var player: PlayerController?
    private var targets: [(MPRemoteCommand, Any)] = []

    func activate(_ player: PlayerController) {
        guard targets.isEmpty else { return }
        self.player = player
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.playCommand) { $0.play() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        add(center.skipForwardCommand) { $0.skip(by: 10) }
        add(center.skipBackwardCommand) { $0.skip(by: -10) }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.player?.seek(to: position) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, target))
    }

    func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 更新标题、时长、当前位置与速率；系统据速率自行推算进度，无需频繁刷新
    func update() {
        guard let player, player.phase == .ready else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: player.title ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let player = self?.player else { return }
                action(player)
                self?.update()
            }
            return .success
        }
        targets.append((command, target))
    }
}
