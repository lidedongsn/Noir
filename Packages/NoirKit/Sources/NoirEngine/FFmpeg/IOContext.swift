import CFFmpeg
import Foundation

/// 将 ByteSource 桥接为 FFmpeg 的 AVIOContext。
/// FFmpeg 构建时未启用任何协议，全部 I/O 经由此处。
final class IOContext {
    private let source: ByteSource
    private var position: Int64 = 0
    private(set) var avio: UnsafeMutablePointer<AVIOContext>!

    /// 读缓冲 1 MB：高码率片源下以大块读取减少系统调用次数
    private static let bufferSize: Int32 = 1 << 20

    init(source: ByteSource) throws {
        self.source = source
        guard let buffer = av_malloc(Int(Self.bufferSize)) else {
            throw FFmpegError(code: -ENOMEM, context: "分配 IO 缓冲")
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), Self.bufferSize, 0, opaque,
            { opaque, buf, size in
                let io = Unmanaged<IOContext>.fromOpaque(opaque!).takeUnretainedValue()
                return io.read(into: UnsafeMutableRawBufferPointer(start: buf, count: Int(size)))
            },
            nil,
            { opaque, offset, whence in
                let io = Unmanaged<IOContext>.fromOpaque(opaque!).takeUnretainedValue()
                return io.seek(offset: offset, whence: whence)
            }
        ) else {
            av_free(buffer)
            throw FFmpegError(code: -ENOMEM, context: "创建 AVIOContext")
        }
        avio = ctx
    }

    deinit {
        // FFmpeg 可能已替换缓冲区，需释放 AVIOContext 当前持有的缓冲
        av_freep(&avio.pointee.buffer)
        avio_context_free(&avio)
    }

    private func read(into buffer: UnsafeMutableRawBufferPointer) -> Int32 {
        do {
            let n = try source.read(at: position, into: buffer)
            guard n > 0 else { return AVConst.errorEOF }
            position += Int64(n)
            return Int32(n)
        } catch {
            return -EIO
        }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & AVSEEK_SIZE != 0 {
            return source.size ?? -1
        }
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: position = offset
        case SEEK_CUR: position += offset
        case SEEK_END:
            guard let size = source.size else { return -1 }
            position = size + offset
        default: return -1
        }
        return position
    }
}
