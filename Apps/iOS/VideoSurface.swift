import AVFoundation
import NoirEngine
import SwiftUI

/// 承载视频与字幕图层的视图，解码、色彩管理与 HDR/EDR 输出均由系统完成。
struct VideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer?
    let subtitleLayer: SubtitleLayer?
    /// 画面填满屏幕（裁切）而非完整显示
    let fills: Bool
    /// 画面显示尺寸，用于旋转时计算画面缩放
    let videoSize: CGSize?

    func makeUIView(context: Context) -> SurfaceView {
        SurfaceView()
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        view.displayLayer = displayLayer
        view.subtitleLayer = subtitleLayer
        view.fills = fills
        view.videoSize = videoSize
    }

    final class SurfaceView: UIView {
        var displayLayer: AVSampleBufferDisplayLayer? {
            didSet {
                guard displayLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let displayLayer {
                    // 启用 EDR，HDR 片源以高动态范围输出
                    displayLayer.wantsExtendedDynamicRangeContent = true
                    displayLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
                    layer.insertSublayer(displayLayer, at: 0)
                    setNeedsLayout()
                }
            }
        }

        var subtitleLayer: SubtitleLayer? {
            didSet {
                guard subtitleLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let subtitleLayer {
                    subtitleLayer.contentsScale = traitCollection.displayScale
                    layer.addSublayer(subtitleLayer)
                    setNeedsLayout()
                }
            }
        }

        var fills = false {
            didSet {
                guard fills != oldValue else { return }
                // 切换时保留系统的过渡动画
                displayLayer?.videoGravity = fills ? .resizeAspectFill : .resizeAspect
            }
        }

        var videoSize: CGSize?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let old = displayLayer?.bounds.size ?? .zero
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer?.frame = bounds
            subtitleLayer?.frame = bounds
            CATransaction.commit()
            // 旋转时视图尺寸随系统动画变化，而 AVSampleBufferDisplayLayer 内部的画面会直接跳到最终尺寸、
            // 不跟随图层尺寸动画（动画中途画面溢出黑边）。因此图层直接设为最终尺寸，
            // 再以缩放与位移动画从旧画面过渡到新画面，时长与曲线沿用系统动画
            if let system = layer.animation(forKey: "bounds.size"), old != .zero, old != bounds.size {
                for sublayer in [displayLayer, subtitleLayer].compactMap({ $0 }) {
                    animate(sublayer, from: old, like: system)
                }
            }
        }

        private func animate(_ sublayer: CALayer, from old: CGSize, like system: CAAnimation) {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = contentScale(old) / contentScale(bounds.size)
            scale.toValue = 1
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = CGPoint(x: old.width / 2, y: old.height / 2)
            position.toValue = CGPoint(x: bounds.midX, y: bounds.midY)
            let group = CAAnimationGroup()
            group.animations = [scale, position]
            group.duration = system.duration
            group.timingFunction = system.timingFunction
            group.beginTime = system.beginTime
            group.fillMode = .backwards
            sublayer.add(group, forKey: "rotation")
        }

        /// 画面在给定区域内显示时的缩放比例（完整显示或填满）
        private func contentScale(_ size: CGSize) -> CGFloat {
            guard let video = videoSize, video.width > 0, video.height > 0 else { return size.width }
            let x = size.width / video.width, y = size.height / video.height
            return fills ? max(x, y) : min(x, y)
        }
    }
}
