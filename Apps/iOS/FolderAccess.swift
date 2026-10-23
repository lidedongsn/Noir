import Foundation
import NoirEngine

/// 文件夹访问授权。从其他位置打开的影片只能读取该文件本身；用户授权其所在文件夹后，
/// 同名外挂字幕可自动加载。授权以书签保存，启动时恢复。
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
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            active.append(url)
            valid.append(stale ? (try? url.bookmarkData()) ?? bookmark : bookmark)
        }
        UserDefaults.standard.set(valid, forKey: key)
    }

    /// 保存用户在文件夹选择器中选择的文件夹，并重新查找外挂字幕
    static func authorize(_ url: URL, for player: PlayerController) {
        guard url.startAccessingSecurityScopedResource() else { return }
        active.append(url)
        if let bookmark = try? url.bookmarkData() {
            var bookmarks = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
            bookmarks.append(bookmark)
            UserDefaults.standard.set(bookmarks, forKey: key)
        }
        player.reloadSiblingSubtitles()
    }
}
