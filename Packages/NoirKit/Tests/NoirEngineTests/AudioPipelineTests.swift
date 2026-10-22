import CFFmpeg
import CoreMedia
import Testing
@testable import NoirEngine

/// 测试片源中第 k 秒仅第 k 个声道有信号。
/// 逐秒检查能量最大的声道，同时验证解码结果与声道映射。
@Suite struct AudioPipelineTests {
    struct Decoded {
        var channels: Int
        var sampleRate: Double
        var samples: [Float] // 交错
        var labels: [AudioChannelLabel] = []
    }

    func decode(_ file: String, seconds: Double) throws -> (AudioDecoder, Decoded) {
        let demuxer = try TestMedia.demuxer(file)
        let index = demuxer.info.audioTracks[0].id
        let decoder = try AudioDecoders.make(stream: demuxer.stream(index))
        demuxer.select(streams: [index])

        var result = Decoded(channels: 0, sampleRate: 0, samples: [])
        while let packet = try demuxer.readPacket() {
            // find_stream_info 期间缓存的包不受 discard 影响，须按流号过滤
            guard packet.streamIndex == index else { continue }
            for sample in try decoder.decode(packet) {
                let format = CMSampleBufferGetFormatDescription(sample)!
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
                result.channels = Int(asbd.mChannelsPerFrame)
                result.sampleRate = asbd.mSampleRate
                result.labels = labels(format)
                guard asbd.mFormatID == kAudioFormatLinearPCM else { continue }
                let block = CMSampleBufferGetDataBuffer(sample)!
                var floats = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                floats.withUnsafeMutableBytes {
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                result.samples += floats
            }
            if result.sampleRate > 0, Double(result.samples.count / max(result.channels, 1)) >= seconds * result.sampleRate {
                break
            }
        }
        return (decoder, result)
    }

    func labels(_ format: CMAudioFormatDescription) -> [AudioChannelLabel] {
        var size = 0
        guard let acl = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size) else { return [] }
        let n = Int(acl.pointee.mNumberChannelDescriptions)
        return UnsafeBufferPointer(start: ChannelLayout.descriptionsPointer(UnsafeMutablePointer(mutating: acl)), count: n)
            .map(\.mChannelLabel)
    }

    /// 源声道 k 应有的标签：与生产代码用同一套映射（未指定顺序时按声道数取默认布局）
    func sourceLabels(_ file: String) throws -> [AudioChannelLabel] {
        let demuxer = try TestMedia.demuxer(file)
        var data = ChannelLayout.coreAudio(demuxer.stream(demuxer.info.audioTracks[0].id).pointee.codecpar.pointee.ch_layout)
        return data.withUnsafeMutableBytes { raw in
            let acl = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            let n = Int(acl.pointee.mNumberChannelDescriptions)
            return UnsafeBufferPointer(start: ChannelLayout.descriptionsPointer(acl), count: n).map(\.mChannelLabel)
        }
    }

    /// 第 second 秒中间 0.5 秒内，每个声道的均方能量
    func energy(_ d: Decoded, second: Int) -> [Float] {
        let start = Int((Double(second) + 0.25) * d.sampleRate)
        let end = Int((Double(second) + 0.75) * d.sampleRate)
        var e = [Float](repeating: 0, count: d.channels)
        for f in start..<end {
            for c in 0..<d.channels {
                let v = d.samples[f * d.channels + c]
                e[c] += v * v
            }
        }
        return e
    }

    func expectChannelOrder(_ file: String, channels: Int, route: AudioRoute, lfeIndex: Int? = 3) throws {
        let (decoder, d) = try decode(file, seconds: Double(channels))
        #expect(decoder.route == route)
        #expect(d.channels == channels)
        #expect(d.sampleRate == 48_000)
        // 按声道标签核对：输出顺序可与源不同，但第 k 秒的有效声道须带有源声道 k 的标签
        let expected = try sourceLabels(file)
        #expect(d.labels.count == channels)
        for k in 0..<channels where k != lfeIndex { // 有损编码会滤除 LFE 声道的高频测试信号
            let e = energy(d, second: k)
            let loudest = e.indices.max { e[$0] < e[$1] }!
            #expect(d.labels[loudest] == expected[k],
                    "\(file) 第 \(k) 秒应为标签 \(expected[k])，实际声道 \(loudest) 标签 \(d.labels[loudest])，能量 \(e)")
        }
    }

    @Test("TrueHD 经 FFmpeg 解码") func trueHD() throws {
        // FFmpeg 的 TrueHD 编码器最多支持 5.1
        try expectChannelOrder("hdr10-hevc-truehd51.mkv", channels: 6, route: .ffmpeg, lfeIndex: nil)
    }

    @Test("DTS 5.1 经 FFmpeg 解码") func dts51() throws {
        try expectChannelOrder("sdr-hevc-dts51.mkv", channels: 6, route: .ffmpeg)
    }

    @Test("FLAC 7.1 经 AudioToolbox 解码") func flac71() throws {
        try expectChannelOrder("sdr-hevc-flac71.mkv", channels: 8, route: .audioToolbox, lfeIndex: nil)
    }

    @Test("ALAC 立体声经 AudioToolbox 解码") func alacStereo() throws {
        try expectChannelOrder("sdr-hevc-alac20.mkv", channels: 2, route: .audioToolbox, lfeIndex: nil)
    }

    @Test("AAC 5.1 经 AudioToolbox 解码") func aac51() throws {
        try expectChannelOrder("sdr-h264-aac51.mp4", channels: 6, route: .audioToolbox)
    }

    @Test("多声道 Opus 经 FFmpeg 解码") func opusMultichannel() throws {
        try expectChannelOrder("sdr-hevc-opus51.mkv", channels: 6, route: .ffmpeg)
    }

    @Test("立体声 Opus 经 AudioToolbox 解码") func opusStereo() throws {
        try expectChannelOrder("sdr-hevc-opus20.mkv", channels: 2, route: .audioToolbox, lfeIndex: nil)
    }

    @Test("AC3 压缩码流直通") func ac3Passthrough() throws {
        let (decoder, d) = try decode("sdr-h264-ac351.mkv", seconds: 0)
        #expect(decoder.route == .system)
        #expect(d.channels == 6)
    }

    @Test("7.1 声道标签映射") func channelLabels71() {
        // FFmpeg 7.1 原生顺序：FL FR FC LFE BL BR SL SR
        var layout = AVChannelLayout()
        av_channel_layout_from_string(&layout, "7.1")
        var data = ChannelLayout.coreAudio(layout)
        let labels = data.withUnsafeMutableBytes { raw in
            let acl = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            let n = Int(acl.pointee.mNumberChannelDescriptions)
            return UnsafeBufferPointer(start: ChannelLayout.descriptionsPointer(acl), count: n).map(\.mChannelLabel)
        }
        #expect(labels == [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ])
        av_channel_layout_uninit(&layout)
    }
}
