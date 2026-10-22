import NoirEngine
import SwiftUI

/// 悬浮于画面底部的播放控制条
struct ControlsBar: View {
    @Environment(PlayerController.self) private var player
    @Binding var showsInfo: Bool

    var body: some View {
        HStack(spacing: 4) {
            HUDButton("gobackward.10", size: 13, help: "快退 10 秒（←）") { player.skip(by: -10) }
            HUDButton(player.isPlaying ? "pause.fill" : "play.fill", size: 16, help: "播放 / 暂停（空格）") {
                player.togglePlayPause()
            }
            .contentTransition(.symbolEffect(.replace))
            HUDButton("goforward.10", size: 13, help: "快进 10 秒（→）") { player.skip(by: 10) }

            TimeText(player.currentTime)
                .frame(width: 48, alignment: .trailing)
                .padding(.leading, 6)
            ScrubBar()
                .padding(.horizontal, 8)
            TimeText(player.currentTime - player.duration)
                .frame(width: 48, alignment: .leading)
                .padding(.trailing, 6)

            SubtitleMenu()
            AudioTrackMenu()
            HUDButton(showsInfo ? "info.circle.fill" : "info.circle", size: 13, help: "信息面板（I）") {
                withAnimation(.easeOut(duration: 0.2)) { showsInfo.toggle() }
            }
            HUDButton("arrow.up.left.and.arrow.down.right", size: 12, help: "全屏（F）") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .frame(maxWidth: 600)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                // 叠加轻度暗化，保证亮场景下控件可读
                .overlay(Capsule(style: .continuous).fill(.black.opacity(0.18)))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.07)))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}

// MARK: - 按钮

private struct HUDButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    init(_ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size + 18, height: size + 18)
        }
        .buttonStyle(HUDButtonStyle())
        .help(help)
    }
}

/// 控制条按钮样式：悬停高亮，按下缩放反馈
struct HUDButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.86))
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.spring(duration: 0.2), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - 时间

private struct TimeText: View {
    let seconds: Double

    init(_ seconds: Double) { self.seconds = seconds }

    var body: some View {
        Text(formatTime(seconds))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.62))
    }
}

/// 格式化时间；负值表示剩余时间（如 -1:23）
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let sign = seconds < -0.5 ? "-" : ""
    let s = Int(abs(seconds).rounded(.down))
    return sign + (s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60))
}

// MARK: - 进度条

/// 进度条：悬停时加粗并显示滑块与时间提示，拖动结束后执行跳转。
private struct ScrubBar: View {
    @Environment(PlayerController.self) private var player
    @State private var dragFraction: Double?
    @State private var hoverFraction: Double?

    private var active: Bool { hoverFraction != nil || dragFraction != nil }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(player.duration, 0.001)
            let played = dragFraction ?? min(max(player.currentTime / duration, 0), 1)
            let height: CGFloat = active ? 3 : 2

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(.white.opacity(0.7))
                    .frame(width: max(width * played, height))
                Circle().fill(.white)
                    .frame(width: 9, height: 9)
                    .offset(x: width * played - 4.5)
                    .scaleEffect(active ? 1 : 0.01)
                    .opacity(active ? 1 : 0)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let fraction = dragFraction ?? hoverFraction {
                    TimeBubble(text: formatTime(fraction * duration))
                        .offset(x: min(max(width * fraction - 28, -8), width - 48), y: -26)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverFraction = min(max(point.x / width, 0), 1)
                case .ended: hoverFraction = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / width, 0), 1) }
                    .onEnded { value in
                        player.seek(to: min(max(value.location.x / width, 0), 1) * duration)
                        dragFraction = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 18)
    }
}

private struct TimeBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.75), in: Capsule())
            .fixedSize()
    }
}

// MARK: - 字幕

private struct SubtitleMenu: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        Menu {
            Section("字幕") {
                Toggle("关闭", isOn: Binding(
                    get: { player.subtitleTrackID == nil },
                    set: { if $0 { player.selectSubtitleTrack(nil) } }
                ))
                ForEach(player.subtitleTracks) { track in
                    Toggle(isOn: Binding(
                        get: { track.id == player.subtitleTrackID },
                        set: { if $0 { player.selectSubtitleTrack(track.id) } }
                    )) {
                        Text(track.displayName)
                    }
                    .disabled(track.format == nil)
                }
            }
            Divider()
            Button("添加字幕文件…") { SubtitleFiles.present(player) }
            if !player.canReadSourceFolder {
                Button("自动加载同名字幕…") { FolderAccess.authorize(for: player) }
            }
        } label: {
            Image(systemName: player.subtitleTrackID != nil ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 31, height: 31)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HUDButtonStyle())
        .fixedSize()
        .help("字幕（S）")
    }
}

// MARK: - 音轨

private struct AudioTrackMenu: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let tracks = player.info?.audioTracks ?? []
        Menu {
            Section("音轨") {
                ForEach(tracks) { track in
                    Toggle(isOn: Binding(
                        get: { track.id == player.audioTrackID },
                        set: { if $0 { player.selectAudioTrack(track.id) } }
                    )) {
                        Text(track.displayName)
                    }
                    .disabled(track.route == .unsupported)
                }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 31, height: 31)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(HUDButtonStyle())
        .fixedSize()
        .opacity(tracks.count < 2 ? 0.35 : 1)
        .disabled(tracks.count < 2)
        .help("音轨")
    }
}
