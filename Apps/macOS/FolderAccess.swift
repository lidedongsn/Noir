import AppKit
import NoirEngine

/// 文件夹访问授权。沙盒下只能读取用户选择的文件；用户授权某个文件夹后，
/// 其中所有视频的同名外挂字幕都可自动加载。授权以安全范围书签保存，启动时恢复。
@MainActor
enum FolderAccess {
    private static let key = "authorizedFolders"
    private static var active: [URL] = []

    /// 恢复已保存的授权
    static func restore() {
        let bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        var valid: [Data] = []
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            active.append(url)
            valid.append(stale ? (try? bookmarkData(url)) ?? bookmark : bookmark)
        }
        UserDefaults.standard.set(valid, forKey: key)
    }

    /// 请求授权片源所在文件夹，成功后重新查找外挂字幕
    static func authorize(for player: PlayerController) {
        guard let source = player.sourceURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.deletingLastPathComponent()
        panel.message = "授权后，墨影会自动加载此文件夹（含子文件夹）中与视频同名的字幕文件"
        panel.prompt = "授权"
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? bookmarkData(url) else { return }
        if url.startAccessingSecurityScopedResource() { active.append(url) }
        var bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        bookmarks.append(bookmark)
        UserDefaults.standard.set(bookmarks, forKey: key)
        player.reloadSiblingSubtitles()
    }

    private static func bookmarkData(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
    }
}
