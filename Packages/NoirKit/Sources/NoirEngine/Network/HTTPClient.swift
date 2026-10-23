import Foundation
import Synchronization

/// 按字节范围读取远程文件，供 RemoteByteSource 下载缓存块
public protocol RangeTransport: Sendable {
    func fetch(_ range: Range<Int64>) async throws -> Data
}

public enum NetworkError: Error, CustomStringConvertible, Equatable {
    /// 当前网络不允许使用（只允许 Wi-Fi 时处于蜂窝网络），或没有网络
    case offline
    case unauthorized
    case notFound
    /// 服务器不支持分段读取
    case rangeNotSupported
    case status(Int)
    case invalidResponse

    public var description: String {
        switch self {
        case .offline: "没有可用的网络"
        case .unauthorized: "用户名或密码错误"
        case .notFound: "文件不存在"
        case .rangeNotSupported: "服务器不支持分段读取"
        case .status(let code): "服务器错误（\(code)）"
        case .invalidResponse: "服务器响应无效"
        }
    }
}

/// 一台服务器的 HTTP 会话：认证、是否允许蜂窝网络。
/// 凭据只在服务器发出认证质询时提供，不随请求主动发送，重定向到云盘直链时不会泄露。
public final class HTTPClient: NSObject, Sendable, URLSessionTaskDelegate {
    private let credential: URLCredential?
    private let allowsCellular: Mutex<Bool>
    private let session = Mutex<URLSession?>(nil)

    public init(username: String? = nil, password: String? = nil, allowsCellular: Bool = false) {
        credential = username.flatMap { $0.isEmpty ? nil : URLCredential(user: $0, password: password ?? "", persistence: .forSession) }
        self.allowsCellular = Mutex(allowsCellular)
        super.init()
    }

    /// 是否允许使用蜂窝网络（含个人热点）；修改后对新请求生效
    public func setAllowsCellular(_ allowed: Bool) {
        allowsCellular.withLock { $0 = allowed }
    }

    public func invalidate() {
        session.withLock { $0?.invalidateAndCancel(); $0 = nil }
    }

    private var urlSession: URLSession {
        session.withLock { session in
            if let session { return session }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.httpMaximumConnectionsPerHost = 8
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            session = created
            return created
        }
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let cellular = allowsCellular.withLock { $0 }
        request.allowsCellularAccess = cellular
        request.allowsExpensiveNetworkAccess = cellular
        return request
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
            switch http.statusCode {
            case 401: throw NetworkError.unauthorized
            case 404: throw NetworkError.notFound
            default: return (data, http)
            }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .cannotConnectToHost, .timedOut:
                throw NetworkError.offline
            case .userAuthenticationRequired: throw NetworkError.unauthorized
            default: throw error
            }
        }
    }

    /// 读取整个文件（如外挂字幕）
    public func download(_ url: URL) async throws -> Data {
        let (data, response) = try await data(for: request(url))
        guard (200..<300).contains(response.statusCode) else { throw NetworkError.status(response.statusCode) }
        return data
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            if let credential, challenge.previousFailureCount == 0 {
                completionHandler(.useCredential, credential)
            } else {
                // 不再重试，交回 401 响应，由调用方报告认证失败
                completionHandler(.rejectProtectionSpace, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// HTTP Range 读取。服务器重定向（如 OpenList 转到云盘直链）后直接请求最终地址；
/// 直链过期（403/404/410）时从原地址重新获取。
public final class HTTPRangeTransport: RangeTransport {
    public let url: URL
    private let client: HTTPClient
    private let resolved = Mutex<URL?>(nil)

    public init(url: URL, client: HTTPClient) {
        self.url = url
        self.client = client
    }

    public func fetch(_ range: Range<Int64>) async throws -> Data {
        if let direct = resolved.withLock({ $0 }) {
            do {
                return try await fetch(range, from: direct)
            } catch NetworkError.notFound, NetworkError.status(403), NetworkError.status(410) {
                resolved.withLock { $0 = nil }
            }
        }
        return try await fetch(range, from: url)
    }

    private func fetch(_ range: Range<Int64>, from source: URL) async throws -> Data {
        var request = client.request(source)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await client.data(for: request)
        if let final = response.url, final != source, source == url {
            resolved.withLock { $0 = final }
        }
        switch response.statusCode {
        case 206:
            guard data.count == range.count else { throw NetworkError.invalidResponse }
            return data
        case 200:
            // 不支持 Range 的服务器返回整个文件；只有请求的正好是整个文件时才可用
            guard range.lowerBound == 0, data.count == range.count else { throw NetworkError.rangeNotSupported }
            return data
        default:
            throw NetworkError.status(response.statusCode)
        }
    }
}
