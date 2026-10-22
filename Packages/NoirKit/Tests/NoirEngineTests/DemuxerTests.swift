import CFFmpeg
import Testing
@testable import NoirEngine

@Suite struct DemuxerTests {
    @Test("读取 4K HDR10 与 TrueHD 流信息") func hdr10AndTrueHDInfo() throws {
        let info = try TestMedia.demuxer("hdr10-hevc-truehd51.mkv").info
        #expect(info.container.contains("matroska"))
        #expect(abs((info.duration ?? 0) - 10) < 0.5)

        let video = try #require(info.videoTracks.first)
        #expect(video.codec == "hevc")
        #expect(video.width == 3840 && video.height == 2160)
        #expect(video.bitDepth == 10)
        #expect(video.dynamicRange == .hdr10)
        #expect(video.hardwareDecodable)
        #expect(abs((video.frameRate ?? 0) - 23.976) < 0.01)

        let audio = try #require(info.audioTracks.first)
        #expect(audio.codec == "truehd")
        #expect(audio.channels == 6)
        #expect(audio.route == .ffmpeg)
    }

    @Test("识别 HLG 动态范围") func hlgDetection() throws {
        let info = try TestMedia.demuxer("hlg-hevc-eac351.mkv").info
        #expect(info.videoTracks.first?.dynamicRange == .hlg)
        #expect(info.audioTracks.first?.route == .system)
    }

    @Test("多音轨的语言与标题") func multiTrackMetadata() throws {
        let tracks = try TestMedia.demuxer("hdr10-multi-audio.mkv").info.audioTracks
        #expect(tracks.map(\.codec) == ["truehd", "eac3", "aac"])
        #expect(tracks.map(\.language) == ["eng", "jpn", "chi"])
        #expect(tracks[0].title == "TrueHD 5.1")
    }

    @Test("音频处理路径选择", arguments: [
        ("sdr-hevc-dts51.mkv", AudioRoute.ffmpeg),
        ("sdr-hevc-flac71.mkv", .audioToolbox),
        ("sdr-hevc-opus51.mkv", .ffmpeg),
        ("sdr-hevc-opus20.mkv", .audioToolbox),
        ("sdr-hevc-alac20.mkv", .audioToolbox),
        ("sdr-h264-ac351.mkv", .system),
        ("sdr-h264-aac51.mp4", .audioToolbox),
    ])
    func audioRouteSelection(file: String, route: AudioRoute) throws {
        #expect(try TestMedia.demuxer(file).info.audioTracks.first?.route == route)
    }

    @Test("跳转定位到目标之前的关键帧") func seekLandsOnKeyframe() throws {
        let demuxer = try TestMedia.demuxer("hdr10-hevc-truehd51.mkv")
        let video = demuxer.info.videoTracks[0].id
        demuxer.select(streams: [video])
        try demuxer.seek(to: 5)
        let packet = try #require(try demuxer.readPacket())
        let time = demuxer.stream(video).pointee.time_base.time(packet.pts).seconds
        #expect(packet.isKeyframe)
        #expect(time <= 5.01)
    }
}
