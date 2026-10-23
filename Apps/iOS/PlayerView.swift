import AVFoundation
import NoirEngine
import SwiftUI

/// 播放视图。竖屏时画面居中、控件排布在画面范围内，横屏时全屏，随手机方向切换，也可按按钮切换。
/// 单击显示/隐藏控件，双击暂停，左右滑动快进快退，左半边上下滑动调亮度、右半边调音量，双指捏合切换填满屏幕。
struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    let dismiss: () -> Void

    @State private var controlsVisible = true
    @State private var lastActivity = Date.now
    @State private var showsInfo = false
    @State private var fills = false
    /// 当前滑动手势；方向在开始滑动时确定，松手前不变
    @State private var pan: Pan?
    /// 按实体音量键时显示的音量（系统音量提示被 VolumeViewHost 屏蔽，由此代替）
    @State private var keyVolume: Double?
    @State private var keyVolumeHide: Task<Void, Never>?
    /// 整个界面与画面区域的尺寸
    @State private var screen = CGSize(width: 1, height: 1)
    @State private var stage = CGSize(width: 1, height: 1)
    @State private var pip = PictureInPicture()
    /// 正在退出：控件淡出，横屏时画面随旋转动画转回竖屏后再关闭，避免露出横屏状态的片库
    @State private var closing = false
    @State private var dismissed = false
    @State private var nowPlaying = NowPlaying()

    private enum Pan {
        /// 左右滑动快进快退：起点与目标时间
        case seek(from: Double, to: Double)
        case brightness(start: Double, value: Double)
        case volume(start: Double, value: Double)
    }

    private var chromeVisible: Bool {
        player.phase != .ready || controlsVisible || !player.isPlaying
    }

    /// 竖拍画面竖着拿手机时即为全屏
    private var isVerticalVideo: Bool {
        player.videoTrack.map { $0.displaySize.height > $0.displaySize.width } ?? false
    }

    private var isFullscreen: Bool {
        screen.width > screen.height || isVerticalVideo
    }

    /// 竖屏时控件区域的高度：画面高度，过扁的画面至少留出三行控件的空间
    private var portraitControlsHeight: CGFloat {
        let size = player.videoTrack?.displaySize ?? CGSize(width: 16, height: 9)
        let height = size.width > 0 ? screen.width * size.height / size.width : 0
        return max(height, 240)
    }

    var body: some View {
        let fullscreen = isFullscreen
        // 竖屏与横屏都是整屏播放器，竖屏时画面居中、上下留黑边
        stageView(fullscreen: fullscreen)
            .ignoresSafeArea()
        .background { VolumeViewHost().frame(width: 1, height: 1) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            screen = newSize
            // 布局尺寸在旋转动画开始时就已是最终尺寸，等动画结束后再关闭
            if closing, newSize.height > newSize.width { afterRotation(finishClose) }
        }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .onAppear {
            // 播放时随手机方向在竖屏与横屏全屏间切换
            AppDelegate.lock(.allButUpsideDown)
            nowPlaying.activate(player)
        }
        .onDisappear {
            AppDelegate.lock(.portrait)
            UIApplication.shared.isIdleTimerDisabled = false
            pip.attach(nil, player: player)
            nowPlaying.deactivate()
        }
        .onChange(of: player.displayLayer, initial: true) { _, layer in
            pip.attach(layer, player: player)
        }
        // 同步画中画窗口与锁屏的播放状态
        .onChange(of: player.isPlaying) {
            pip.invalidate()
            nowPlaying.update()
        }
        .onChange(of: player.phase) {
            pip.invalidate()
            nowPlaying.update()
        }
        // 竖拍画面只用竖屏
        .onChange(of: isVerticalVideo) { _, vertical in
            AppDelegate.lock(vertical ? .portrait : .allButUpsideDown)
        }
        // 播放时屏幕不自动锁定
        .onChange(of: player.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        // 控件显示时，底部字幕上移避让控制条
        .onChange(of: chromeVisible && !closing, initial: true) { _, visible in
            player.subtitleBottomInset = visible ? 96 : 0
        }
        .onChange(of: fullscreen) { _, fullscreen in
            if !fullscreen { showsInfo = false }
            player.subtitleBottomInset = chromeVisible ? 96 : 0
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            // 画中画时继续解码画面；否则只播放声音，画面在回到前台时恢复
            case .background:
                if !pip.isActive { player.suspendVideo() }
                nowPlaying.update()
            case .active: player.resumeVideo()
            default: break
            }
        }
        // 来电等音频中断、拔出耳机时暂停
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .began { player.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            if reason == .oldDeviceUnavailable { player.pause() }
        }
        // 实体音量键：系统音量变化且不是滑动手势引起时，显示音量条，1.2 秒后淡出
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume, options: [.new])) { volume in
            if case .volume = pan { return }
            keyVolumeHide?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { keyVolume = Double(volume) }
            keyVolumeHide = Task {
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { keyVolume = nil }
            }
        }
        .task(id: player.isPlaying) { await autoHide() }
    }

    /// 画面区域：视频、控件与各种提示，竖屏与横屏共用同一视图
    private func stageView(fullscreen: Bool) -> some View {
        ZStack {
            Color.black
            VideoSurface(displayLayer: player.displayLayer, subtitleLayer: player.subtitleLayer, fills: fills,
                         videoSize: player.videoTrack?.displaySize)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    player.togglePlayPause()
                    poke()
                }
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        controlsVisible = !chromeVisible
                        if !controlsVisible { showsInfo = false }
                    }
                    lastActivity = .now
                }
                .gesture(panGesture)
                .simultaneousGesture(
                    MagnifyGesture().onEnded { value in
                        if value.magnification > 1.1 { fills = true }
                        if value.magnification < 0.9 { fills = false }
                    }
                )

            switch player.phase {
            case .idle, .loading: ProgressView().tint(.white)
            case .failed(let message): FailureView(message: message, dismiss: close)
            case .ready: EmptyView()
            }

            if player.phase == .ready {
                ControlsOverlay(
                    showsInfo: $showsInfo, fills: $fills, pip: pip, compact: !fullscreen, dismiss: close,
                    exitFullscreen: isVerticalVideo ? nil : { rotate(to: .portrait) },
                    enterFullscreen: { rotate(to: .landscapeRight) }, poke: poke
                )
                // 竖屏时控件围绕画面排布，不贴到屏幕上下边缘
                .frame(height: fullscreen ? nil : portraitControlsHeight)
                .opacity(chromeVisible && !closing ? 1 : 0)
                .allowsHitTesting(chromeVisible && !closing)
                .animation(.easeOut(duration: 0.25), value: chromeVisible)

                if showsInfo, fullscreen {
                    InfoPanel()
                        .padding(.vertical, 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 16)
                        .transition(.opacity)
                }
            }

            switch pan {
            case .seek(let from, let to):
                ScrubHUD(from: from, to: to).allowsHitTesting(false)
            case .brightness(_, let value):
                LevelHUD(symbol: "sun.max.fill", value: value).allowsHitTesting(false)
            case .volume(_, let value):
                LevelHUD(symbol: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", value: value).allowsHitTesting(false)
            case nil:
                if let keyVolume {
                    LevelHUD(symbol: keyVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", value: keyVolume)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stage = $0 }
    }

    /// 水平滑动快进快退（画面宽度对应 3 分钟，松手后跳转）；
    /// 垂直滑动在左半边调亮度、右半边调音量（滑过画面高度的 70% 为全程）
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard player.phase == .ready else { return }
                let dx = value.translation.width, dy = value.translation.height
                let vertical = -Double(dy / max(stage.height * 0.7, 1))
                switch pan {
                case nil:
                    if abs(dx) > abs(dy) {
                        pan = .seek(from: player.currentTime, to: player.currentTime)
                    } else if value.startLocation.x < stage.width / 2 {
                        pan = .brightness(start: ScreenBrightness.value, value: ScreenBrightness.value)
                    } else {
                        pan = .volume(start: SystemVolume.value, value: SystemVolume.value)
                    }
                case .seek(let from, _):
                    let to = from + Double(dx / max(stage.width, 1)) * 180
                    pan = .seek(from: from, to: min(max(to, 0), player.duration))
                case .brightness(let start, _):
                    let value = min(max(start + vertical, 0), 1)
                    ScreenBrightness.value = value
                    pan = .brightness(start: start, value: value)
                case .volume(let start, _):
                    let value = min(max(start + vertical, 0), 1)
                    SystemVolume.value = value
                    pan = .volume(start: start, value: value)
                }
            }
            .onEnded { _ in
                if case .seek(_, let to) = pan {
                    player.seek(to: to)
                    poke()
                }
                withAnimation(.easeOut(duration: 0.2)) { pan = nil }
            }
    }

    /// 按钮切换竖屏与横屏全屏：转到指定方向，之后仍随手机方向自动切换
    private func rotate(to orientation: UIInterfaceOrientationMask) {
        AppDelegate.rotate(to: orientation)
        poke()
    }

    /// 系统旋转动画约 0.4 秒
    private func afterRotation(_ action: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    /// 退出播放：控件淡出，横屏时画面随旋转动画转回竖屏，转完再淡出关闭
    private func close() {
        guard !closing else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            closing = true
            showsInfo = false
        }
        Task {
            guard screen.width > screen.height else { return finishClose() }
            AppDelegate.lock(.portrait)
            // 系统未旋转时兜底
            try? await Task.sleep(for: .milliseconds(1200))
            finishClose()
        }
    }

    private func finishClose() {
        guard !dismissed else { return }
        dismissed = true
        dismiss()
    }

    /// 记录操作，推迟自动隐藏
    private func poke() {
        lastActivity = .now
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
    }

    private func autoHide() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if player.isPlaying, controlsVisible, !showsInfo, Date.now.timeIntervalSince(lastActivity) > 3 {
                withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
    }
}

// MARK: - 滑动跳转提示

private struct ScrubHUD: View {
    let from: Double
    let to: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(formatTime(to))
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
            Text((to >= from ? "+" : "-") + formatTime(abs(to - from)))
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 14))
    }
}

/// 亮度、音量提示
private struct LevelHUD: View {
    let symbol: String
    let value: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 24)
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 140, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: 140 * value, height: 4)
                }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - 错误

private struct FailureView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text("无法播放")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 420)
            Button("返回", action: dismiss)
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}
