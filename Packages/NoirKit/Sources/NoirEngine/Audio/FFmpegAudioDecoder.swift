import AudioToolbox
import CFFmpeg
import CoreMedia

/// FFmpeg 软件解码器，用于系统不支持的格式（TrueHD、DTS 系列、多声道 Opus），输出多声道 LPCM。
final class FFmpegAudioDecoder: AudioDecoder {
    let route = AudioRoute.ffmpeg
    private(set) var outputChannels: Int
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let frame = av_frame_alloc()!
    private let timeBase: AVRational
    private var format: CMAudioFormatDescription?
    private var formatKey: (rate: Int32, channels: Int32) = (0, 0)
    private var scratch: [Float] = []
    private var timeline = AudioTimeline()

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        let par = stream.pointee.codecpar!
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else {
            throw AudioDecoderError.unsupported(codecName(par.pointee.codec_id))
        }
        context = avcodec_alloc_context3(codec)
        try check(avcodec_parameters_to_context(context, par), "复制解码参数")
        context!.pointee.pkt_timebase = stream.pointee.time_base
        try check(avcodec_open2(context, codec, nil), "打开 \(codecName(par.pointee.codec_id)) 解码器")
        timeBase = stream.pointee.time_base
        outputChannels = Int(par.pointee.ch_layout.nb_channels)
    }

    deinit {
        avcodec_free_context(&context)
        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
    }

    func decode(_ packet: Packet) throws -> [CMSampleBuffer] {
        try check(avcodec_send_packet(context, packet.raw), "送入音频包")
        var samples: [CMSampleBuffer] = []
        while true {
            let ret = avcodec_receive_frame(context, frame)
            if ret == AVConst.errorAgain || ret == AVConst.errorEOF { break }
            try check(ret, "音频解码")
            defer { av_frame_unref(frame) }
            samples.append(try makeSample())
        }
        return samples
    }

    func flush() {
        avcodec_flush_buffers(context)
        timeline.reset()
    }

    private func makeSample() throws -> CMSampleBuffer {
        let f = frame.pointee
        let channels = Int(f.ch_layout.nb_channels)
        if format == nil || formatKey != (f.sample_rate, f.ch_layout.nb_channels) {
            format = try ChannelLayout.formatDescription(
                ChannelLayout.float32(sampleRate: Double(f.sample_rate), channels: channels),
                layout: f.ch_layout
            )
            formatKey = (f.sample_rate, f.ch_layout.nb_channels)
            outputChannels = channels
        }
        SampleConverter.interleavedFloat32(
            format: AVSampleFormat(f.format), channels: channels, frames: Int(f.nb_samples),
            planes: f.extended_data, into: &scratch
        )
        let block = try scratch.withUnsafeBytes { try SampleBuffers.blockBuffer(copying: $0) }
        let ts = f.best_effort_timestamp != AVConst.noPTS ? f.best_effort_timestamp : f.pts
        return try SampleBuffers.audio(
            block: block, format: format!, frameCount: Int(f.nb_samples),
            pts: timeline.place(timeBase.time(ts), frames: Int(f.nb_samples), sampleRate: Double(f.sample_rate))
        )
    }
}
