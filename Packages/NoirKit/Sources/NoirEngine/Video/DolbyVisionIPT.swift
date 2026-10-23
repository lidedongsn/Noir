import CoreVideo
import Foundation
import VideoToolbox

/// 杜比视界 Profile 5 画面（IPTPQc2）转为 BT.2020 PQ RGB，供截图使用。
///
/// Profile 5 没有 HDR10 兼容层，解码输出是 IPT 色彩，只有系统的显示合成器能按 RPU 正确显示；
/// CoreImage 与 VTPixelTransfer 都会把它当作 YCbCr，截出的封面偏绿偏紫。
/// 此处按杜比视界默认的 IPT→LMS→RGB 矩阵换算，未应用 RPU 中的逐帧重塑曲线，颜色为近似值。
enum DolbyVisionIPT {
    /// 是否为需要换算的 IPT 画面：带 RPU 且没有 YCbCr 矩阵
    static func isIPT(_ buffer: CVImageBuffer) -> Bool {
        CVBufferCopyAttachment(buffer, "DolbyVisionRPUData" as CFString, nil) != nil
            && CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil
    }

    // IPTPQc2 → LMS（PQ 域）
    private static let ipt2lms: [[Float]] = [
        [1.0, 0.0975689, 0.205226],
        [1.0, -0.1138760, 0.133217],
        [1.0, 0.0326151, -0.676887],
    ]
    // LMS（线性）→ BT.2020 RGB（线性），含杜比视界 2% 串扰
    private static let lms2rgb: [[Float]] = [
        [3.06441879, -2.16597676, 0.10155818],
        [-0.65612108, 1.78554118, -0.12943749],
        [0.01736321, -0.04725154, 1.03004253],
    ]

    /// 缩放到 width×height 并换算，输出带 BT.2020 / PQ 标注的半精度 RGBA 画面
    static func convert(_ buffer: CVImageBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard let source = scaledYCbCr(buffer, width: width, height: height),
              let output = makeBuffer(kCVPixelFormatType_64RGBAHalf, width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let out = CVPixelBufferGetBaseAddress(output) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let outStride = CVPixelBufferGetBytesPerRow(output)

        for y in 0..<height {
            let lumaRow = (luma + y * lumaStride).assumingMemoryBound(to: UInt16.self)
            let chromaRow = (chroma + (y / 2) * chromaStride).assumingMemoryBound(to: UInt16.self)
            let outRow = (out + y * outStride).assumingMemoryBound(to: Float16.self)
            for x in 0..<width {
                // 10 位数据存放在 16 位字的高位，全范围
                let i = Float(lumaRow[x] >> 6) / 1023
                let p = Float(chromaRow[x / 2 * 2] >> 6) / 1023 - 0.5
                let t = Float(chromaRow[x / 2 * 2 + 1] >> 6) / 1023 - 0.5
                var lms = [Float](repeating: 0, count: 3)
                for c in 0..<3 {
                    lms[c] = pqToLinear(ipt2lms[c][0] * i + ipt2lms[c][1] * p + ipt2lms[c][2] * t)
                }
                for c in 0..<3 {
                    let linear = lms2rgb[c][0] * lms[0] + lms2rgb[c][1] * lms[1] + lms2rgb[c][2] * lms[2]
                    outRow[x * 4 + c] = Float16(linearToPQ(max(linear, 0)))
                }
                outRow[x * 4 + 3] = 1
            }
        }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        return output
    }

    /// 用 VTPixelTransfer 缩放并转为可由 CPU 读取的 10 位全范围双平面格式（解码输出可能是压缩格式）
    private static func scaledYCbCr(_ buffer: CVImageBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session,
              let output = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, width: width, height: height)
        else { return nil }
        defer { VTPixelTransferSessionInvalidate(session) }
        // 目标沿用源画面的色彩标注，只缩放不做色彩转换
        CVBufferPropagateAttachments(buffer, output)
        return VTPixelTransferSessionTransferImage(session, from: buffer, to: output) == noErr ? output : nil
    }

    private static func makeBuffer(_ format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer
    }

    // SMPTE ST 2084
    private static let m1: Float = 2610 / 16384, m2: Float = 2523 / 4096 * 128
    private static let c1: Float = 3424 / 4096, c2: Float = 2413 / 4096 * 32, c3: Float = 2392 / 4096 * 32

    private static func pqToLinear(_ v: Float) -> Float {
        let p = powf(max(v, 0), 1 / m2)
        return powf(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    private static func linearToPQ(_ v: Float) -> Float {
        let p = powf(v, m1)
        return powf((c1 + c2 * p) / (1 + c3 * p), m2)
    }
}
