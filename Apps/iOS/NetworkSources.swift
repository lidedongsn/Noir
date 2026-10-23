import Foundation
import Network
import NoirEngine
import Observation
import Security

/// 网络片源：WebDAV 服务器、联网规则（默认只用 Wi-Fi）与边看边缓存的空间管理
@MainActor @Observable
final class NetworkSources {
    struct Server: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        /// 根目录地址
        var url: URL
        var username: String
    }

    private(set) var servers: [Server] = []

    /// 允许用蜂窝网络（含个人热点）播放与预缓存
    var cellularPlayback: Bool {
        didSet {
            UserDefaults.standard.set(cellularPlayback, forKey: Keys.cellularPlayback)
            applyCellularPolicy()
        }
    }

    /// 允许用蜂窝网络下载
    var cellularDownload: Bool {
        didSet { UserDefaults.standard.set(cellularDownload, forKey: Keys.cellularDownload) }
    }

    /// 缓存上限（GB）
    var cacheLimit: Int {
        didSet {
            UserDefaults.standard.set(cacheLimit, forKey: Keys.cacheLimit)
            pruneCache()
        }
    }

    static let cacheLimitChoices = [1, 2, 5, 10]

    /// 当前是否连着 Wi-Fi（不含个人热点）
    private(set) var onWiFi = false
    /// 当前是否有任何可用网络
    private(set) var online = false

    /// 现在能否为播放联网
    var canStream: Bool { onWiFi || (online && cellularPlayback) }
    /// 现在能否为下载联网
    var canDownload: Bool { onWiFi || (online && cellularDownload) }
    /// 正在用蜂窝网络播放（预缓存距离受限）
    var streamingOnCellular: Bool { !onWiFi && online && cellularPlayback }

    /// 正在播放或下载、清理缓存时保留的缓存目录
    var activeCaches: Set<URL> = []

    /// 网络恢复时调用，让正在等待的下载立即重试
    var onReconnect: (() -> Void)?

    let streamRoot = URL.cachesDirectory.appending(path: "Stream")
    /// 始终为手机保留的空闲空间
    static let minimumFree: Int64 = 10 << 30

    @ObservationIgnored private var clients: [UUID: WebDAVClient] = [:]
    @ObservationIgnored private var openCaches: [URL: WeakCache] = [:]

    private struct WeakCache {
        weak var cache: BlockCache?
    }
    @ObservationIgnored private let monitor = NWPathMonitor()

    private enum Keys {
        static let servers = "webdavServers"
        static let cellularPlayback = "cellularPlayback"
        static let cellularDownload = "cellularDownload"
        static let cacheLimit = "streamCacheLimit"
    }

    init() {
        let defaults = UserDefaults.standard
        cellularPlayback = defaults.bool(forKey: Keys.cellularPlayback)
        cellularDownload = defaults.bool(forKey: Keys.cellularDownload)
        let limit = defaults.integer(forKey: Keys.cacheLimit)
        cacheLimit = Self.cacheLimitChoices.contains(limit) ? limit : 5
        if let data = defaults.data(forKey: Keys.servers),
           let stored = try? JSONDecoder().decode([Server].self, from: data) {
            servers = stored
        }
        try? FileManager.default.createDirectory(at: streamRoot, withIntermediateDirectories: true)
        monitor.pathUpdateHandler = { [weak self] path in
            // 系统把蜂窝网络与个人热点（走的是对方手机的蜂窝流量）标记为高开销，其余视为 Wi-Fi（含有线网络）
            let online = path.status == .satisfied
            let wifi = online && !path.isExpensive
            Task { @MainActor in self?.update(online: online, wifi: wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "noir.network.path"))
    }

    private func update(online: Bool, wifi: Bool) {
        let wasAvailable = canStream
        self.online = online
        onWiFi = wifi
        if canStream, !wasAvailable { onReconnect?() }
    }

    // MARK: - 服务器

    func client(for serverID: UUID) -> WebDAVClient? {
        if let client = clients[serverID] { return client }
        guard let server = servers.first(where: { $0.id == serverID }) else { return nil }
        let client = WebDAVClient(client: HTTPClient(
            username: server.username, password: Keychain.password(for: server.id), allowsCellular: cellularPlayback
        ))
        clients[serverID] = client
        return client
    }

    func server(_ id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    /// 测试连接：能列出根目录即可
    static func test(_ server: Server, password: String, allowsCellular: Bool) async throws {
        let client = HTTPClient(username: server.username, password: password, allowsCellular: allowsCellular)
        defer { client.invalidate() }
        _ = try await WebDAVClient(client: client).list(server.url)
    }

    func save(_ server: Server, password: String) {
        Keychain.setPassword(password, for: server.id)
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        clients[server.id]?.client.invalidate()
        clients[server.id] = nil
        saveServers()
    }

    /// 删除服务器及其缓存
    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        Keychain.setPassword(nil, for: server.id)
        clients[server.id]?.client.invalidate()
        clients[server.id] = nil
        saveServers()
        let prefix = server.id.uuidString
        for dir in (try? FileManager.default.contentsOfDirectory(at: streamRoot, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Keys.servers)
        }
    }

    private func applyCellularPolicy() {
        for client in clients.values { client.client.setAllowsCellular(cellularPlayback) }
    }

    // MARK: - 缓存

    /// 影片的块缓存目录：服务器 ID 加影片标识的哈希
    func cacheDirectory(server: UUID, key: String) -> URL {
        streamRoot.appending(path: "\(server.uuidString)-\(Library.hash(key))")
    }

    /// 打开影片的块缓存。同一影片在播放、截图、下载间共用一个实例，已下载块的记录不会互相覆盖
    func cache(server: UUID, key: String, size: Int64, version: String) -> BlockCache? {
        let directory = cacheDirectory(server: server, key: key)
        if let cache = openCaches[directory]?.cache, cache.size == size { return cache }
        guard let cache = try? BlockCache(directory: directory, size: size, version: version) else { return nil }
        openCaches = openCaches.filter { $0.value.cache != nil }
        openCaches[directory] = WeakCache(cache: cache)
        return cache
    }

    var cacheUsage: Int64 { BlockCache.usage(root: streamRoot) }

    var cacheLimitBytes: Int64 { Int64(cacheLimit) << 30 }

    private var freeSpace: Int64 {
        (try? URL.cachesDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// 按上限清理（最久没看的先删），同时保证手机至少留有 minimumFree 的空闲空间。
    /// reserving 为即将播放的影片预留的空间：打开新影片时先给它腾出位置
    func pruneCache(reserving: Int64 = 0) {
        let usage = cacheUsage
        // 空闲空间不足时，缓存只能用到「当前占用 - 欠缺部分」
        let shortfall = max(Self.minimumFree - freeSpace, 0)
        let limit = min(cacheLimitBytes - reserving, usage - shortfall)
        BlockCache.prune(root: streamRoot, limit: max(limit, 0), keep: activeCaches)
    }

    /// 正在播放的影片可占用的缓存：不超过上限，也不挤占手机保留的空闲空间
    func playbackBudget(currentlyCached: Int64) -> Int64 {
        min(cacheLimitBytes, max(freeSpace - Self.minimumFree + currentlyCached, 0))
    }

    func clearCache() {
        for dir in (try? FileManager.default.contentsOfDirectory(at: streamRoot, includingPropertiesForKeys: nil)) ?? []
        where !activeCaches.contains(dir) {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

/// 服务器密码存放在钥匙串，仅本机可用
enum Keychain {
    private static let service = "dev.noir.webdav"

    static func password(for id: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
        SecItemDelete(query as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(password.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
