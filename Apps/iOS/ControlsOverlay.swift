import NoirEngine
import SwiftUI

/// 播放控件：顶部关闭、标题与轨道菜单，中部播放控制，底部进度条。
/// 竖屏时控件排布在画面范围内，顶部按钮精简，底部带横屏全屏按钮。
struct ControlsOverlay: View {
    @Environment(PlayerController.self) private var player
    @Binding var showsInfo: Bool
    @Binding var fills: Bool
    let pip: PictureInPicture
    /// 竖屏
    let compact: Bool
    let dismiss: () -> Void
    /// 全屏时左上角退出全屏；nil 时为关闭（竖拍画面没有竖屏布局）
    let exitFullscreen: (() -> Void)?
    let enterFullscreen: () -> Void
    /// 每次操作时调用，推迟控件自动隐藏
    let poke: () -> Void

    var body: some View {
        ZStack {
            // 上下暗角保证控件在亮场景下可读
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: compact ? 56 : 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: compact ? 64 : 140)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                if compact {
                    HStack {
                        IconButton("chevron.down", action: dismiss)
                        Spacer()
                        SubtitleMenu()
                        AudioTrackMenu()
                        if PictureInPicture.isSupported {
                            IconButton("pip.enter") { pip.start() }
                        }
                    }
                } else {
                    TopBar(showsInfo: $showsInfo, fills: $fills, pip: pip,
                           leading: exitFullscreen.map { ("chevron.left", $0) } ?? ("xmark", dismiss), poke: poke)
                }
                Spacer()
                TransportButtons(poke: poke)
                Spacer()
                BottomBar(fullscreen: compact ? enterFullscreen : nil, poke: poke)
            }
            .padding(.horizontal, compact ? 8 : 20)
            .padding(.vertical, compact ? 0 : 12)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - 顶部

private struct TopBar: View {
    @Environment(PlayerController.self) private var player
    @Binding var showsInfo: Bool
    @Binding var fills: Bool
    let pip: PictureInPicture
    /// 左上角按钮：退出全屏或关闭
    let leading: (symbol: String, action: () -> Void)
    let poke: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            IconButton(leading.symbol, action: leading.action)
            Text(player.title ?? "")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 6)
            Spacer(minLength: 16)
            SubtitleMenu()
            AudioTrackMenu()
            if PictureInPicture.isSupported {
                IconButton("pip.enter") { pip.start() }
            }
            IconButton(fills ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                withAnimation { fills.toggle() }
                poke()
            }
            IconButton(showsInfo ? "info.circle.fill" : "info.circle") {
                withAnimation(.easeOut(duration: 0.2)) { showsInfo.toggle() }
                poke()
            }
        }
    }
}

// MARK: - 中部

private struct TransportButtons: View {
    @Environment(PlayerController.self) private var player
    let poke: () -> Void

    var body: some View {
        HStack(spacing: 64) {
            IconButton("gobackward.10", size: 26) {
                player.skip(by: -10)
                poke()
            }
            IconButton(player.isPlaying ? "pause.fill" : "play.fill", size: 40) {
                player.togglePlayPause()
                poke()
            }
            .contentTransition(.symbolEffect(.replace))
            IconButton("goforward.10", size: 26) {
                player.skip(by: 10)
                poke()
            }
        }
    }
}

// MARK: - 底部

private struct BottomBar: View {
    @Environment(PlayerController.self) private var player
    /// 竖屏时显示横屏全屏按钮
    let fullscreen: (() -> Void)?
    let poke: () -> Void
    @State private var dragFraction: Double?

    var body: some View {
        let duration = max(player.duration, 0.001)
        let current = dragFraction.map { $0 * duration } ?? player.currentTime
        HStack(spacing: fullscreen == nil ? 12 : 6) {
            TimeText(current)
            ScrubBar(dragFraction: $dragFraction, poke: poke)
            TimeText(current - player.duration)
            if let fullscreen {
                IconButton("arrow.up.left.and.arrow.down.right", size: 15, action: fullscreen)
            }
        }
    }
}

private struct TimeText: View {
    let seconds: Double

    init(_ seconds: Double) { self.seconds = seconds }

    var body: some View {
        Text(formatTime(seconds))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .frame(minWidth: 52)
    }
}

/// 进度条：按住拖动，松手跳转
private struct ScrubBar: View {
    @Environment(PlayerController.self) private var player
    @Binding var dragFraction: Double?
    let poke: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(player.duration, 0.001)
            let played = dragFraction ?? min(max(player.currentTime / duration, 0), 1)
            let dragging = dragFraction != nil

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: max(width * played, 4))
                Circle().fill(.white)
                    .frame(width: dragging ? 18 : 12, height: dragging ? 18 : 12)
                    .offset(x: width * played - (dragging ? 9 : 6))
            }
            .frame(height: dragging ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged {
                        dragFraction = min(max($0.location.x / width, 0), 1)
                        poke()
                    }
                    .onEnded { value in
                        player.seek(to: min(max(value.location.x / width, 0), 1) * duration)
                        dragFraction = nil
                        poke()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 36)
    }
}

// MARK: - 按钮

private struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    init(_ symbol: String, size: CGFloat = 17, action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: max(size + 24, 44), height: max(size + 24, 44))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

/// 按下缩放反馈
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - 字幕

private struct SubtitleMenu: View {
    @Environment(PlayerController.self) private var player
    @State private var importingFiles = false
    @State private var importingFolder = false

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
            Section {
                Button("添加字幕文件…", systemImage: "doc.badge.plus") { importingFiles = true }
                if !player.canReadSourceFolder {
                    Button("自动加载同名字幕…", systemImage: "folder.badge.plus") { importingFolder = true }
                }
            }
        } label: {
            Image(systemName: player.subtitleTrackID != nil ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .subtitleImporters(files: $importingFiles, folder: $importingFolder, player: player)
    }
}

extension View {
    /// 添加外挂字幕文件、授权影片所在文件夹（自动加载同名字幕）的文件选择器
    func subtitleImporters(files: Binding<Bool>, folder: Binding<Bool>, player: PlayerController) -> some View {
        fileImporter(isPresented: files, allowedContentTypes: SubtitleFiles.contentTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { player.addSubtitleFiles(urls) }
        }
        // 同一视图上只有一个 fileImporter 生效，文件夹选择挂在背景视图上
        .background {
            Color.clear.fileImporter(isPresented: folder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { FolderAccess.authorize(url, for: player) }
            }
        }
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
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .opacity(tracks.count < 2 ? 0.35 : 1)
        .disabled(tracks.count < 2)
    }
}
