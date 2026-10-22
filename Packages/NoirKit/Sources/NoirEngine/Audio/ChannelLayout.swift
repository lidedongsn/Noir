import AudioToolbox
import CFFmpeg
import CoreMedia

/// FFmpeg 声道布局 → CoreAudio 声道布局。
/// 逐声道标注而非套用预设布局，样本无需重排。
enum ChannelLayout {
    /// 返回可直接传给 CMAudioFormatDescriptionCreate 的 AudioChannelLayout 字节
    static func coreAudio(_ layout: AVChannelLayout) -> Data {
        var layout = layout
        if layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&layout, layout.nb_channels)
        }
        let count = Int(layout.nb_channels)
        let channels = (0..<count).map { av_channel_layout_channel_from_index(&layout, UInt32($0)) }
        let hasSides = channels.contains(AV_CHAN_SIDE_LEFT)

        let size = MemoryLayout<AudioChannelLayout>.size
            + max(0, count - 1) * MemoryLayout<AudioChannelDescription>.stride
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let acl = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            acl.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            acl.pointee.mChannelBitmap = []
            acl.pointee.mNumberChannelDescriptions = UInt32(count)
            let descriptions = descriptionsPointer(acl)
            for (i, channel) in channels.enumerated() {
                descriptions[i] = AudioChannelDescription(
                    mChannelLabel: label(channel, hasSides: hasSides),
                    mChannelFlags: [],
                    mCoordinates: (0, 0, 0)
                )
            }
        }
        return data
    }

    /// AudioChannelLayout 末尾为变长数组，Swift 仅导入首个元素，需按偏移访问。
    static func descriptionsPointer(_ acl: UnsafeMutablePointer<AudioChannelLayout>) -> UnsafeMutablePointer<AudioChannelDescription> {
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        return (UnsafeMutableRawPointer(acl) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
    }

    /// 两套命名对环绕声道的约定不同：FFmpeg 的 side 对应 CoreAudio 的 Ls/Rs，
    /// 7.1 中的 back 对应 Rls/Rrs；仅含 back 的 5.1(back) 布局中，back 映射为 Ls/Rs。
    static func label(_ channel: AVChannel, hasSides: Bool) -> AudioChannelLabel {
        switch channel {
        case AV_CHAN_FRONT_LEFT: kAudioChannelLabel_Left
        case AV_CHAN_FRONT_RIGHT: kAudioChannelLabel_Right
        case AV_CHAN_FRONT_CENTER: kAudioChannelLabel_Center
        case AV_CHAN_LOW_FREQUENCY: kAudioChannelLabel_LFEScreen
        case AV_CHAN_SIDE_LEFT: kAudioChannelLabel_LeftSurround
        case AV_CHAN_SIDE_RIGHT: kAudioChannelLabel_RightSurround
        case AV_CHAN_BACK_LEFT: hasSides ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
        case AV_CHAN_BACK_RIGHT: hasSides ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
        case AV_CHAN_BACK_CENTER: kAudioChannelLabel_CenterSurround
        case AV_CHAN_FRONT_LEFT_OF_CENTER: kAudioChannelLabel_LeftCenter
        case AV_CHAN_FRONT_RIGHT_OF_CENTER: kAudioChannelLabel_RightCenter
        case AV_CHAN_TOP_CENTER: kAudioChannelLabel_TopCenterSurround
        case AV_CHAN_TOP_FRONT_LEFT: kAudioChannelLabel_VerticalHeightLeft
        case AV_CHAN_TOP_FRONT_CENTER: kAudioChannelLabel_VerticalHeightCenter
        case AV_CHAN_TOP_FRONT_RIGHT: kAudioChannelLabel_VerticalHeightRight
        case AV_CHAN_TOP_BACK_LEFT: kAudioChannelLabel_TopBackLeft
        case AV_CHAN_TOP_BACK_CENTER: kAudioChannelLabel_TopBackCenter
        case AV_CHAN_TOP_BACK_RIGHT: kAudioChannelLabel_TopBackRight
        case AV_CHAN_WIDE_LEFT: kAudioChannelLabel_LeftWide
        case AV_CHAN_WIDE_RIGHT: kAudioChannelLabel_RightWide
        case AV_CHAN_SURROUND_DIRECT_LEFT: kAudioChannelLabel_LeftSurroundDirect
        case AV_CHAN_SURROUND_DIRECT_RIGHT: kAudioChannelLabel_RightSurroundDirect
        case AV_CHAN_LOW_FREQUENCY_2: kAudioChannelLabel_LFE2
        case AV_CHAN_STEREO_LEFT: kAudioChannelLabel_LeftTotal
        case AV_CHAN_STEREO_RIGHT: kAudioChannelLabel_RightTotal
        default: kAudioChannelLabel_Unknown
        }
    }

    static func formatDescription(
        _ asbd: AudioStreamBasicDescription,
        layout: AVChannelLayout?,
        layoutData: Data? = nil,
        cookie: Data? = nil
    ) throws -> CMAudioFormatDescription {
        var asbd = asbd
        let layoutData = layoutData ?? layout.map(coreAudio)
        var format: CMAudioFormatDescription?
        let status = layoutData.withOptionalBytes { layoutPtr, layoutSize in
            cookie.withOptionalBytes { cookiePtr, cookieSize in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &asbd,
                    layoutSize: layoutSize,
                    layout: layoutPtr?.assumingMemoryBound(to: AudioChannelLayout.self),
                    magicCookieSize: cookieSize, magicCookie: cookiePtr,
                    extensions: nil, formatDescriptionOut: &format
                )
            }
        }
        guard status == noErr, let format else { throw SampleBufferError.coreMedia("创建音频格式描述", status) }
        return format
    }

    /// 交错 Float32 LPCM
    static func float32(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

extension Optional where Wrapped == Data {
    func withOptionalBytes<R>(_ body: (UnsafeRawPointer?, Int) -> R) -> R {
        switch self {
        case .some(let data): data.withUnsafeBytes { body($0.baseAddress, $0.count) }
        case .none: body(nil, 0)
        }
    }
}
