import CFFmpeg
import CoreMedia

enum VideoFormatError: Error, CustomStringConvertible {
    case unsupportedCodec(String)
    case missingConfiguration(String)
    case coreMedia(OSStatus)

    var description: String {
        switch self {
        case .unsupportedCodec(let name): "不支持的视频编码：\(name)"
        case .missingConfiguration(let name): "\(name) 缺少解码配置（可能是 Annex B 码流）"
        case .coreMedia(let status): "创建视频格式描述失败（\(status)）"
        }
    }
}

/// 由 FFmpeg 的流参数构造 CMVideoFormatDescription。
/// 压缩数据原样提交给系统解码，此处负责完整传递解码配置、色彩信息与 HDR 元数据。
enum VideoFormat {
    static func codecType(for id: AVCodecID) -> CMVideoCodecType? {
        switch id {
        case AV_CODEC_ID_HEVC: kCMVideoCodecType_HEVC
        case AV_CODEC_ID_H264: kCMVideoCodecType_H264
        case AV_CODEC_ID_AV1: kCMVideoCodecType_AV1
        default: nil
        }
    }

    static func make(_ par: UnsafePointer<AVCodecParameters>) throws -> CMVideoFormatDescription {
        let p = par.pointee
        let name = codecName(p.codec_id)
        guard let codecType = codecType(for: p.codec_id) else {
            throw VideoFormatError.unsupportedCodec(name)
        }
        // MKV / MP4 中的 extradata 是 hvcC / avcC / av1C 记录，首字节为版本号 1
        guard let config = par.extradata, config.first == 1 else {
            throw VideoFormatError.missingConfiguration(name)
        }
        let atomName = switch p.codec_id {
        case AV_CODEC_ID_HEVC: "hvcC"
        case AV_CODEC_ID_H264: "avcC"
        default: "av1C"
        }

        var ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atomName: config],
            kCMFormatDescriptionExtension_FullRangeVideo: p.color_range == AVCOL_RANGE_JPEG,
        ]
        // 容器未标注色彩信息时，回退到码流 SPS 中的 VUI
        let vui = colorsFromParameterSets(codec: p.codec_id, config: config)
        ext[kCMFormatDescriptionExtension_ColorPrimaries] = colorPrimaries(p.color_primaries) ?? vui.primaries
        ext[kCMFormatDescriptionExtension_TransferFunction] = transferFunction(p.color_trc) ?? vui.transfer
        ext[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix(p.color_space) ?? vui.matrix
        if let v = masteringDisplay(par) { ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = v }
        if let v = contentLightLevel(par) { ext[kCMFormatDescriptionExtension_ContentLightLevelInfo] = v }

        let sar = p.sample_aspect_ratio
        if sar.num > 0, sar.den > 0, sar.num != sar.den {
            ext[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: sar.num,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: sar.den,
            ]
        }

        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: p.width,
            height: p.height,
            extensions: ext as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw VideoFormatError.coreMedia(status) }
        return format
    }

    // MARK: 码流中的色彩信息

    struct Colors {
        var primaries: CFString?
        var transfer: CFString?
        var matrix: CFString?

        init(primaries: CFString? = nil, transfer: CFString? = nil, matrix: CFString? = nil) {
            self.primaries = primaries
            self.transfer = transfer
            self.matrix = matrix
        }

        init(_ format: CMFormatDescription) {
            func value(_ key: CFString) -> CFString? {
                CMFormatDescriptionGetExtension(format, extensionKey: key).map { $0 as! CFString }
            }
            self.init(
                primaries: value(kCMFormatDescriptionExtension_ColorPrimaries),
                transfer: value(kCMFormatDescriptionExtension_TransferFunction),
                matrix: value(kCMFormatDescriptionExtension_YCbCrMatrix)
            )
        }

        var dynamicRange: DynamicRange {
            switch transfer {
            case kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ: .hdr10
            case kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG: .hlg
            default: .sdr
            }
        }
    }

    /// 由 CoreMedia 解析参数集，获取 SPS VUI 中的色彩信息。
    static func colorsFromParameterSets(codec: AVCodecID, config: Data) -> Colors {
        let parsed: (sets: [Data], lengthSize: Int)? = switch codec {
        case AV_CODEC_ID_HEVC: ParameterSets.hevc(config)
        case AV_CODEC_ID_H264: ParameterSets.avc(config)
        default: nil
        }
        guard let parsed, !parsed.sets.isEmpty else { return Colors() }

        var format: CMFormatDescription?
        let pointers = parsed.sets.map { set in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: p, count: set.count)
            return UnsafePointer(p)
        }
        defer { pointers.forEach { $0.deallocate() } }
        let sizes = parsed.sets.map(\.count)
        let status = codec == AV_CODEC_ID_HEVC
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(parsed.lengthSize), extensions: nil, formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(parsed.lengthSize), formatDescriptionOut: &format)
        guard status == noErr, let format else { return Colors() }
        return Colors(format)
    }

    // MARK: 色彩三要素

    private static func colorPrimaries(_ v: AVColorPrimaries) -> CFString? {
        switch v {
        case AVCOL_PRI_BT2020: kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case AVCOL_PRI_BT709: kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_SMPTE432: kCMFormatDescriptionColorPrimaries_P3_D65
        case AVCOL_PRI_SMPTE431: kCMFormatDescriptionColorPrimaries_DCI_P3
        case AVCOL_PRI_BT470BG: kCMFormatDescriptionColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCMFormatDescriptionColorPrimaries_SMPTE_C
        default: nil
        }
    }

    private static func transferFunction(_ v: AVColorTransferCharacteristic) -> CFString? {
        switch v {
        case AVCOL_TRC_SMPTE2084: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
            kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE240M: kCMFormatDescriptionTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_IEC61966_2_1: kCMFormatDescriptionTransferFunction_sRGB
        case AVCOL_TRC_LINEAR: kCMFormatDescriptionTransferFunction_Linear
        default: nil
        }
    }

    private static func matrix(_ v: AVColorSpace) -> CFString? {
        switch v {
        case AVCOL_SPC_BT2020_NCL: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_BT709: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M: kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995
        default: nil
        }
    }

    // MARK: HDR 静态元数据

    /// ISO/IEC 23008-2 D.2.28 的大端结构：三原色按 G、B、R 顺序，单位 0.00002；亮度单位 0.0001 nit
    static func masteringDisplay(_ par: UnsafePointer<AVCodecParameters>) -> Data? {
        guard let raw = par.sideData(AV_PKT_DATA_MASTERING_DISPLAY_METADATA) else { return nil }
        let m = UnsafeRawPointer(raw.baseAddress!).load(as: AVMasteringDisplayMetadata.self)
        guard m.has_primaries != 0, m.has_luminance != 0 else { return nil }

        var data = Data(capacity: 24)
        func chroma(_ q: AVRational) { data.appendBigEndian(UInt16(clamping: Int((av_q2d(q) * 50_000).rounded()))) }
        let primaries = [m.display_primaries.0, m.display_primaries.1, m.display_primaries.2]
        for c in [1, 2, 0] { // FFmpeg 按 R、G、B 存储
            chroma(primaries[c].0)
            chroma(primaries[c].1)
        }
        chroma(m.white_point.0)
        chroma(m.white_point.1)
        data.appendBigEndian(UInt32(clamping: Int((av_q2d(m.max_luminance) * 10_000).rounded())))
        data.appendBigEndian(UInt32(clamping: Int((av_q2d(m.min_luminance) * 10_000).rounded())))
        return data
    }

    /// ISO/IEC 23008-2 D.2.35：MaxCLL、MaxFALL 各 16 位大端
    static func contentLightLevel(_ par: UnsafePointer<AVCodecParameters>) -> Data? {
        guard let raw = par.sideData(AV_PKT_DATA_CONTENT_LIGHT_LEVEL) else { return nil }
        let c = UnsafeRawPointer(raw.baseAddress!).load(as: AVContentLightMetadata.self)
        var data = Data(capacity: 4)
        data.appendBigEndian(UInt16(clamping: c.MaxCLL))
        data.appendBigEndian(UInt16(clamping: c.MaxFALL))
        return data
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
