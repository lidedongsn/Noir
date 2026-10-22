import CFFmpeg
import CoreMedia

enum SampleBufferError: Error, CustomStringConvertible {
    case coreMedia(String, OSStatus)

    var description: String {
        switch self {
        case .coreMedia(let what, let status): "\(what) 失败（\(status)）"
        }
    }
}

private func ensure(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw SampleBufferError.coreMedia(what, status) }
}

enum SampleBuffers {
    /// 零拷贝：CMBlockBuffer 直接引用 AVPacket 的内存，样本释放时才释放 Packet
    static func blockBuffer(referencing packet: Packet) throws -> CMBlockBuffer {
        let retained = Unmanaged.passRetained(packet)
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                Unmanaged<Packet>.fromOpaque(refCon!).release()
            },
            refCon: retained.toOpaque()
        )
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: packet.data,
            blockLength: packet.size,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: packet.size,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            retained.release()
            throw SampleBufferError.coreMedia("创建 CMBlockBuffer", status)
        }
        return block
    }

    /// 复制数据到新分配的 CMBlockBuffer（用于解码后的音频）
    static func blockBuffer(copying bytes: UnsafeRawBufferPointer) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        try ensure(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ), "分配 CMBlockBuffer")
        try ensure(CMBlockBufferReplaceDataBytes(
            with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count
        ), "写入 CMBlockBuffer")
        return block!
    }

    /// 构造压缩视频帧样本
    static func video(
        packet: Packet,
        format: CMVideoFormatDescription,
        timeBase: AVRational
    ) throws -> CMSampleBuffer {
        let block = try blockBuffer(referencing: packet)
        var timing = CMSampleTimingInfo(
            duration: packet.duration > 0 ? timeBase.time(packet.duration) : .invalid,
            presentationTimeStamp: timeBase.time(packet.pts),
            decodeTimeStamp: timeBase.time(packet.dts)
        )
        var size = packet.size
        var sample: CMSampleBuffer?
        try ensure(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ), "创建视频样本")

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)!
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        if !packet.isKeyframe {
            dict.set(kCMSampleAttachmentKey_NotSync, kCFBooleanTrue)
        }
        return sample!
    }

    /// 音频样本：LPCM 时 packetSizes 为空，压缩格式时每包一个描述
    static func audio(
        block: CMBlockBuffer,
        format: CMAudioFormatDescription,
        frameCount: Int,
        packetSizes: [Int] = [],
        pts: CMTime
    ) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        if packetSizes.isEmpty {
            try ensure(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: frameCount, presentationTimeStamp: pts, packetDescriptions: nil,
                sampleBufferOut: &sample
            ), "创建 LPCM 样本")
        } else {
            var offset: Int64 = 0
            let descriptions = packetSizes.map { size in
                defer { offset += Int64(size) }
                return AudioStreamPacketDescription(
                    mStartOffset: offset, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size)
                )
            }
            try ensure(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: packetSizes.count, presentationTimeStamp: pts,
                packetDescriptions: descriptions, sampleBufferOut: &sample
            ), "创建压缩音频样本")
        }
        return sample!
    }
}

extension CFMutableDictionary {
    func set(_ key: CFString, _ value: CFBoolean) {
        CFDictionarySetValue(
            self,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }
}
