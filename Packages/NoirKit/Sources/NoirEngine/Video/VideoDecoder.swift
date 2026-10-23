import CFFmpeg
import CoreMedia
import Synchronization
import VideoToolbox

/// VideoToolbox 硬件解码，输出按显示时间排序的已解码画面。
///
/// 不直接把压缩帧交给 AVSampleBufferVideoRenderer：渲染器内部解码的提前量有限，
/// 遇到 B 帧多、重排序深的 H.264（常见于网络视频编码器）时，帧解码完成已晚于显示时间而被丢弃，
/// 表现为规律性卡顿。自行解码后提前量由播放会话控制，渲染器只负责按时显示。
/// 非线程安全，仅在播放队列上调用；解码回调在 VideoToolbox 线程，结果经锁传递。
final class VideoDecoder {
    struct Frame: @unchecked Sendable {
        var image: CVImageBuffer
        var pts: CMTime
        var duration: CMTime
    }

    private let session: VTDecompressionSession
    /// 解码回调写入、播放队列读取
    private final class Inbox: Sendable {
        let frames = Mutex<[Frame]>([])
    }
    private let decoded = Inbox()
    /// 已解码、尚未按序取出的画面（按 PTS 排序）
    private var pending: [Frame] = []
    private var outputFormat: CMVideoFormatDescription?
    /// VideoToolbox 按解码顺序输出，需按 PTS 重排后再显示：
    /// 暂存帧数超过码流的重排序深度时，最早的一帧不会再被后续帧超前，即可输出（与解码器 DPB 的输出规则一致）。
    /// 不依赖 DTS，因为 MKV 不存储 DTS。
    let reorderDepth: Int
    /// HDR 静态元数据：VideoToolbox 输出的画面不携带，需从格式描述复制，供系统做色调映射
    private let hdrAttachments: [(CFString, CFTypeRef)]

    init(format: CMVideoFormatDescription, reorderDepth: Int) throws {
        self.reorderDepth = reorderDepth
        hdrAttachments = [
            (kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCVImageBufferMasteringDisplayColorVolumeKey),
            (kCMFormatDescriptionExtension_ContentLightLevelInfo, kCVImageBufferContentLightLevelInfoKey),
        ].compactMap { ext, key in
            CMFormatDescriptionGetExtension(format, extensionKey: ext).map { (key, $0) }
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw SampleBufferError.coreMedia("创建视频解码会话", status)
        }
        self.session = session
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    /// 作废解码会话，之后的解码返回 kVTInvalidSessionErr（测试中模拟 iOS 进入后台）
    func invalidate() {
        VTDecompressionSessionInvalidate(session)
    }

    /// 解码一帧；结果在 nextFrame 中按显示顺序取出
    func decode(_ sample: CMSampleBuffer) throws {
        let duration = CMSampleBufferGetDuration(sample)
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableTemporalProcessing], infoFlagsOut: nil
        ) { [decoded] status, _, image, pts, _ in
            guard status == noErr, let image, pts.isValid else { return }
            decoded.frames.withLock { $0.append(Frame(image: image, pts: pts, duration: duration)) }
        }
        guard status == noErr else { throw SampleBufferError.coreMedia("视频解码", status) }
    }

    /// 片源读完时调用，输出解码器内暂存的帧
    func finish() {
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    /// 跳转时清空
    func flush() {
        finish()
        decoded.frames.withLock { $0.removeAll() }
        pending.removeAll()
    }

    /// 取出下一帧（按显示顺序）。draining 为 true 时不再等待重排序。
    func nextFrame(draining: Bool) -> Frame? {
        absorb()
        guard !pending.isEmpty, draining || pending.count > reorderDepth else { return nil }
        return pending.removeFirst()
    }

    /// 已解码、尚未取出的帧数
    func bufferedCount() -> Int {
        absorb()
        return pending.count
    }

    /// 已解码画面的最晚显示时间
    var bufferedUntil: CMTime? { pending.last?.pts }

    private func absorb() {
        let incoming = decoded.frames.withLock { frames in
            defer { frames.removeAll(keepingCapacity: true) }
            return frames
        }
        for frame in incoming {
            for (key, value) in hdrAttachments {
                CVBufferSetAttachment(frame.image, key, value, .shouldPropagate)
            }
            pending.insert(frame, at: pending.partitionIndex { $0.pts > frame.pts })
        }
    }

    /// 已解码画面封装为样本，交给渲染器显示
    func sampleBuffer(for frame: Frame) throws -> CMSampleBuffer {
        if outputFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(outputFormat!, imageBuffer: frame.image) {
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: frame.image, formatDescriptionOut: &format
            )
            guard status == noErr, let format else { throw SampleBufferError.coreMedia("创建画面格式描述", status) }
            outputFormat = format
        }
        var timing = CMSampleTimingInfo(duration: frame.duration, presentationTimeStamp: frame.pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame.image, formatDescription: outputFormat!,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw SampleBufferError.coreMedia("创建画面样本", status) }
        return sample
    }
}

extension VideoDecoder {
    /// 码流的重排序深度：HEVC 读取 SPS；其余使用 FFmpeg 从容器得到的值；都没有时取规范上限 16
    static func reorderDepth(_ par: UnsafePointer<AVCodecParameters>) -> Int {
        if par.pointee.codec_id == AV_CODEC_ID_HEVC, let depth = par.extradata.flatMap(ParameterSets.hevcReorderDepth) {
            return depth
        }
        let delay = Int(par.pointee.video_delay)
        return delay > 0 ? delay : 16
    }
}
