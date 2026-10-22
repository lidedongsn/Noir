import CFFmpeg
import CoreMedia
import Testing
import VideoToolbox
@testable import NoirEngine

/// 以强制硬件解码的 VideoToolbox 会话验证格式描述与样本构造正确，且色彩信息传递至解码输出。
@Suite struct VideoPipelineTests {
    struct Decoded: @unchecked Sendable {
        var pixelFormat: OSType
        var transfer: String?
        var primaries: String?
    }

    func decodeFirstFrames(_ file: String, count: Int = 10) throws -> (CMVideoFormatDescription, [Decoded]) {
        let demuxer = try TestMedia.demuxer(file)
        let index = demuxer.info.videoTracks[0].id
        let stream = demuxer.stream(index)
        let format = try VideoFormat.make(UnsafePointer(stream.pointee.codecpar!))

        let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: spec,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
        )
        try #require(status == noErr, "硬件解码会话创建失败 \(status)")
        defer { VTDecompressionSessionInvalidate(session!) }

        let results = Locked<[Decoded]>([])
        for packet in try demuxer.packets(stream: index, count: count) {
            let sample = try SampleBuffers.video(
                packet: packet, format: format, timeBase: stream.pointee.time_base
            )
            VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                guard status == noErr, let image else { return }
                results.mutate {
                    $0.append(Decoded(
                        pixelFormat: CVPixelBufferGetPixelFormatType(image),
                        transfer: CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as? String,
                        primaries: CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil) as? String
                    ))
                }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session!)
        return (format, results.value)
    }

    @Test("HDR10 硬件解码输出 10 位 PQ") func hdr10HardwareDecode() throws {
        let (format, frames) = try decodeFirstFrames("hdr10-hevc-truehd51.mkv")
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any]
        #expect(ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

        #expect(frames.count == 10)
        let first = try #require(frames.first)
        // 硬件解码器会选择其原生输出格式（'x420'、'p420'、无损压缩的 '&xf0' 等），此处仅校验非 8 位
        #expect(![kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            .contains(first.pixelFormat))
        #expect(first.transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(first.primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    }

    @Test("HLG 硬件解码") func hlgHardwareDecode() throws {
        let (_, frames) = try decodeFirstFrames("hlg-hevc-eac351.mkv")
        #expect(frames.count == 10)
        #expect(frames.first?.transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    @Test("从 SPS VUI 读取色彩信息") func colorsFromVUI() throws {
        let demuxer = try TestMedia.demuxer("hdr10-hevc-truehd51.mkv")
        let par = UnsafePointer(demuxer.stream(demuxer.info.videoTracks[0].id).pointee.codecpar!)
        let colors = VideoFormat.colorsFromParameterSets(codec: par.pointee.codec_id, config: par.extradata!)
        #expect(colors.transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        #expect(colors.primaries == kCMFormatDescriptionColorPrimaries_ITU_R_2020)
        #expect(colors.matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
    }

    @Test("H.264 硬件解码") func h264HardwareDecode() throws {
        let (_, frames) = try decodeFirstFrames("sdr-h264-ac351.mkv")
        #expect(frames.count == 10)
    }
}

final class Locked<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&_value) } }
}

/// 自行解码路径：VideoToolbox 按解码顺序输出，VideoDecoder 需按显示顺序重排，且保留色彩与 HDR 元数据。
@Suite struct VideoDecoderTests {
    func decode(_ file: String, count: Int, extensions extra: [CFString: Any] = [:]) throws -> [VideoDecoder.Frame] {
        let demuxer = try TestMedia.demuxer(file)
        let index = try #require(demuxer.info.videoTracks.first).id
        let stream = demuxer.stream(index)
        let par = UnsafePointer(stream.pointee.codecpar!)
        var format = try VideoFormat.make(par)
        if !extra.isEmpty {
            var extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] ?? [:]
            extensions.merge(extra) { $1 }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var updated: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: CMFormatDescriptionGetMediaSubType(format),
                width: dimensions.width, height: dimensions.height,
                extensions: extensions as CFDictionary, formatDescriptionOut: &updated
            )
            format = try #require(updated)
        }
        let decoder = try VideoDecoder(format: format, reorderDepth: VideoDecoder.reorderDepth(par))
        var frames: [VideoDecoder.Frame] = []
        for packet in try demuxer.packets(stream: index, count: count) {
            try decoder.decode(SampleBuffers.video(packet: packet, format: format, timeBase: stream.pointee.time_base))
            while let frame = decoder.nextFrame(draining: false) { frames.append(frame) }
        }
        decoder.finish()
        while let frame = decoder.nextFrame(draining: true) { frames.append(frame) }
        return frames
    }

    @Test("输出按显示顺序排列", arguments: ["sdr-h264-bpyramid.mp4", "hdr10-hevc-truehd51.mkv", "sdr-hevc-alac20.mkv"])
    func displayOrder(file: String) throws {
        let frames = try decode(file, count: 96)
        #expect(frames.count == 96)
        let times = frames.map(\.pts.seconds)
        #expect(times == times.sorted(), "\(file) 输出顺序：\(times.prefix(12))")
    }

    @Test("从 HEVC SPS 读取重排序深度") func hevcReorderDepth() throws {
        let demuxer = try TestMedia.demuxer("hdr10-hevc-truehd51.mkv")
        let par = UnsafePointer(demuxer.stream(0).pointee.codecpar!)
        let depth = try #require(par.extradata.flatMap(ParameterSets.hevcReorderDepth))
        #expect((1...4).contains(depth))
    }

    @Test("HDR10 画面保留 10 位、PQ 与母版显示信息") func hdrAttachments() throws {
        // 测试片源的 HDR 静态元数据只在 SEI 中，这里补入格式描述，验证解码画面会携带容器提供的元数据
        let mastering = Data(repeating: 0x10, count: 24), light = Data([0x03, 0xE8, 0x01, 0x90])
        let frame = try #require(try decode("hdr10-hevc-truehd51.mkv", count: 8, extensions: [
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume: mastering,
            kCMFormatDescriptionExtension_ContentLightLevelInfo: light,
        ]).first)
        let format = CVPixelBufferGetPixelFormatType(frame.image)
        #expect(![kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(format))
        #expect(CVBufferCopyAttachment(frame.image, kCVImageBufferTransferFunctionKey, nil) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(CVBufferCopyAttachment(frame.image, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data == mastering)
        #expect(CVBufferCopyAttachment(frame.image, kCVImageBufferContentLightLevelInfoKey, nil) as? Data == light)
    }
}
