import AppKit
import SwiftUI

extension View {
    /// 按视频显示宽高比锁定窗口缩放比例；传入 nil 解除锁定。
    func windowAspectRatio(_ size: CGSize?) -> some View {
        background(WindowAspectLock(size: size))
    }
}

private struct WindowAspectLock: NSViewRepresentable {
    let size: CGSize?

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.size = size
    }

    /// 用于获取宿主 NSWindow 的辅助视图
    final class Probe: NSView {
        private var applied: CGSize?? = .none

        var size: CGSize? {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applied = .none
            apply()
        }

        private func apply() {
            guard let window, applied != .some(size) else { return }
            applied = .some(size)

            guard let size, size.width > 0, size.height > 0 else {
                // 恢复默认缩放增量以解除比例锁定
                window.resizeIncrements = NSSize(width: 1, height: 1)
                return
            }
            // 内容视图铺满整个窗口（标题栏透明），因此锁定窗口外框比例；
            // contentAspectRatio 会扣除标题栏高度，不适用于此场景
            window.aspectRatio = size
            // 全屏状态下尺寸由系统决定，比例锁定在退出全屏后生效
            guard !window.styleMask.contains(.fullScreen) else { return }
            window.setFrame(fittedFrame(for: window, aspect: size), display: true, animate: true)
        }

        /// 计算符合目标比例的窗口尺寸：保持中心点与面积，并限制在屏幕可用区域内。
        private func fittedFrame(for window: NSWindow, aspect: CGSize) -> NSRect {
            let current = window.frame
            let ratio = aspect.width / aspect.height
            let area = current.width * current.height
            var size = NSSize(width: (area * ratio).squareRoot(), height: (area / ratio).squareRoot())

            if let visible = window.screen?.visibleFrame {
                let scale = min(1, visible.width / size.width, visible.height / size.height)
                size = NSSize(width: size.width * scale, height: size.height * scale)
            }
            size.width = max(size.width, window.minSize.width)
            size.height = size.width / ratio

            var frame = NSRect(origin: .zero, size: size)
            frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
            if let visible = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            return frame
        }
    }
}
