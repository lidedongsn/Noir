import NoirEngine
import SwiftUI

/// 主播放视图。播放中鼠标静止 2 秒后自动隐藏控件。
struct PlayerView: View {
    @Environment(PlayerController.self) private var player
    @State private var controlsVisible = true
    @State private var lastActivity = Date.now
    @State private var showsInfo = false
    @FocusState private var focused: Bool

    private var chromeVisible: Bool {
        player.phase != .ready || controlsVisible || !player.isPlaying
    }

    var body: some View {
        ZStack {
            Color.black

            VideoSurface(displayLayer: player.displayLayer, subtitleLayer: player.subtitleLayer)
                .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }

            switch player.phase {
            case .idle: EmptyStateView()
            case .loading: ProgressView().controlSize(.small).tint(.white)
            case .failed(let message): FailureView(message: message)
            case .ready: EmptyView()
            }

            if player.phase == .ready {
                VStack(spacing: 0) {
                    TitleBar(title: player.title ?? "")
                    Spacer()
                    ControlsBar(showsInfo: $showsInfo)
                        .offset(y: chromeVisible ? 0 : 8)
                }
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: chromeVisible)

                if showsInfo {
                    InfoPanel()
                        .padding(.top, 52)
                        .padding(.leading, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .windowAspectRatio(player.phase == .ready ? player.videoTrack?.displaySize : nil)
        .windowButtonsHidden(!chromeVisible)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onContinuousHover { _ in registerActivity() }
        .onKeyPress(characters: ["i", "I"]) { _ in
            withAnimation(.easeOut(duration: 0.2)) { showsInfo.toggle() }
            return .handled
        }
        .onKeyPress(characters: ["s", "S"]) { _ in
            player.toggleSubtitles()
            return .handled
        }
        .onKeyPress(characters: ["f", "F"]) { _ in
            NSApp.keyWindow?.toggleFullScreen(nil)
            return .handled
        }
        .onKeyPress(.escape) {
            guard let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) else { return .ignored }
            window.toggleFullScreen(nil)
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            // 拖入字幕文件时加载到当前片源，否则作为视频打开
            let subtitles = urls.filter { SubtitleFiles.extensions.contains($0.pathExtension.lowercased()) }
            if !subtitles.isEmpty, player.phase == .ready {
                player.addSubtitleFiles(subtitles)
                return true
            }
            guard let url = urls.first(where: { !subtitles.contains($0) }) else { return false }
            player.open(url: url)
            return true
        }
        // 控制条显示时，底部字幕上移避让
        .onChange(of: chromeVisible, initial: true) { _, visible in
            player.subtitleBottomInset = visible ? 72 : 0
        }
        .task(id: player.isPlaying) { await autoHide() }
    }

    private func registerActivity() {
        lastActivity = .now
        if !controlsVisible { controlsVisible = true }
    }

    private func autoHide() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if player.isPlaying, controlsVisible, Date.now.timeIntervalSince(lastActivity) > 2 {
                controlsVisible = false
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

// MARK: - 空状态与错误

private struct EmptyStateView: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(spacing: 18) {
            Text("墨影")
                .font(.system(size: 46, weight: .ultraLight, design: .serif))
                .foregroundStyle(.white.opacity(0.92))
            Text("NOIR")
                .font(.system(size: 12, weight: .light))
                .tracking(10)
                .foregroundStyle(.white.opacity(0.45))
            Text("拖入视频，或按 ⌘O 打开")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 28)
        }
        .contentShape(Rectangle())
        .onTapGesture { OpenPanel.present(player) }
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text("无法播放")
                .font(.headline)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: 420)
        }
        .foregroundStyle(.white.opacity(0.85))
    }
}

private struct TitleBar: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .padding(.horizontal, 90) // 避开窗口标准按钮
            .background(
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
            )
            .allowsHitTesting(false)
    }
}
