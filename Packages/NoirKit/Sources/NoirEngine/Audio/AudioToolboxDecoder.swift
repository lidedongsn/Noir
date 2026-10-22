import AudioToolbox
import CFFmpeg
import CoreMedia

/// 基于 AudioToolbox 的解码器（AAC / FLAC / ALAC / Opus / MP3），输出交错 Float32 LPCM。
final class AudioToolboxDecoder: AudioDecoder {
    let route = AudioRoute.audioToolbox
    let outputChannels: Int
    private var converter: AudioConverterRef?
    private let format: CMAudioFormatDescription
    private let timeBase: AVRational
    private let sampleRate: Double

    // 输入回调状态：待送入的数据包及其包描述（须在回调返回后保持有效）
    private var pending: Packet?
    private var inFlight: Packet?
    private let packetDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    // 输出缓冲按单包最大帧数分配（FLAC 块最大 65535 帧）
    private static let capacityFrames = 65_536
    private let output: UnsafeMutableRawBufferPointer

    /// 输入回调的自定义返回码，表示当前数据包已消费完毕
    private static let noMoreData: OSStatus = 0x6E6F_6D6F // 'nomo'

    init(par: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        let p = par.pointee
        var input = AudioStreamBasicDescription()
        input.mFormatID = try Self.formatID(p.codec_id)
        input.mSampleRate = Double(p.sample_rate)
        input.mChannelsPerFrame = UInt32(p.ch_layout.nb_channels)
        let cookie = MagicCookie.make(codec: p.codec_id, extradata: par.extradata)

        if let cookie {
            // 由系统根据 cookie 补全 ASBD（每包帧数、HE-AAC 实际采样率等）
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = cookie.withUnsafeBytes {
                AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32($0.count), $0.baseAddress, &size, &input)
            }
            guard status == noErr else { throw AudioDecoderError.audioToolbox("解析 \(codecName(p.codec_id)) 配置", status) }
        } else {
            input.mFramesPerPacket = switch p.codec_id {
            case AV_CODEC_ID_OPUS: 960
            case AV_CODEC_ID_MP3: 1152
            default: UInt32(max(p.frame_size, 0))
            }
        }

        let channels = Int(input.mChannelsPerFrame)
        var outputASBD = ChannelLayout.float32(sampleRate: input.mSampleRate, channels: channels)
        var created: AudioConverterRef?
        var status = AudioConverterNew(&input, &outputASBD, &created)
        guard status == noErr, let created else {
            throw AudioDecoderError.audioToolbox("创建 \(codecName(p.codec_id)) 解码器", status)
        }
        do {
            if let cookie {
                status = cookie.withUnsafeBytes {
                    AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
                }
                guard status == noErr else { throw AudioDecoderError.audioToolbox("设置解码配置", status) }
            }
            format = try ChannelLayout.formatDescription(
                outputASBD,
                layout: nil,
                layoutData: Self.configureOutputLayout(created, ffmpegLayout: p.ch_layout)
            )
        } catch {
            AudioConverterDispose(created)
            throw error
        }
        converter = created
        outputChannels = channels
        sampleRate = input.mSampleRate
        self.timeBase = timeBase
        output = .allocate(byteCount: Self.capacityFrames * channels * 4, alignment: 16)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        packetDescription.deallocate()
        output.deallocate()
    }

    /// 系统解码器按各编码格式的原生声道顺序输出（如 AAC 为 C L R …）。
    /// 优先由转换器重排为 FFmpeg 布局，与其他路径保持一致；不支持时使用解码器实际输出的布局。
    private static func configureOutputLayout(_ converter: AudioConverterRef, ffmpegLayout: AVChannelLayout) -> Data? {
        var wanted = ChannelLayout.coreAudio(ffmpegLayout)
        let status = wanted.withUnsafeMutableBytes {
            AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, UInt32($0.count), $0.baseAddress!)
        }
        if status == noErr { return wanted }

        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &size, nil) == noErr, size > 0 else {
            return nil
        }
        var actual = Data(count: Int(size))
        let got = actual.withUnsafeMutableBytes {
            AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &size, $0.baseAddress!)
        }
        return got == noErr ? actual : nil
    }

    private static func formatID(_ id: AVCodecID) throws -> AudioFormatID {
        switch id {
        case AV_CODEC_ID_AAC: kAudioFormatMPEG4AAC
        case AV_CODEC_ID_ALAC: kAudioFormatAppleLossless
        case AV_CODEC_ID_FLAC: kAudioFormatFLAC
        case AV_CODEC_ID_OPUS: kAudioFormatOpus
        case AV_CODEC_ID_MP3: kAudioFormatMPEGLayer3
        default: throw AudioDecoderError.unsupported(codecName(id))
        }
    }

    func decode(_ packet: Packet) throws -> [CMSampleBuffer] {
        pending = packet
        let basePTS = timeBase.time(packet.pts)
        var samples: [CMSampleBuffer] = []
        var decodedFrames: Int64 = 0
        let opaque = Unmanaged.passUnretained(self).toOpaque()

        while true {
            var frames = UInt32(Self.capacityFrames)
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outputChannels),
                    mDataByteSize: UInt32(output.count),
                    mData: output.baseAddress
                )
            )
            let status = AudioConverterFillComplexBuffer(converter!, Self.inputProc, opaque, &frames, &buffers, nil)
            if frames > 0 {
                let bytes = UnsafeRawBufferPointer(rebasing: output[0..<Int(buffers.mBuffers.mDataByteSize)])
                let pts = basePTS + CMTime(value: decodedFrames, timescale: CMTimeScale(sampleRate))
                samples.append(try SampleBuffers.audio(
                    block: try SampleBuffers.blockBuffer(copying: bytes),
                    format: format, frameCount: Int(frames), pts: pts
                ))
                decodedFrames += Int64(frames)
            }
            if status == Self.noMoreData || frames == 0 { break }
            guard status == noErr else { throw AudioDecoderError.audioToolbox("音频解码", status) }
        }
        inFlight = nil
        return samples
    }

    func flush() {
        if let converter { AudioConverterReset(converter) }
        pending = nil
        inFlight = nil
    }

    private static let inputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDescription, userData in
        let decoder = Unmanaged<AudioToolboxDecoder>.fromOpaque(userData!).takeUnretainedValue()
        guard let packet = decoder.pending else {
            ioPackets.pointee = 0
            return AudioToolboxDecoder.noMoreData
        }
        decoder.pending = nil
        decoder.inFlight = packet // 转换器读取完成前保持数据有效

        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = packet.data
        ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.size)
        ioData.pointee.mBuffers.mNumberChannels = UInt32(decoder.outputChannels)
        decoder.packetDescription.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.size)
        )
        outDescription?.pointee = decoder.packetDescription
        ioPackets.pointee = 1
        return noErr
    }
}

/// 将容器中的解码配置转换为 AudioToolbox 所需的 magic cookie。
enum MagicCookie {
    static func make(codec: AVCodecID, extradata: Data?) -> Data? {
        guard let extradata, !extradata.isEmpty else { return nil }
        switch codec {
        case AV_CODEC_ID_AAC:
            return esds(audioSpecificConfig: extradata)
        case AV_CODEC_ID_FLAC:
            return dfLa(extradata)
        case AV_CODEC_ID_OPUS:
            // 系统 Opus 解码器仅支持单声道 / 立体声，且不接受 OpusHead 形式的 cookie
            return nil
        default:
            return extradata
        }
    }

    /// FLAC 的 cookie 是完整的 MP4 'dfLa' box：box 头 + version/flags + STREAMINFO 元数据块
    static func dfLa(_ extradata: Data) -> Data {
        // extradata 可能是裸 STREAMINFO，也可能是 "fLaC" + 元数据块（STREAMINFO 恒为首块，跳过 4 字节块头）
        let start = extradata.startIndex
        let streamInfo = extradata.starts(with: Data("fLaC".utf8)) && extradata.count >= 42
            ? extradata[(start + 8)..<(start + 42)]
            : extradata.prefix(34)
        var payload = Data([0, 0, 0, 0])            // version + flags
        payload += [0x80, 0, 0, 34]                 // 最后一个块、类型 STREAMINFO、长度 34
        payload += streamInfo
        var box = Data()
        box.appendBigEndian(UInt32(8 + payload.count))
        box += Data("dfLa".utf8)
        box += payload
        return box
    }

    /// AAC 的 cookie 是 MPEG-4 ES_Descriptor，AudioSpecificConfig 包在 DecoderSpecificInfo 里
    static func esds(audioSpecificConfig asc: Data) -> Data {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            var d = Data([tag])
            // 长度统一使用 4 字节可变长编码
            let n = body.count
            d.append(contentsOf: [0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F),
                                  0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
            d.append(body)
            return d
        }
        let decoderSpecific = descriptor(0x05, asc)
        // objectTypeIndication=0x40（MPEG-4 Audio），streamType=0x15（音频），缓冲与码率填 0
        let decoderConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + decoderSpecific)
        let slConfig = descriptor(0x06, Data([0x02]))
        return descriptor(0x03, Data([0, 0, 0]) + decoderConfig + slConfig)
    }
}
