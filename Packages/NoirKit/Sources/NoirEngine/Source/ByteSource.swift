import Foundation

/// 片源的随机访问读取接口，隔离解封装层与具体的文件或网络实现。
public protocol ByteSource: AnyObject, Sendable {
    /// 总字节数；未知时为 nil
    var size: Int64? { get }
    /// 从 offset 处读取，返回实际读到的字节数，0 表示已到末尾
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

/// 本地文件数据源，基于 pread，线程安全。
public final class FileByteSource: ByteSource {
    private let fd: Int32
    public let size: Int64?

    public init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        size = fstat(fd, &info) == 0 ? Int64(info.st_size) : nil
        // 以顺序读取为主，启用内核预读
        _ = fcntl(fd, F_RDAHEAD, 1)
    }

    deinit { close(fd) }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let n = pread(fd, buffer.baseAddress, buffer.count, off_t(offset))
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return n
    }
}
