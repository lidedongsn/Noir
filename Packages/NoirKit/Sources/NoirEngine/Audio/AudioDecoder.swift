import AudioToolbox
import CFFmpeg
import CoreMedia

/// 将音频数据包转换为可提交给 AVSampleBufferAudioRenderer 的样本。
protocol AudioDecoder: AnyObject {
    var route: AudioRoute { get }
    /// 输出声道数（压缩直送时为源声道数）
    var outputChannels: Int { get }
    func decode(_ packet: Packet) throws -> [CMSampleBuffer]
    /// 清空内部状态（跳转后调用）
    func flush()
}

enum AudioDecoderError: Error, CustomStringConvertible {
    case unsupported(String)
    case audioToolbox(String, OSStatus)

    var description: String {
        switch self {
        case .unsupported(let name): "不支持的音频格式：\(name)"
        case .audioToolbox(let what, let status): "\(what) 失败（\(fourCharCode(status))）"
        }
    }
}

func fourCharCode(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
    if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(status)
}

enum AudioDecoders {
    static func make(stream: UnsafeMutablePointer<AVStream>) throws -> AudioDecoder {
        let par = UnsafePointer(stream.pointee.codecpar!)
        let timeBase = stream.pointee.time_base
        switch AudioRoute(par) {
        case .system: return try SystemAudioPassthrough(par: par, timeBase: timeBase)
        case .audioToolbox: return try AudioToolboxDecoder(par: par, timeBase: timeBase)
        case .ffmpeg: return try FFmpegAudioDecoder(stream: stream)
        case .pcm: return try PCMPassthrough(par: par, timeBase: timeBase)
        case .unsupported: throw AudioDecoderError.unsupported(codecName(par.pointee.codec_id))
        }
    }
}

// MARK: - AC3 / E-AC3 直通

/// 压缩码流直接提交给系统渲染器解码，以保留 E-AC3 中的杜比全景声（JOC）信息。
final class SystemAudioPassthrough: AudioDecoder {
    let route = AudioRoute.system
    let outputChannels: Int
    private let format: CMAudioFormatDescription
    private let timeBase: AVRational

    init(par: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        let p = par.pointee
        let asbd = AudioStreamBasicDescription(
            mSampleRate: Double(p.sample_rate),
            mFormatID: p.codec_id == AV_CODEC_ID_EAC3 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1536,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(p.ch_layout.nb_channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        format = try ChannelLayout.formatDescription(asbd, layout: p.ch_layout)
        outputChannels = Int(p.ch_layout.nb_channels)
        self.timeBase = timeBase
    }

    func decode(_ packet: Packet) throws -> [CMSampleBuffer] {
        let block = try SampleBuffers.blockBuffer(referencing: packet)
        return [try SampleBuffers.audio(
            block: block, format: format, frameCount: 1536,
            packetSizes: [packet.size], pts: timeBase.time(packet.pts)
        )]
    }

    func flush() {}
}

// MARK: - PCM 直通

final class PCMPassthrough: AudioDecoder {
    let route = AudioRoute.pcm
    let outputChannels: Int
    private let format: CMAudioFormatDescription
    private let bytesPerFrame: Int
    private let timeBase: AVRational

    init(par: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        let p = par.pointee
        let (bits, isFloat, isBigEndian): (Int, Bool, Bool) = switch p.codec_id {
        case AV_CODEC_ID_PCM_S16LE: (16, false, false)
        case AV_CODEC_ID_PCM_S16BE: (16, false, true)
        case AV_CODEC_ID_PCM_S24LE: (24, false, false)
        case AV_CODEC_ID_PCM_S24BE: (24, false, true)
        case AV_CODEC_ID_PCM_S32LE: (32, false, false)
        case AV_CODEC_ID_PCM_S32BE: (32, false, true)
        default: (32, true, false)
        }
        let channels = Int(p.ch_layout.nb_channels)
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        flags |= isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger
        if isBigEndian { flags |= kAudioFormatFlagIsBigEndian }
        bytesPerFrame = bits / 8 * channels
        let asbd = AudioStreamBasicDescription(
            mSampleRate: Double(p.sample_rate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bits), mReserved: 0
        )
        format = try ChannelLayout.formatDescription(asbd, layout: p.ch_layout)
        outputChannels = channels
        self.timeBase = timeBase
    }

    func decode(_ packet: Packet) throws -> [CMSampleBuffer] {
        let block = try SampleBuffers.blockBuffer(referencing: packet)
        return [try SampleBuffers.audio(
            block: block, format: format, frameCount: packet.size / bytesPerFrame,
            pts: timeBase.time(packet.pts)
        )]
    }

    func flush() {}
}

// MARK: - 采样格式转换

/// 将任意 FFmpeg 采样格式的音频帧转换为交错 Float32（24 位整数样本可无损表示）。
enum SampleConverter {
    static func interleavedFloat32(
        format: AVSampleFormat,
        channels: Int,
        frames: Int,
        planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        into output: inout [Float]
    ) {
        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(channels * frames)
        let planar = av_sample_fmt_is_planar(format) != 0
        let packed = av_get_packed_sample_fmt(format)

        func read<T>(_ type: T.Type, _ convert: (T) -> Float) {
            if planar {
                let ptrs = (0..<channels).map { UnsafeRawPointer(planes[$0]!).assumingMemoryBound(to: T.self) }
                for f in 0..<frames {
                    for c in 0..<channels { output.append(convert(ptrs[c][f])) }
                }
            } else {
                let ptr = UnsafeRawPointer(planes[0]!).assumingMemoryBound(to: T.self)
                for i in 0..<(frames * channels) { output.append(convert(ptr[i])) }
            }
        }

        switch packed {
        case AV_SAMPLE_FMT_FLT: read(Float.self) { $0 }
        case AV_SAMPLE_FMT_DBL: read(Double.self) { Float($0) }
        case AV_SAMPLE_FMT_S32: read(Int32.self) { Float($0) / 2_147_483_648 }
        case AV_SAMPLE_FMT_S16: read(Int16.self) { Float($0) / 32_768 }
        case AV_SAMPLE_FMT_U8: read(UInt8.self) { (Float($0) - 128) / 128 }
        default: break
        }
    }
}
