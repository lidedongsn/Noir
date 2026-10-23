import CFFmpeg
import CoreImage
import CoreMedia
import Foundation

/// 片库封面：读取媒体信息，并从片中截取一帧作为封面。
/// 只解码目标位置附近的一个关键帧；HDR 画面经 CoreImage 色调映射为 SDR。
public enum Thumbnailer {
    public struct Result: Sendable {
        public var info: MediaInfo
        public var image: CGImage?
    }

    /// 依次尝试的位置（占片长的比例）；画面过暗（黑场、片头字幕）时换下一个
    private static let positions = [0.1, 0.2, 0.35, 0.5]
    /// 平均亮度低于此值视为过暗
    private static let darkThreshold = 0.12

    /// 读取片源并截取封面，宽度不超过 maxWidth 像素。耗时操作，勿在主线程调用。
    public static func make(url: URL, maxWidth: Int) throws -> Result {
        try withVideo(url) { demuxer, video in
            guard let video else { return Result(info: demuxer.info, image: nil) }
            let duration = demuxer.info.duration ?? 0
            var fallback: CGImage?
            for position in duration > 0 ? positions : [0] {
                guard let image = try? video.keyframe(demuxer, at: duration * position, maxWidth: maxWidth) else { continue }
                if averageLuma(image) >= darkThreshold { return Result(info: demuxer.info, image: image) }
                fallback = fallback ?? image
            }
            return Result(info: demuxer.info, image: fallback)
        }
    }

    /// 精确截取 seconds 处显示的画面（续播封面）：从之前的关键帧解码到目标时间
    public static func frame(url: URL, at seconds: Double, maxWidth: Int) throws -> CGImage? {
        try withVideo(url) { demuxer, video in
            try video?.exactFrame(demuxer, at: seconds, maxWidth: maxWidth)
        }
    }

    /// 打开片源并准备视频轨的解码参数
    private static func withVideo<T>(_ url: URL, _ body: (Demuxer, Video?) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let demuxer = try Demuxer(source: try FileByteSource(url: url))
        guard let track = demuxer.info.videoTracks.first else { return try body(demuxer, nil) }
        let stream = demuxer.stream(track.id)
        let par = UnsafePointer(stream.pointee.codecpar!)
        // 与播放一致：杜比视界优先，系统不支持时回退为兼容层
        let format = [true, false].lazy.compactMap { dolbyVision -> CMVideoFormatDescription? in
            guard let format = try? VideoFormat.make(par, dolbyVision: dolbyVision),
                  (try? VideoDecoder(format: format, reorderDepth: 0)) != nil else { return nil }
            return format
        }.first
        guard let format else { return try body(demuxer, nil) }
        demuxer.select(streams: [track.id])
        let video = Video(format: format, timeBase: stream.pointee.time_base, size: track.displaySize,
                          reorderDepth: VideoDecoder.reorderDepth(par))
        return try body(demuxer, video)
    }

    private struct Video {
        var format: CMVideoFormatDescription
        var timeBase: AVRational
        var size: CGSize
        var reorderDepth: Int

        /// 解码 seconds 之前最近的关键帧
        func keyframe(_ demuxer: Demuxer, at seconds: Double, maxWidth: Int) throws -> CGImage? {
            try demuxer.seek(to: seconds)
            // 每个位置单独创建解码器，避免上一个位置的参考帧影响
            let decoder = try VideoDecoder(format: format, reorderDepth: 0)
            while let packet = try demuxer.readPacket() {
                guard packet.isKeyframe else { continue }
                try decoder.decode(SampleBuffers.video(packet: packet, format: format, timeBase: timeBase))
                decoder.finish()
                guard let frame = decoder.nextFrame(draining: true) else { return nil }
                return render(frame.image, size: size, maxWidth: maxWidth)
            }
            return nil
        }

        /// 解码到 seconds 处正在显示的那一帧（显示时间不晚于 seconds 的最后一帧）
        func exactFrame(_ demuxer: Demuxer, at seconds: Double, maxWidth: Int) throws -> CGImage? {
            try demuxer.seek(to: seconds)
            let decoder = try VideoDecoder(format: format, reorderDepth: reorderDepth)
            let target = CMTime(seconds: seconds, preferredTimescale: 90_000)
            var shown: VideoDecoder.Frame?
            func take(draining: Bool) -> Bool {
                while let frame = decoder.nextFrame(draining: draining) {
                    if frame.pts > target { return true }
                    shown = frame
                }
                return false
            }
            // 关键帧间隔较长的片源也能覆盖（60 fps 下约 20 秒）
            for _ in 0..<1200 {
                guard let packet = try demuxer.readPacket() else { break }
                try decoder.decode(SampleBuffers.video(packet: packet, format: format, timeBase: timeBase))
                if take(draining: false) { break }
            }
            decoder.finish()
            _ = take(draining: true)
            return shown.flatMap { render($0.image, size: size, maxWidth: maxWidth) }
        }
    }

    /// CIContext 线程安全，可在多个线程同时渲染
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 按显示宽高比（考虑非方形像素）缩放，输出 sRGB
    private static func render(_ buffer: CVImageBuffer, size: CGSize, maxWidth: Int) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let width = min(CGFloat(maxWidth), size.width)
        let height = (width * size.height / size.width).rounded()
        // 杜比视界 Profile 5 的 IPT 画面需先换算为 RGB
        let source = DolbyVisionIPT.isIPT(buffer)
            ? DolbyVisionIPT.convert(buffer, width: Int(width), height: Int(height)) ?? buffer
            : buffer
        let image = CIImage(cvImageBuffer: source, options: [.toneMapHDRtoSDR: true])
        guard !image.extent.isEmpty else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: width / image.extent.width, y: height / image.extent.height
        ))
        return context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// 缩到 16×16 后计算平均亮度（0–1）
    static func averageLuma(_ image: CGImage) -> Double {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 1 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return sum / Double(side * side) / 255
    }
}
