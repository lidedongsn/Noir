import AVFoundation
import NoirEngine
import SwiftUI

/// 承载视频与字幕图层的视图，解码、色彩管理与 HDR/EDR 输出均由系统完成。
struct VideoSurface: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer?
    let subtitleLayer: SubtitleLayer?

    func makeNSView(context: Context) -> SurfaceView {
        SurfaceView()
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.displayLayer = displayLayer
        view.subtitleLayer = subtitleLayer
    }

    final class SurfaceView: NSView {
        var displayLayer: AVSampleBufferDisplayLayer? {
            didSet {
                guard displayLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let displayLayer {
                    // 启用 EDR，HDR 片源在支持的显示器上以高动态范围输出
                    displayLayer.wantsExtendedDynamicRangeContent = true
                    layer?.insertSublayer(displayLayer, at: 0)
                    needsLayout = true
                }
            }
        }

        var subtitleLayer: SubtitleLayer? {
            didSet {
                guard subtitleLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let subtitleLayer {
                    subtitleLayer.contentsScale = window?.backingScaleFactor ?? 2
                    layer?.addSublayer(subtitleLayer)
                    needsLayout = true
                }
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = .black
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            subtitleLayer?.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func layout() {
            super.layout()
            // 禁用尺寸变化的隐式动画
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer?.frame = bounds
            subtitleLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
