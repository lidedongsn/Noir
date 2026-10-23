import CryptoKit
import Foundation
import ImageIO
import NoirEngine
import Observation
import UIKit

/// 片库：墨影文件夹（App 的 Documents，在「文件」App 中显示为「我的 iPhone › 墨影」）中的影片，
/// 以及从其他位置打开过的影片。其他位置的文件以书签保存，下次无需重新选择。
/// 同时管理封面、媒体标签与播放进度：封面缓存在 Caches 目录，影片不在片库中后随之删除；
/// 内存中只保留最近显示的封面，按显示尺寸解码。
@MainActor @Observable
final class Library {
    struct Item: Identifiable, Hashable {
        var url: URL
        var name: String
        var size: Int64
        var date: Date
        var id: URL { url }
        /// 文件名加大小标识同一部影片，文件被移动或重新授权后封面与进度仍可对应
        var key: String { "\(url.lastPathComponent)|\(size)" }
    }

    /// 封面与媒体标签
    struct Details: Codable {
        var duration: Double?
        var tags: [String]
        var hasImage: Bool
    }

    /// 播放进度
    struct Progress: Codable {
        var position: Double
        var duration: Double
        var date: Date

        var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }
        var remaining: Double { max(duration - position, 0) }
    }

    /// 墨影文件夹中的影片，按修改时间倒序
    private(set) var local: [Item] = []
    /// 从其他位置打开过的影片，最近的在前
    private(set) var recent: [Item] = []
    private(set) var details: [String: Details] = [:]
    /// 本次读取失败的影片，下次刷新时重试
    private(set) var failed: Set<String> = []
    /// 续播封面（上次看到的画面）的生成时间，变化时界面重新读取
    private(set) var resumeStamps: [String: Date] = [:]
    private(set) var progress: [String: Progress] = [:]

    /// 最近一部未看完的影片
    var continueWatching: Item? {
        (recent + local)
            .filter { progress[$0.key] != nil }
            .max { progress[$0.key]!.date < progress[$1.key]!.date }
    }

    private static let recentKey = "recentFiles"
    private static let progressKey = "playbackProgress"
    private static let recentLimit = 20
    private let documents = URL.documentsDirectory
    private let cache = URL.cachesDirectory.appending(path: "Thumbnails")
    /// 正在生成封面的影片
    private var pending: Set<String> = []
    /// 正在生成续播封面的影片
    private var pendingResume: Set<String> = []
    /// 本轮截取失败的续播封面，刷新时清空重试
    private var failedResume: Set<String> = []
    /// 已解码的封面，超出上限时自动释放最久未用的
    @ObservationIgnored private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    init() {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let data = UserDefaults.standard.data(forKey: Self.progressKey),
           let stored = try? JSONDecoder().decode([String: Progress].self, from: data) {
            progress = stored
        }
        refresh()
    }

    func refresh() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)?
            .compactMap { $0 as? URL } ?? []
        local = files.filter(Self.isVideo).compactMap(Self.item).sorted { $0.date > $1.date }

        var bookmarks: [Data] = []
        recent = []
        for bookmark in storedBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // 文件已被删除或移走时不再保留
            guard let item = Self.item(url) else { continue }
            recent.append(item)
            bookmarks.append(stale ? (try? url.bookmarkData()) ?? bookmark : bookmark)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentKey)
        removeOrphans()
        failed = []
        failedResume = []
        loadDetails()
        updateResumeImage()
    }

    /// 记录从其他位置打开的影片；墨影文件夹内的不需要记录
    func remember(_ url: URL) {
        guard !isLocal(url) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else { return }
        var bookmarks = storedBookmarks()
        // 同一文件只保留最新一条
        bookmarks.removeAll { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale))?.standardizedFileURL == url.standardizedFileURL
        }
        bookmarks.insert(bookmark, at: 0)
        UserDefaults.standard.set(Array(bookmarks.prefix(Self.recentLimit)), forKey: Self.recentKey)
        refresh()
    }

    /// 从「最近打开」中移除（不删除文件）
    func forget(_ item: Item) {
        var bookmarks = storedBookmarks()
        if let index = recent.firstIndex(of: item), index < bookmarks.count {
            bookmarks.remove(at: index)
            UserDefaults.standard.set(bookmarks, forKey: Self.recentKey)
        }
        refresh()
    }

    /// 删除墨影文件夹中的影片
    func delete(_ item: Item) {
        guard isLocal(item.url) else { return }
        try? FileManager.default.removeItem(at: item.url)
        refresh()
    }

    // MARK: - 播放进度

    /// 续播位置；没有记录时为 0
    func resumePosition(for url: URL) -> Double {
        item(for: url).flatMap { progress[$0.key]?.position } ?? 0
    }

    /// 保存播放进度。开头不足 30 秒或已接近结尾（剩余不足 3 分钟或超过 95%）时视为未开始或已看完，清除记录。
    func saveProgress(for url: URL, position: Double, duration: Double) {
        guard let item = item(for: url), duration > 0 else { return }
        let finished = position > duration * 0.95 || duration - position < 180
        setProgress(position < 30 || finished ? nil : Progress(position: position, duration: duration, date: .now), for: item.key)
    }

    private func setProgress(_ value: Progress?, for key: String) {
        progress[key] = value
        saveProgress()
        if value == nil {
            try? FileManager.default.removeItem(at: resumeURL(key))
            resumeStamps[key] = nil
        }
        updateResumeImage()
    }

    private func saveProgress() {
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: Self.progressKey)
        }
    }

    private func item(for url: URL) -> Item? {
        let target = url.standardizedFileURL
        if let item = (local + recent).first(where: { $0.url.standardizedFileURL == target }) { return item }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Self.item(url)
    }

    // MARK: - 封面

    /// 加载封面标签：先读缓存，没有缓存的依次在后台生成
    private func loadDetails() {
        let missing = (recent + local).filter { details[$0.key] == nil && !pending.contains($0.key) }
        var queue: [Item] = []
        for item in missing {
            if let data = try? Data(contentsOf: cacheURL(item.key).appendingPathExtension("json")),
               let cached = try? JSONDecoder().decode(Details.self, from: data) {
                details[item.key] = cached
            } else {
                queue.append(item)
            }
        }
        guard !queue.isEmpty else { return }
        pending.formUnion(queue.map(\.key))
        let cache = self.cache
        Task {
            // 逐个生成，避免同时解码多部 4K 影片
            for item in queue {
                let base = cache.appending(path: Self.hash(item.key))
                let generated = await Task.detached(priority: .utility) {
                    Self.generate(item.url, base: base)
                }.value
                pending.remove(item.key)
                if let generated {
                    details[item.key] = generated
                } else {
                    failed.insert(item.key)
                }
            }
        }
    }

    /// 读取封面，按 maxPixels（像素）缩小解码
    func thumbnail(for item: Item, maxPixels: Int) async -> UIImage? {
        let name = "\(Self.hash(item.key))@\(maxPixels)" as NSString
        if let image = images.object(forKey: name) { return image }
        let url = cacheURL(item.key).appendingPathExtension("jpg")
        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(url, maxPixels: maxPixels)
        }.value
        if let image {
            images.setObject(image, forKey: name, cost: Int(image.size.width * image.size.height * image.scale * image.scale) * 4)
        }
        return image
    }

    /// 读取续播封面；还没有时返回 nil
    func resumeThumbnail(for item: Item, maxPixels: Int) async -> UIImage? {
        let url = resumeURL(item.key)
        guard let stamp = resumeStamps[item.key] ?? Self.modificationDate(url) else { return nil }
        let name = "\(Self.hash(item.key)).resume@\(maxPixels)@\(stamp.timeIntervalSince1970)" as NSString
        if let image = images.object(forKey: name) { return image }
        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(url, maxPixels: maxPixels)
        }.value
        if let image {
            images.setObject(image, forKey: name, cost: Int(image.size.width * image.size.height * image.scale * image.scale) * 4)
        }
        return image
    }

    /// 为有播放进度的影片截取上次看到的画面，一次截一部，「继续观看」的优先；已有且不早于进度记录时跳过。
    /// 后台时硬件解码可能被系统中止，失败的会在下次回到前台刷新时重试。
    private func updateResumeImage() {
        guard pendingResume.isEmpty else { return }
        let candidates = ([continueWatching].compactMap { $0 } + recent + local).filter { item in
            guard let progress = progress[item.key], !failedResume.contains(item.key) else { return false }
            return Self.modificationDate(resumeURL(item.key)).map { $0 < progress.date } ?? true
        }
        guard let item = candidates.first, let progress = progress[item.key] else { return }
        let url = resumeURL(item.key)
        pendingResume.insert(item.key)
        Task {
            let image = await Task.detached(priority: .utility) {
                // 「最近打开」的外部文件需要访问授权
                let scoped = item.url.startAccessingSecurityScopedResource()
                defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
                return try? Thumbnailer.frame(url: item.url, at: progress.position, maxWidth: 960)
            }.value
            pendingResume.remove(item.key)
            if let image, let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8),
               (try? jpeg.write(to: url)) != nil {
                resumeStamps[item.key] = .now
            } else {
                failedResume.insert(item.key)
            }
            // 继续截下一部；截取期间进度又更新了的（例如继续播放后再次退出）也会按新位置重截
            updateResumeImage()
        }
    }

    private func resumeURL(_ key: String) -> URL {
        cacheURL(key).appendingPathExtension("resume.jpg")
    }

    nonisolated private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// 删除已不在片库中的影片的封面与播放进度（文件被删除、移走或从列表移除）
    private func removeOrphans() {
        let items = recent + local
        let keys = Set(items.map(\.key))
        let names = Set(keys.map(Self.hash))
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        // 文件名为「哈希.jpg」「哈希.json」「哈希.resume.jpg」
        for file in files where !names.contains(String(file.lastPathComponent.prefix { $0 != "." })) {
            try? FileManager.default.removeItem(at: file)
        }
        for key in details.keys where !keys.contains(key) { details[key] = nil }
        let stale = progress.keys.filter { !keys.contains($0) }
        if !stale.isEmpty {
            for key in stale { progress[key] = nil }
            saveProgress()
        }
    }

    private func cacheURL(_ key: String) -> URL {
        cache.appending(path: Self.hash(key))
    }

    /// 截图规则变化时递增，旧缓存随之失效
    nonisolated private static let cacheVersion = 2

    /// 截取封面并写入缓存；读取失败时返回 nil 且不写缓存，下次刷新时重试
    nonisolated private static func generate(_ url: URL, base: URL) -> Details? {
        guard let result = try? Thumbnailer.make(url: url, maxWidth: 960) else { return nil }
        var hasImage = false
        if let image = result.image, let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) {
            hasImage = (try? jpeg.write(to: base.appendingPathExtension("jpg"))) != nil
        }
        let details = Details(duration: result.info.duration, tags: tags(result.info), hasImage: hasImage)
        if let json = try? JSONEncoder().encode(details) {
            try? json.write(to: base.appendingPathExtension("json"))
        }
        return details
    }

    /// 用 ImageIO 直接按目标尺寸解码，不先解出整张图
    nonisolated private static func decode(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// 分辨率与动态范围标签，例如「4K · HDR10」
    nonisolated static func tags(_ info: MediaInfo) -> [String] {
        guard let video = info.videoTracks.first else { return [] }
        var tags: [String] = []
        let size = video.displaySize
        switch max(size.width, size.height * 16 / 9) {
        case 3200...: tags.append("4K")
        case 1800...: tags.append("1080p")
        case 1200...: tags.append("720p")
        default: tags.append("SD")
        }
        switch video.dynamicRange {
        case .sdr: break
        case .hdr10: tags.append("HDR10")
        case .hlg: tags.append("HLG")
        case .dolbyVision: tags.append("杜比视界")
        }
        return tags
    }

    nonisolated private static func hash(_ key: String) -> String {
        SHA256.hash(data: Data("\(cacheVersion)|\(key)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 文件

    private func isLocal(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path + "/")
    }

    private func storedBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: Self.recentKey) as? [Data] ?? []
    }

    private static func isVideo(_ url: URL) -> Bool {
        VideoFiles.extensions.contains(url.pathExtension.lowercased())
    }

    private static func item(_ url: URL) -> Item? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return Item(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            size: Int64(values.fileSize ?? 0),
            date: values.contentModificationDate ?? .distantPast
        )
    }
}
