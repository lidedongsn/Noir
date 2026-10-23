import CoreMedia
import CoreVideo
import Testing
@testable import NoirEngine

/// 杜比视界：按 'dvh1' 加配置记录描述，由系统硬件解码；Profile 5 的 IPT 画面截图时自行换算。
@Suite struct DolbyVisionTests {
    func format(_ file: String, dolbyVision: Bool = true) throws -> CMVideoFormatDescription {
        let demuxer = try TestMedia.demuxer(file)
        return try VideoFormat.make(UnsafePointer(demuxer.stream(0).pointee.codecpar!), dolbyVision: dolbyVision)
    }

    func atoms(_ format: CMVideoFormatDescription) -> [String: Data] {
        CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Data] ?? [:]
    }

    @Test("识别 Profile 与兼容层", arguments: [("dv-p5.mkv", 5), ("dv-p81.mkv", 8)])
    func mediaInfo(file: String, profile: Int) throws {
        let video = try #require(try TestMedia.demuxer(file).info.videoTracks.first)
        #expect(video.dynamicRange == .dolbyVision)
        #expect(video.dolbyVisionProfile == profile)
    }

    @Test("格式描述为 dvh1 并附带配置记录", arguments: [("dv-p5.mkv", "dvcC", 5, 0), ("dv-p81.mkv", "dvvC", 8, 1)])
    func formatDescription(file: String, atom: String, profile: Int, compatibility: Int) throws {
        let format = try format(file)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC)
        let record = try #require(atoms(format)[atom])
        #expect(record.count == 24)
        #expect(Int(record[2] >> 1) == profile)
        #expect(record[3] & 0x07 == 0b101) // RPU、无增强层、有基础层
        #expect(Int(record[4] >> 4) == compatibility)
        #expect(atoms(format)["hvcC"] != nil)
    }

    @Test("回退时按普通 HEVC 描述") func fallback() throws {
        let format = try format("dv-p5.mkv", dolbyVision: false)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(atoms(format)["dvcC"] == nil)
    }

    /// Profile 5：系统解码器输出 IPT 画面并附带逐帧 RPU，由显示合成器按杜比视界显示
    @Test("Profile 5 硬件解码输出逐帧 RPU") func profile5RPU() throws {
        let frames = try VideoDecoderTests().decode("dv-p5.mkv", count: 8)
        let image = try #require(frames.first).image
        #expect(CVBufferCopyAttachment(image, "DolbyVisionRPUData" as CFString, nil) != nil)
        #expect(DolbyVisionIPT.isIPT(image))
    }

    /// Profile 8.1：输出 HDR10 兼容层（BT.2020 / PQ），与系统播放器一致
    @Test("Profile 8.1 输出 HDR10 兼容层") func profile81() throws {
        let frames = try VideoDecoderTests().decode("dv-p81.mkv", count: 8)
        let image = try #require(frames.first).image
        let transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as? String
        #expect(transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(!DolbyVisionIPT.isIPT(image))
    }

    /// 测试图案左起第一条色带（原为红色）在 IPT 解释下显示为橄榄色；未换算时 CoreImage 会截出原图案的红色
    @Test("Profile 5 截图换算 IPT 色彩") func profile5Thumbnail() throws {
        let image = try #require(try Thumbnailer.make(url: TestMedia.url("dv-p5.mkv"), maxWidth: 480).image)
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // 取第一条色带中部
        let bar = try #require(image.cropping(to: CGRect(x: image.width / 12, y: image.height / 2, width: 1, height: 1)))
        ctx.draw(bar, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel[0] > 60 && pixel[1] > 60 && pixel[2] < 40, "第一条色带应为橄榄色，实际 \(pixel.prefix(3))")
    }
}
