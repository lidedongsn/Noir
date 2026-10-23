import Foundation

/// WebDAV 目录中的一项
public struct WebDAVEntry: Sendable, Hashable, Identifiable {
    /// 完整地址
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var etag: String?

    public var id: URL { url }

    public init(url: URL, name: String, isDirectory: Bool, size: Int64?, modified: Date?, etag: String?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.etag = etag
    }

    /// 文件版本标识，服务器上的文件变化后缓存随之失效
    public var version: String {
        etag ?? "\(size ?? -1)-\(modified?.timeIntervalSince1970 ?? 0)"
    }
}

/// WebDAV 客户端：列目录（PROPFIND），文件读取经由 HTTPRangeTransport
public struct WebDAVClient: Sendable {
    public let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    /// 列出目录内容（不含目录自身），文件夹在前，按名称排序
    public func list(_ directory: URL) async throws -> [WebDAVEntry] {
        let url = directory.hasDirectoryPath ? directory : directory.appending(path: "")
        var request = client.request(url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop>
            <d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/>
            </d:prop></d:propfind>
            """.utf8)
        let (data, response) = try await client.data(for: request)
        guard response.statusCode == 207 else { throw NetworkError.status(response.statusCode) }
        let base = response.url ?? url
        let entries = MultiStatusParser.parse(data).compactMap { $0.entry(relativeTo: base) }
        let selfPath = base.standardized.path(percentEncoded: false).trimmingSuffix("/")
        return entries
            .filter { $0.url.standardized.path(percentEncoded: false).trimmingSuffix("/") != selfPath }
            .sorted { lhs, rhs in
                lhs.isDirectory != rhs.isDirectory
                    ? lhs.isDirectory
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// 读取单个文件的属性（大小、修改时间）
    public func info(_ file: URL) async throws -> WebDAVEntry {
        var request = client.request(file, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        let (data, response) = try await client.data(for: request)
        guard response.statusCode == 207,
              let entry = MultiStatusParser.parse(data).first?.entry(relativeTo: response.url ?? file)
        else { throw NetworkError.status(response.statusCode) }
        return entry
    }

    public func transport(for file: URL) -> HTTPRangeTransport {
        HTTPRangeTransport(url: file, client: client)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > 1 ? String(dropLast(suffix.count)) : self
    }
}

/// 解析 PROPFIND 返回的 207 Multi-Status
private final class MultiStatusParser: NSObject, XMLParserDelegate {
    struct Response {
        var href = ""
        var displayName: String?
        var isCollection = false
        var length: Int64?
        var modified: Date?
        var etag: String?

        func entry(relativeTo base: URL) -> WebDAVEntry? {
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { return nil }
            let fallback = url.path(percentEncoded: false).split(separator: "/").last.map(String.init) ?? href
            let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            return WebDAVEntry(url: url, name: name, isDirectory: isCollection, size: length, modified: modified,
                               etag: etag?.trimmingCharacters(in: CharacterSet(charactersIn: "\"W/")))
        }
    }

    private var responses: [Response] = []
    private var current: Response?
    private var text = ""

    static func parse(_ data: Data) -> [Response] {
        let delegate = MultiStatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.responses
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "response": current = Response()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href": current?.href = value
        case "displayname": current?.displayName = value
        case "getcontentlength": current?.length = Int64(value)
        case "getlastmodified": current?.modified = Self.dateFormatter.date(from: value)
        case "getetag": current?.etag = value
        case "response":
            if let current { responses.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}
