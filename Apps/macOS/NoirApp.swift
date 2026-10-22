import NoirEngine
import SwiftUI
import UniformTypeIdentifiers

@main
struct NoirApp: App {
    @State private var player = PlayerController()

    init() {
        FolderAccess.restore()
    }

    var body: some Scene {
        Window("墨影", id: "player") {
            PlayerView()
                .environment(player)
                .onOpenURL { player.open(url: $0) }
                // 最小尺寸需容纳 2.39:1 宽银幕比例
                .frame(minWidth: 480, minHeight: 200)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        // 启动时始终显示主窗口，不恢复上次的窗口状态
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") { OpenPanel.present(player) }
                    .keyboardShortcut("o")
            }
            CommandMenu("播放") {
                Button(player.isPlaying ? "暂停" : "播放") { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.phase != .ready)
                Button("快退 10 秒") { player.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(player.phase != .ready)
                Button("快进 10 秒") { player.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(player.phase != .ready)
                Divider()
                Button(player.subtitleTrackID != nil ? "隐藏字幕" : "显示字幕") { player.toggleSubtitles() }
                    .disabled(player.phase != .ready || player.subtitleTracks.isEmpty)
                Button("添加字幕文件…") { SubtitleFiles.present(player) }
                    .disabled(player.phase != .ready)
            }
        }
    }
}

/// 外挂字幕文件选择
enum SubtitleFiles {
    static let extensions = ["srt", "ass", "ssa"]
    static let contentTypes = extensions.compactMap { UTType(filenameExtension: $0) }

    @MainActor
    static func present(_ player: PlayerController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = player.sourceURL?.deletingLastPathComponent()
        if panel.runModal() == .OK {
            player.addSubtitleFiles(panel.urls)
        }
    }
}

enum OpenPanel {
    static let contentTypes: [UTType] = [.movie, UTType(filenameExtension: "mkv") ?? .movie]

    @MainActor
    static func present(_ player: PlayerController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            player.open(url: url)
        }
    }
}
