import CoreMedia
import Testing
@testable import NoirEngine

/// 相邻音频样本的时间戳必须首尾相接：容器时间戳精度有限（MKV 为毫秒），
/// 直接使用会留下零点几毫秒的空隙或重叠，播放时表现为呲啦声与电流声
@Suite struct AudioTimelineTests {
    @Test("解码输出的音频时间戳连续", arguments: [
        "sdr-hevc-dts51.mkv", "hdr10-hevc-truehd51.mkv", "hlg-hevc-eac351.mkv", "sdr-h264-ac351.mkv",
        "sdr-hevc-flac71.mkv", "sdr-hevc-opus51.mkv", "sdr-hevc-alac20.mkv", "sdr-h264-aac51.mp4",
    ])
    func contiguous(file: String) throws {
        let demuxer = try Demuxer(source: FileByteSource(url: TestMedia.url(file)))
        let track = try #require(demuxer.info.audioTracks.first)
        demuxer.select(streams: [track.id])
        try demuxer.seek(to: 2)
        let decoder = try AudioDecoders.make(stream: demuxer.stream(track.id))
        var lastEnd: CMTime?
        var gaps: [Double] = []
        var buffers = 0
        while buffers < 400, let packet = try demuxer.readPacket() {
            for sample in try decoder.decode(packet) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if let lastEnd, abs((pts - lastEnd).seconds) > 1e-6 { gaps.append((pts - lastEnd).seconds) }
                lastEnd = pts + CMSampleBufferGetDuration(sample)
                buffers += 1
            }
        }
        #expect(buffers > 50)
        #expect(gaps.isEmpty, "\(file)（\(decoder.route)）有 \(gaps.count) 处不连续，如 \(gaps.prefix(3).map { String(format: "%.5f", $0) })")
    }
}
