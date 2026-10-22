import CFFmpeg

/// AVPacket 的所有权封装。视频样本以零拷贝方式引用其数据，生命周期由 CMBlockBuffer 持有。
final class Packet {
    let raw: UnsafeMutablePointer<AVPacket>

    init() {
        raw = av_packet_alloc()
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = raw
        av_packet_free(&p)
    }

    var streamIndex: Int { Int(raw.pointee.stream_index) }
    var isKeyframe: Bool { raw.pointee.flags & AV_PKT_FLAG_KEY != 0 }
    var pts: Int64 { raw.pointee.pts }
    var dts: Int64 { raw.pointee.dts }
    var duration: Int64 { raw.pointee.duration }
    var size: Int { Int(raw.pointee.size) }
    var data: UnsafeMutableRawPointer? { raw.pointee.data.map(UnsafeMutableRawPointer.init) }
}
