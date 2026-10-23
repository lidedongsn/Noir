import CryptoKit
import Foundation
import ImageIO
import NoirEngine
import Observation
import UIKit

/// 片库：墨影文件夹（App 的 Documents，在「文件」App 中显示为「我的 iPhone › 墨影」）中的影片，
/// 以及从其他位置打开过的影片与网络影片。其他位置的文件以书签保存，下次无需重新选择。
/// 同时管理封面、媒体标签与播放进度：封面缓存在 Caches 目录，影片不在片库中后随之删除；
/// 内存中只保留最近显示的封面，按显示尺寸解码。
@MainActor @Observable
final class Library {
    struct Item: Identifiable, Hashable {
        var url: URL
        var name: String
        var size: Int64
        var date: Date
        /// 网络影片所在的 WebDAV 服务器；本地影片为 nil
        var server: UUID?
        /// 网络影片在服务器上的版本，变化后缓存失效
        var version: String?
        var id: URL { url }
        var isRemote: Bool { server != nil }
        /// 本地影片以文件名加大小标识，文件被移动或重新授权后封面与进度仍可对应；
        /// 网络影片以服务器、路径加大小标识
        var key: String {
            guard let server else { return "\(url.lastPathComponent)|\(size)" }
            return "remote|\(server.uuidString)|\(url.path(percentEncoded: false))|\(size)"
        }

        init(url: URL, name: String, size: Int64, date: Date, server: UUID? = nil, version: String? = nil) {
            self.url = url
            self.name = name
            self.size = size
            self.date = date
            self.server = server
            self.version = version
        }

        init(remote entry: WebDAVEntry, server: UUID) {
            self.init(url: entry.url, name: (entry.name as NSString).deletingPathExtension, size: entry.size ?? 0,
                      date: entry.modified ?? .distantPast, server: server, version: entry.version)
        }
    }

    /// 「最近打开」的记录：其他位置的本地文件存书签，网络影片存地址与属性
    private enum Recent: Codable {
        case file(Data)
        case remote(RemoteRecord)
    }

    private struct RemoteRecord: Codable {
        var server: UUID
        var url: URL
        var name: String
        var size: Int64
        var date: Date
        var version: String
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
    /// 从其他位置打开过的影片与网络影片，最近的在前
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

    /// 旧版只记录本地书签
    private static let legacyRecentKey = "recentFiles"
    private static let recentKey = "recentItems"
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

    let network: NetworkSources

    init(network: NetworkSources) {
        self.network = network
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

        var records: [Recent] = []
        recent = []
        for record in storedRecents() {
            switch record {
            case .file(let bookmark):
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { continue }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // 文件已被删除或移走时不再保留
                guard let item = Self.item(url) else { continue }
                recent.append(item)
                records.append(.file(stale ? (try? url.bookmarkData()) ?? bookmark : bookmark))
            case .remote(let remote):
                // 服务器已删除时不再保留；服务器暂时连不上时保留
                guard network.server(remote.server) != nil else { continue }
                recent.append(Item(url: remote.url, name: remote.name, size: remote.size, date: remote.date,
                                   server: remote.server, version: remote.version))
                records.append(record)
            }
        }
        storeRecents(records)
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
        var records = storedRecents()
        // 同一文件只保留最新一条
        records.removeAll { record in
            guard case .file(let data) = record else { return false }
            var stale = false
            return (try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale))?.standardizedFileURL == url.standardizedFileURL
        }
        records.insert(.file(bookmark), at: 0)
        storeRecents(records)
        refresh()
    }

    /// 记录打开过的网络影片
    func remember(remote item: Item) {
        guard let server = item.server, let version = item.version else { return }
        var records = storedRecents()
        records.removeAll { record in
            guard case .remote(let remote) = record else { return false }
            return remote.server == server && remote.url == item.url
        }
        records.insert(.remote(RemoteRecord(server: server, url: item.url, name: item.name, size: item.size,
                                            date: item.date, version: version)), at: 0)
        storeRecents(records)
        refresh()
    }

    /// 从「最近打开」中移除（不删除文件）
    func forget(_ item: Item) {
        var records = storedRecents()
        if let index = recent.firstIndex(of: item), index < records.count {
            records.remove(at: index)
            storeRecents(records)
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

    /// 浏览网络文件夹时，为出现在屏幕上的影片读取或生成封面
    func requestDetails(for item: Item) {
        guard !failed.contains(item.key) else { return }
        loadDetails([item])
    }

    /// 加载封面标签：先读缓存，没有缓存的依次在后台生成。网络影片只在 Wi-Fi 下生成
    private func loadDetails(_ items: [Item]? = nil) {
        let missing = (items ?? recent + local).filter { details[$0.key] == nil && !pending.contains($0.key) }
        var queue: [Item] = []
        for item in missing {
            if let data = try? Data(contentsOf: cacheURL(item.key).appendingPathExtension("json")),
               let cached = try? JSONDecoder().decode(Details.self, from: data) {
                details[item.key] = cached
            } else {
                queue.append(item)
            }
        }
        queue.removeAll { $0.isRemote && !network.onWiFi }
        guard !queue.isEmpty else { return }
        pending.formUnion(queue.map(\.key))
        Task {
            // 逐个生成，避免同时解码多部 4K 影片
            for item in queue {
                let base = cacheURL(item.key)
                try? FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
                let generated: Details?
                if item.isRemote {
                    let source = network.onWiFi ? remoteSource(for: item, prefetching: false) : nil
                    generated = await Task.detached(priority: .utility) {
                        defer { source?.close() }
                        return source.flatMap { source in Self.generate(base: base) { try Thumbnailer.make(source: source, maxWidth: 960) } }
                    }.value
                } else {
                    generated = await Task.detached(priority: .utility) {
                        Self.generate(base: base) { try Thumbnailer.make(url: item.url, maxWidth: 960) }
                    }.value
                }
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
        // 网络影片只在 Wi-Fi 下截取（停止位置附近通常已在缓存中）
        let source = item.isRemote ? remoteSource(for: item, prefetching: false) : nil
        if item.isRemote, source == nil || !network.onWiFi {
            failedResume.insert(item.key)
            return updateResumeImage()
        }
        pendingResume.insert(item.key)
        Task {
            let image = await Task.detached(priority: .utility) {
                if let source {
                    defer { source.close() }
                    return try? Thumbnailer.frame(source: source, at: progress.position, maxWidth: 960)
                }
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

    /// 删除已不在片库中的影片的封面与播放进度（文件被删除、移走或从列表移除）。
    /// 网络影片的封面与进度按服务器保存（浏览过的影片不一定在片库中），服务器删除后才清理
    private func removeOrphans() {
        let items = recent + local
        let keys = Set(items.map(\.key))
        let names = Set(keys.map(Self.hash))
        let servers = Set(network.servers.map(\.id.uuidString))
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if file.hasDirectoryPath || UUID(uuidString: file.lastPathComponent) != nil {
                // 服务器目录
                if !servers.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
                continue
            }
            // 文件名为「哈希.jpg」「哈希.json」「哈希.resume.jpg」
            if !names.contains(String(file.lastPathComponent.prefix { $0 != "." })) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        func kept(_ key: String) -> Bool {
            keys.contains(key) || Self.server(ofKey: key).map { servers.contains($0) } ?? false
        }
        for key in details.keys where !kept(key) { details[key] = nil }
        let stale = progress.keys.filter { !kept($0) }
        if !stale.isEmpty {
            for key in stale { progress[key] = nil }
            saveProgress()
        }
    }

    private func cacheURL(_ key: String) -> URL {
        if let server = Self.server(ofKey: key) {
            return cache.appending(path: server).appending(path: Self.hash(key))
        }
        return cache.appending(path: Self.hash(key))
    }

    /// 网络影片标识中的服务器 ID
    nonisolated private static func server(ofKey key: String) -> String? {
        guard key.hasPrefix("remote|") else { return nil }
        return key.split(separator: "|", maxSplits: 2).dropFirst().first.map(String.init)
    }

    /// 网络影片的片源，读取经由块缓存；服务器已删除时为 nil
    /// prefetching 为 false 时只下载读取需要的部分（截图）
    func remoteSource(for item: Item, prefetching: Bool = true) -> RemoteByteSource? {
        guard let server = item.server, let version = item.version, let client = network.client(for: server),
              let cache = network.cache(server: server, key: item.key, size: item.size, version: version) else { return nil }
        let source = RemoteByteSource(cache: cache, transport: client.transport(for: item.url))
        source.setPrefetching(prefetching)
        return source
    }

    /// 截图规则变化时递增，旧缓存随之失效
    nonisolated private static let cacheVersion = 2

    /// 截取封面并写入缓存；读取失败时返回 nil 且不写缓存，下次刷新时重试
    nonisolated private static func generate(base: URL, _ make: () throws -> Thumbnailer.Result) -> Details? {
        guard let result = try? make() else { return nil }
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

    nonisolated static func hash(_ key: String) -> String {
        SHA256.hash(data: Data("\(cacheVersion)|\(key)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 文件

    private func isLocal(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path + "/")
    }

    private func storedRecents() -> [Recent] {
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let records = try? JSONDecoder().decode([Recent].self, from: data) {
            return records
        }
        // 从旧版的书签列表迁移
        return (UserDefaults.standard.array(forKey: Self.legacyRecentKey) as? [Data] ?? []).map(Recent.file)
    }

    private func storeRecents(_ records: [Recent]) {
        if let data = try? JSONEncoder().encode(Array(records.prefix(Self.recentLimit))) {
            UserDefaults.standard.set(data, forKey: Self.recentKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyRecentKey)
        }
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
