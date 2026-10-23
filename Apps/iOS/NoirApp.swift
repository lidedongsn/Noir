import AVFoundation
import NoirEngine
import SwiftUI
import UniformTypeIdentifiers

@main
struct NoirApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var player = PlayerController()
    @State private var network: NetworkSources
    @State private var library: Library
    @State private var playing = false
    /// 正在播放的网络影片的块缓存目录，清理缓存时保留
    @State private var playingCache: URL?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let network = NetworkSources()
        _network = State(initialValue: network)
        _library = State(initialValue: Library(network: network))
        FolderAccess.restore()
        // 影片播放：不受静音开关影响，允许多声道输出（AirPods 空间音频、AirPlay 功放）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setSupportsMultichannelContent(true)
    }

    var body: some Scene {
        WindowGroup {
            // 播放界面叠在片库之上并以淡入淡出切换（而非系统全屏弹出），旋转在黑场中完成
            ZStack {
                LibraryView(play: play, openFile: { play($0, fromStart: false) })
                    .environment(library)
                    .environment(network)
                if playing {
                    PlayerView(dismiss: closePlayer)
                        .environment(player)
                        .environment(network)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
                // 从「文件」或其他 App 的分享菜单打开
                .onOpenURL { play($0, fromStart: false) }
                .preferredColorScheme(.dark)
                .onAppear {
                        // 网络恢复：正在播放的网络影片立即重试下载，补上之前没截的封面
                        network.onReconnect = {
                            player.network?.retryNow()
                            library.refresh()
                        }
                    }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: library.refresh()
                    case .background: saveProgress()
                    default: break
                    }
                }
        }
    }

    private func play(_ url: URL, fromStart: Bool) {
        if playing { saveProgress() }
        try? AVAudioSession.sharedInstance().setActive(true)
        library.remember(url)
        player.open(url: url, startTime: fromStart ? 0 : library.resumePosition(for: url))
        withAnimation(.easeOut(duration: 0.25)) { playing = true }
    }

    private func play(_ item: Library.Item, fromStart: Bool) {
        guard let server = item.server else { return play(item.url, fromStart: fromStart) }
        guard let webdav = network.client(for: server), let version = item.version,
              let cache = network.cache(server: server, key: item.key, size: item.size, version: version) else { return }
        if playing { saveProgress() }
        try? AVAudioSession.sharedInstance().setActive(true)
        library.remember(remote: item)
        // 先为这部影片腾出缓存空间
        setPlayingCache(cache.directory)
        network.pruneCache(reserving: min(network.cacheLimitBytes, item.size))
        let entry = WebDAVEntry(url: item.url, name: item.url.lastPathComponent, isDirectory: false,
                                size: item.size, modified: item.date, etag: nil)
        player.open(remote: entry, webdav: webdav, cache: cache, startTime: fromStart ? 0 : library.resumePosition(for: item.url))
        withAnimation(.easeOut(duration: 0.25)) { playing = true }
    }

    private func setPlayingCache(_ directory: URL?) {
        if let playingCache { network.activeCaches.remove(playingCache) }
        playingCache = directory
        if let directory { network.activeCaches.insert(directory) }
    }

    private func closePlayer() {
        saveProgress()
        withAnimation(.easeOut(duration: 0.25)) { playing = false }
        player.close()
        setPlayingCache(nil)
        network.pruneCache()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 记录当前影片的播放位置，供下次续播
    private func saveProgress() {
        guard let url = player.sourceURL, player.phase == .ready else { return }
        library.saveProgress(for: url, position: player.currentTime, duration: player.duration)
    }
}

/// 支持的视频文件类型
enum VideoFiles {
    static let extensions: Set<String> = ["mkv", "mp4", "m4v", "mov"]
    static let contentTypes: [UTType] = [.movie, UTType(filenameExtension: "mkv") ?? .movie]
}

/// 外挂字幕文件类型
enum SubtitleFiles {
    static let contentTypes = ["srt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
}

/// 界面方向由当前页面决定：片库固定竖屏，播放时随手机方向在竖屏与横屏全屏间切换（竖拍画面固定竖屏）
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }

    /// 转到指定方向，允许的方向不变（之后仍随手机方向自动旋转）
    static func rotate(to mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    static func lock(_ mask: UIInterfaceOrientationMask) {
        orientations = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
