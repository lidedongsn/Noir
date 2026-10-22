import Foundation

/// 从 hvcC / avcC 解码配置记录中取出参数集 NAL
enum ParameterSets {
    /// ISO/IEC 14496-15 8.3.3.1：22 字节固定头，之后是按 NAL 类型分组的数组
    static func hevc(_ hvcC: Data) -> (sets: [Data], lengthSize: Int)? {
        let b = [UInt8](hvcC)
        guard b.count > 23, b[0] == 1 else { return nil }
        let lengthSize = Int(b[21] & 0x03) + 1
        var sets: [Data] = []
        var i = 23
        for _ in 0..<Int(b[22]) {
            guard i + 3 <= b.count else { return nil }
            let type = b[i] & 0x3F
            let count = Int(b[i + 1]) << 8 | Int(b[i + 2])
            i += 3
            for _ in 0..<count {
                guard i + 2 <= b.count else { return nil }
                let length = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard i + length <= b.count else { return nil }
                // 仅提取 VPS / SPS / PPS
                if (32...34).contains(type) { sets.append(Data(b[i..<(i + length)])) }
                i += length
            }
        }
        return (sets, lengthSize)
    }

    /// ISO/IEC 14496-15 5.3.3.1
    static func avc(_ avcC: Data) -> (sets: [Data], lengthSize: Int)? {
        let b = [UInt8](avcC)
        guard b.count > 6, b[0] == 1 else { return nil }
        let lengthSize = Int(b[4] & 0x03) + 1
        var sets: [Data] = []
        var i = 5
        for group in 0..<2 {
            guard i < b.count else { return nil }
            let count = group == 0 ? Int(b[i] & 0x1F) : Int(b[i])
            i += 1
            for _ in 0..<count {
                guard i + 2 <= b.count else { return nil }
                let length = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard i + length <= b.count else { return nil }
                sets.append(Data(b[i..<(i + length)]))
                i += length
            }
        }
        return (sets, lengthSize)
    }
}

// MARK: - 重排序深度

extension ParameterSets {
    /// HEVC SPS 的 sps_max_num_reorder_pics（最高时域子层），即显示顺序相对解码顺序最多延后的帧数
    static func hevcReorderDepth(_ hvcC: Data) -> Int? {
        guard let sps = hevc(hvcC)?.sets.first(where: { ($0.first ?? 0) >> 1 & 0x3F == 33 }) else { return nil }
        var r = BitReader(nal: sps.dropFirst(2)) // 跳过 2 字节 NAL 头
        r.skip(4)                                // sps_video_parameter_set_id
        let maxSubLayersMinus1 = r.bits(3)
        r.skip(1)                                // sps_temporal_id_nesting_flag
        // profile_tier_level：通用部分 96 位，之后为各子层标志与可选信息
        r.skip(96)
        var profilePresent: [Bool] = [], levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(r.bits(1) == 1)
            levelPresent.append(r.bits(1) == 1)
        }
        if maxSubLayersMinus1 > 0 { r.skip(2 * (8 - maxSubLayersMinus1)) }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i] { r.skip(88) }
            if levelPresent[i] { r.skip(8) }
        }
        _ = r.ue()                               // sps_seq_parameter_set_id
        if r.ue() == 3 { r.skip(1) }             // chroma_format_idc，4:4:4 时有 separate_colour_plane_flag
        _ = r.ue(); _ = r.ue()                   // 宽、高
        if r.bits(1) == 1 { for _ in 0..<4 { _ = r.ue() } } // conformance_window
        _ = r.ue(); _ = r.ue()                   // 亮度、色度位深
        _ = r.ue()                               // log2_max_pic_order_cnt_lsb_minus4
        let allLayers = r.bits(1) == 1           // sps_sub_layer_ordering_info_present_flag
        var reorder = 0
        for _ in (allLayers ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = r.ue()                           // sps_max_dec_pic_buffering_minus1
            reorder = r.ue()                     // sps_max_num_reorder_pics
            _ = r.ue()                           // sps_max_latency_increase_plus1
        }
        return r.overrun ? nil : reorder
    }
}

/// RBSP 位读取，自动去除防竞争字节（00 00 03）
struct BitReader {
    private var bytes: [UInt8] = []
    private var position = 0
    private(set) var overrun = false

    init(nal: Data) {
        var zeros = 0
        for byte in nal {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            bytes.append(byte)
        }
    }

    mutating func bits(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            guard position < bytes.count * 8 else {
                overrun = true
                return value
            }
            value = value << 1 | Int(bytes[position / 8] >> (7 - position % 8) & 1)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) {
        position += count
        if position > bytes.count * 8 { overrun = true }
    }

    /// 无符号指数哥伦布码
    mutating func ue() -> Int {
        var zeros = 0
        while bits(1) == 0, !overrun, zeros < 32 { zeros += 1 }
        return (1 << zeros) - 1 + bits(zeros)
    }
}
