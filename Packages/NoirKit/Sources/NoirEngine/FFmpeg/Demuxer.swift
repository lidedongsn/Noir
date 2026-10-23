import CFFmpeg
import Foundation
import VideoToolbox

/// 解封装器，仅负责拆分数据包，不进行视频解码。
/// 非线程安全，所有方法须在同一串行队列上调用。
final class Demuxer {
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private let io: IOContext
    let info: MediaInfo

    init(source: ByteSource) throws {
        io = try IOContext(source: source)

        var ctx = avformat_alloc_context()
        ctx!.pointee.pb = io.avio
        ctx!.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        // 打开失败时 avformat_open_input 会释放 ctx
        try check(avformat_open_input(&ctx, nil, nil, nil), "打开片源")
        context = ctx
        // 读取码流以补全 TrueHD / DTS 等格式的声道与 profile 信息
        try check(avformat_find_stream_info(ctx, nil), "读取流信息")
        info = Self.inspect(ctx!)
    }

    deinit {
        avformat_close_input(&context)
    }

    var source: ByteSource { io.source }
    /// 片源中下一次读取的位置
    var readPosition: Int64 { io.position }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream> {
        context!.pointee.streams[index]!
    }

    /// 仅读取指定的流，其余流在解封装层丢弃。
    func select(streams: Set<Int>) {
        for i in 0..<Int(context!.pointee.nb_streams) {
            stream(i).pointee.discard = streams.contains(i) ? AVDISCARD_DEFAULT : AVDISCARD_ALL
        }
    }

    /// 读取下一个数据包；到达文件末尾时返回 nil。
    func readPacket() throws -> Packet? {
        let packet = Packet()
        let ret = av_read_frame(context, packet.raw)
        if ret == AVConst.errorEOF { return nil }
        try check(ret, "读取数据包")
        return packet
    }

    /// 定位到目标时间之前最近的关键帧。
    func seek(to seconds: Double) throws {
        let ts = Int64(seconds * Double(AV_TIME_BASE))
        try check(avformat_seek_file(context, -1, .min, ts, ts, 0), "跳转")
    }
}

// MARK: - 流信息

extension Demuxer {
    private static func inspect(_ ctx: UnsafeMutablePointer<AVFormatContext>) -> MediaInfo {
        var videos: [VideoTrackInfo] = []
        var audios: [AudioTrackInfo] = []
        var subtitles: [SubtitleTrackInfo] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            let stream = ctx.pointee.streams[i]!
            let par = UnsafePointer(stream.pointee.codecpar!)
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                // 跳过封面图等附加图片流
                if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 { continue }
                videos.append(videoInfo(index: i, stream: stream, par: par))
            case AVMEDIA_TYPE_AUDIO:
                audios.append(audioInfo(index: i, stream: stream, par: par))
            case AVMEDIA_TYPE_SUBTITLE:
                subtitles.append(subtitleInfo(index: i, stream: stream, par: par))
            default:
                break
            }
        }
        let duration = ctx.pointee.duration > 0 ? Double(ctx.pointee.duration) / Double(AV_TIME_BASE) : nil
        return MediaInfo(
            container: String(cString: ctx.pointee.iformat.pointee.name),
            duration: duration,
            bitRate: ctx.pointee.bit_rate,
            videoTracks: videos,
            audioTracks: audios,
            subtitleTracks: subtitles
        )
    }

    private static func subtitleInfo(index: Int, stream: UnsafeMutablePointer<AVStream>, par: UnsafePointer<AVCodecParameters>) -> SubtitleTrackInfo {
        let format: SubtitleFormat? = switch par.pointee.codec_id {
        case AV_CODEC_ID_HDMV_PGS_SUBTITLE: .pgs
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_TEXT: .srt
        case AV_CODEC_ID_ASS, AV_CODEC_ID_SSA: .ass
        case AV_CODEC_ID_MOV_TEXT: .movText
        case AV_CODEC_ID_WEBVTT: .webVTT
        default: nil
        }
        let disposition = stream.pointee.disposition
        return SubtitleTrackInfo(
            id: index,
            format: format,
            codec: codecName(par.pointee.codec_id),
            language: dictionaryValue(stream.pointee.metadata, "language"),
            title: dictionaryValue(stream.pointee.metadata, "title"),
            isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
            isForced: disposition & AV_DISPOSITION_FORCED != 0,
            isExternal: false,
            header: format == .ass ? par.extradata.map { String(decoding: $0, as: UTF8.self) } : nil
        )
    }

    private static func videoInfo(index: Int, stream: UnsafeMutablePointer<AVStream>, par: UnsafePointer<AVCodecParameters>) -> VideoTrackInfo {
        let p = par.pointee
        let rate = stream.pointee.avg_frame_rate.doubleValue
        let dovi = par.sideData(AV_PKT_DATA_DOVI_CONF).map {
            UnsafeRawPointer($0.baseAddress!).load(as: AVDOVIDecoderConfigurationRecord.self)
        }
        // 色彩信息取自最终提交给系统的格式描述，保证展示与实际渲染一致
        let colors = (try? VideoFormat.make(par)).map(VideoFormat.Colors.init) ?? VideoFormat.Colors()
        let range = dovi != nil ? .dolbyVision : colors.dynamicRange

        var mastering: String?
        if let data = par.sideData(AV_PKT_DATA_MASTERING_DISPLAY_METADATA) {
            let m = UnsafeRawPointer(data.baseAddress!).load(as: AVMasteringDisplayMetadata.self)
            if m.has_luminance != 0 {
                mastering = String(format: "%.4g–%.0f nits", av_q2d(m.min_luminance), av_q2d(m.max_luminance))
            }
        }
        var light: String?
        if let data = par.sideData(AV_PKT_DATA_CONTENT_LIGHT_LEVEL) {
            let c = UnsafeRawPointer(data.baseAddress!).load(as: AVContentLightMetadata.self)
            light = "MaxCLL \(c.MaxCLL) / MaxFALL \(c.MaxFALL)"
        }

        return VideoTrackInfo(
            id: index,
            codec: codecName(p.codec_id),
            profile: profileName(p.codec_id, p.profile) ?? hevcProfile(par),
            width: Int(p.width),
            height: Int(p.height),
            pixelAspectRatio: p.sample_aspect_ratio.num > 0 && p.sample_aspect_ratio.den > 0
                ? p.sample_aspect_ratio.doubleValue : 1,
            frameRate: rate > 0 ? rate : nil,
            bitDepth: bitDepth(par),
            dynamicRange: range,
            colorPrimaries: colors.primaries.map { $0 as String } ?? "未标注",
            transfer: colors.transfer.map { $0 as String } ?? "未标注",
            matrix: colors.matrix.map { $0 as String } ?? "未标注",
            masteringDisplay: mastering,
            contentLightLevel: light,
            dolbyVisionProfile: dovi.map { Int($0.dv_profile) },
            hardwareDecodable: VideoFormat.codecType(for: p.codec_id).map(VTIsHardwareDecodeSupported) ?? false
        )
    }

    private static func audioInfo(index: Int, stream: UnsafeMutablePointer<AVStream>, par: UnsafePointer<AVCodecParameters>) -> AudioTrackInfo {
        let p = par.pointee
        var layout = p.ch_layout
        var buffer = [CChar](repeating: 0, count: 64)
        av_channel_layout_describe(&layout, &buffer, buffer.count)
        return AudioTrackInfo(
            id: index,
            codec: codecName(p.codec_id),
            profile: profileName(p.codec_id, p.profile),
            language: dictionaryValue(stream.pointee.metadata, "language"),
            title: dictionaryValue(stream.pointee.metadata, "title"),
            channels: Int(p.ch_layout.nb_channels),
            channelLayout: String(cBuffer: buffer),
            sampleRate: Int(p.sample_rate),
            isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
            route: AudioRoute(par)
        )
    }

    private static func profileName(_ id: AVCodecID, _ profile: Int32) -> String? {
        guard profile != AV_PROFILE_UNKNOWN, let name = avcodec_profile_name(id, profile) else { return nil }
        return String(cString: name)
    }

    /// 未编译 HEVC 解码器时 FFmpeg 不填充 profile，改从 hvcC 的 general_profile_idc 读取。
    private static func hevcProfile(_ par: UnsafePointer<AVCodecParameters>) -> String? {
        guard par.pointee.codec_id == AV_CODEC_ID_HEVC, let hvcC = par.extradata, hvcC.count > 1, hvcC[0] == 1 else {
            return nil
        }
        return profileName(AV_CODEC_ID_HEVC, Int32(hvcC[1] & 0x1F))
    }

    /// HEVC 位深从 hvcC 读取（未编译 HEVC 解码器时 FFmpeg 无法获得像素格式）。
    private static func bitDepth(_ par: UnsafePointer<AVCodecParameters>) -> Int? {
        let p = par.pointee
        if p.codec_id == AV_CODEC_ID_HEVC, let hvcC = par.extradata, hvcC.count > 17, hvcC[0] == 1 {
            return Int(hvcC[17] & 0x07) + 8
        }
        if let desc = av_pix_fmt_desc_get(AVPixelFormat(p.format)) {
            return Int(desc.pointee.comp.0.depth)
        }
        return nil
    }
}

extension AudioRoute {
    /// 优先使用系统解码能力，系统不支持的格式才交由 FFmpeg 处理。
    init(_ par: UnsafePointer<AVCodecParameters>) {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
            self = .system
        case AV_CODEC_ID_AAC, AV_CODEC_ID_ALAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_MP3:
            self = .audioToolbox
        case AV_CODEC_ID_OPUS:
            // 系统 Opus 解码器只支持单声道与立体声
            self = par.pointee.ch_layout.nb_channels <= 2 ? .audioToolbox : .ffmpeg
        case AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP, AV_CODEC_ID_DTS:
            self = .ffmpeg
        case AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S32LE, AV_CODEC_ID_PCM_F32LE,
             AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_S24BE, AV_CODEC_ID_PCM_S32BE:
            self = .pcm
        default:
            self = .unsupported
        }
    }
}
