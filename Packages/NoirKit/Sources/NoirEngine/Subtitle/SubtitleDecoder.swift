import CFFmpeg
import CoreGraphics
import Foundation

/// 内封字幕数据包的解码，结果写入 SubtitleTrack。仅在播放队列上调用。
final class SubtitleDecoder {
    private let track: SubtitleTrack
    private let timeBase: AVRational
    private let format: SubtitleFormat
    private var pgs: UnsafeMutablePointer<AVCodecContext>?

    init(stream: UnsafeMutablePointer<AVStream>, track: SubtitleTrack) throws {
        self.track = track
        timeBase = stream.pointee.time_base
        format = track.info.format ?? .srt
        guard format == .pgs else { return }

        let par = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE) else {
            throw FFmpegError(code: AVConst.errorAgain, context: "未编译 PGS 解码器")
        }
        pgs = avcodec_alloc_context3(codec)
        try check(avcodec_parameters_to_context(pgs, par), "复制字幕参数")
        pgs!.pointee.pkt_timebase = timeBase
        try check(avcodec_open2(pgs, codec, nil), "打开 PGS 解码器")
    }

    deinit {
        avcodec_free_context(&pgs)
    }

    func flush() {
        if let pgs { avcodec_flush_buffers(pgs) }
    }

    func decode(_ packet: Packet) {
        if format == .pgs {
            decodePGS(packet)
        } else {
            decodeText(packet)
        }
    }

    // MARK: - 文本

    private func decodeText(_ packet: Packet) {
        guard let data = packet.data, packet.size > 0 else { return }
        let start = timeBase.time(packet.pts).seconds
        guard start.isFinite else { return }
        let duration = timeBase.time(packet.duration).seconds
        let end = start + (duration.isFinite && duration > 0 ? duration : 5)

        var bytes = UnsafeRawBufferPointer(start: data, count: packet.size)
        if format == .movText {
            // Timed Text：2 字节大端文本长度，其后为 UTF-8 文本与样式盒
            guard bytes.count >= 2 else { return }
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            bytes = UnsafeRawBufferPointer(rebasing: bytes[2..<min(2 + length, bytes.count)])
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let key = Int64((start * 1000).rounded())
        let cue = format == .ass
            ? SubtitleText.assPacket(text, start: start, end: end, script: track.script)
            : SubtitleText.plainCue(text, start: start, end: end, key: key)
        if let cue { track.insert(cue) }
    }

    // MARK: - PGS

    private func decodePGS(_ packet: Packet) {
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(pgs, &subtitle, &got, packet.raw) >= 0, got != 0 else { return }
        defer { avsubtitle_free(&subtitle) }

        let pts = subtitle.pts != AVConst.noPTS
            ? Double(subtitle.pts) / Double(AV_TIME_BASE)
            : timeBase.time(packet.pts).seconds
        guard pts.isFinite else { return }
        let start = pts + Double(subtitle.start_display_time) / 1000

        var bitmaps: [SubtitleBitmap] = []
        for i in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[i]?.pointee, rect.type == SUBTITLE_BITMAP,
                  rect.w > 0, rect.h > 0, let bitmap = Self.bitmap(rect) else { continue }
            bitmaps.append(bitmap)
        }
        guard !bitmaps.isEmpty else {
            track.close(at: start)
            return
        }
        let canvas = CGSize(width: Int(pgs!.pointee.width), height: Int(pgs!.pointee.height))
        let end = subtitle.end_display_time == UInt32.max
            ? Double.infinity
            : pts + Double(subtitle.end_display_time) / 1000
        track.insert(SubtitleCue(
            start: start, end: end, key: Int64((start * 1000).rounded()),
            content: .bitmaps(bitmaps, canvas: canvas)
        ))
    }

    /// 调色板索引图转换为预乘 RGBA 图像
    private static func bitmap(_ rect: AVSubtitleRect) -> SubtitleBitmap? {
        let width = Int(rect.w), height = Int(rect.h)
        guard let indices = rect.data.0, let paletteData = rect.data.1 else { return nil }
        let stride = Int(rect.linesize.0)
        var palette = [UInt32](repeating: 0, count: 256)
        paletteData.withMemoryRebound(to: UInt32.self, capacity: 256) { source in
            for i in 0..<Int(min(rect.nb_colors, 256)) {
                // FFmpeg 调色板为 ARGB（非预乘）
                let argb = source[i]
                let a = argb >> 24, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF
                let pr = r * a / 255, pg = g * a / 255, pb = b * a / 255
                palette[i] = pr | pg << 8 | pb << 16 | a << 24
            }
        }
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = palette[Int(indices[y * stride + x])]
            }
        }
        // 小端存储下 UInt32 的字节顺序为 R、G、B、A
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return SubtitleBitmap(image: image, rect: CGRect(x: Int(rect.x), y: Int(rect.y), width: width, height: height))
    }
}
