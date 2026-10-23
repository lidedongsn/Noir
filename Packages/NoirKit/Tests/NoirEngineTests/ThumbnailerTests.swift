import CoreGraphics
import Testing
@testable import NoirEngine

@Suite struct ThumbnailerTests {
    @Test("按显示比例缩放封面", arguments: [
        ("hdr10-hevc-truehd51.mkv", 960, 540),
        ("scope-239.mkv", 960, 402),
        ("sdr-h264-aac51.mp4", 960, 540),
    ])
    func size(file: String, width: Int, height: Int) throws {
        let result = try Thumbnailer.make(url: TestMedia.url(file), maxWidth: 960)
        let image = try #require(result.image)
        #expect(image.width == width)
        #expect(image.height == height)
        #expect(result.info.duration ?? 0 > 9)
    }

    /// 同一测试图案的 HDR10 与 SDR 版本，色调映射后亮度应接近（未映射时 PQ 画面会明显偏暗或发灰）
    @Test func hdrToneMapped() throws {
        let hdr = try #require(try Thumbnailer.make(url: TestMedia.url("hdr10-hevc-truehd51.mkv"), maxWidth: 480).image)
        let sdr = try #require(try Thumbnailer.make(url: TestMedia.url("sdr-hevc-flac71.mkv"), maxWidth: 480).image)
        let (h, s) = (Thumbnailer.averageLuma(hdr), Thumbnailer.averageLuma(sdr))
        #expect(abs(h - s) < 0.15, "HDR \(h) SDR \(s)")
    }

    /// testsrc2 左上角印有当前时间，不同时间截到的画面应不同；同一时间重复截取结果一致
    @Test("精确截取指定时间的画面") func exactFrame() throws {
        let url = TestMedia.url("sdr-h264-bpyramid.mp4")
        let a = try #require(try Thumbnailer.frame(url: url, at: 4.5, maxWidth: 480))
        let b = try #require(try Thumbnailer.frame(url: url, at: 4.5, maxWidth: 480))
        let c = try #require(try Thumbnailer.frame(url: url, at: 6.2, maxWidth: 480))
        #expect(a.width == 480)
        #expect(pixels(a) == pixels(b))
        #expect(pixels(a) != pixels(c))
        // 24 fps：4.51 秒仍显示 4.5 秒那一帧，4.56 秒已是下一帧，说明截取精确到帧而非关键帧
        let sameFrame = try #require(try Thumbnailer.frame(url: url, at: 4.51, maxWidth: 480))
        let nextFrame = try #require(try Thumbnailer.frame(url: url, at: 4.56, maxWidth: 480))
        #expect(pixels(a) == pixels(sameFrame))
        #expect(pixels(a) != pixels(nextFrame))
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
