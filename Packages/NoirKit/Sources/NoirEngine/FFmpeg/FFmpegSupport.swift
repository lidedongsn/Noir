import CFFmpeg
import CoreMedia

/// FFmpeg 调用失败
struct FFmpegError: Error, CustomStringConvertible {
    let code: Int32
    let context: String

    var description: String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return "\(context)：\(String(cBuffer: buffer))（\(code)）"
    }
}

extension String {
    /// 以 NUL 结尾的 C 字符缓冲
    init(cBuffer: [CChar]) {
        let bytes = cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self.init(decoding: bytes, as: UTF8.self)
    }

    /// 可能为空的 C 字符串
    init(cString pointer: UnsafePointer<CChar>?, default fallback: String) {
        self = pointer.map { String(cString: $0) } ?? fallback
    }
}

/// Swift 无法导入的 FFmpeg 宏常量
enum AVConst {
    /// AVERROR_EOF = -MKTAG('E','O','F',' ')
    static let errorEOF: Int32 = -0x2046_4F45
    static let errorAgain: Int32 = -EAGAIN
    /// AV_NOPTS_VALUE
    static let noPTS = Int64.min
}

@discardableResult
func check(_ code: Int32, _ context: @autoclosure () -> String) throws -> Int32 {
    guard code >= 0 else { throw FFmpegError(code: code, context: context()) }
    return code
}

extension AVRational {
    var doubleValue: Double { den == 0 ? 0 : Double(num) / Double(den) }

    /// 以本时间基表示的时间戳转为 CMTime
    func time(_ ts: Int64) -> CMTime {
        guard ts != AVConst.noPTS, den != 0 else { return .invalid }
        return CMTime(value: ts * Int64(num), timescale: den)
    }

    /// CMTime 转为本时间基下的时间戳
    func timestamp(_ time: CMTime) -> Int64 {
        guard num != 0 else { return 0 }
        return Int64((time.seconds * Double(den) / Double(num)).rounded(.down))
    }
}

extension UnsafePointer<AVCodecParameters> {
    /// 读取流级别的附带数据（HDR 母版信息、杜比视界配置等）
    func sideData(_ type: AVPacketSideDataType) -> UnsafeBufferPointer<UInt8>? {
        guard let entry = av_packet_side_data_get(pointee.coded_side_data, pointee.nb_coded_side_data, type),
              let data = entry.pointee.data else { return nil }
        return UnsafeBufferPointer(start: data, count: entry.pointee.size)
    }

    var extradata: Data? {
        guard let data = pointee.extradata, pointee.extradata_size > 0 else { return nil }
        return Data(bytes: data, count: Int(pointee.extradata_size))
    }
}

func codecName(_ id: AVCodecID) -> String {
    String(cString: avcodec_get_name(id))
}

func dictionaryValue(_ dict: OpaquePointer?, _ key: String) -> String? {
    guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else { return nil }
    return String(cString: value)
}

/// 所链接 FFmpeg 的版本与许可，供「关于」页面注明
public enum FFmpegLibrary {
    /// 如「9.0.2」
    public static var version: String { String(cString: av_version_info()) }
    /// 如「LGPL version 2.1 or later」
    public static var license: String { String(cString: avutil_license()) }
}
