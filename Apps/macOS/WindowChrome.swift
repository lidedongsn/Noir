import AppKit
import SwiftUI

extension View {
    /// 控制窗口标准按钮（关闭 / 最小化 / 全屏）的显示，与播放控件同步淡入淡出。
    func windowButtonsHidden(_ hidden: Bool) -> some View {
        background(WindowButtonsVisibility(hidden: hidden))
    }
}

private struct WindowButtonsVisibility: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.buttonsHidden = hidden
    }

    final class Probe: NSView {
        var buttonsHidden = false {
            didSet { if buttonsHidden != oldValue { apply(animated: true) } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply(animated: false)
        }

        private func apply(animated: Bool) {
            // 标准按钮位于同一标题栏容器视图中，统一设置透明度
            guard let titlebar = window?.standardWindowButton(.closeButton)?.superview else { return }
            let alpha: CGFloat = buttonsHidden ? 0 : 1
            guard animated else {
                titlebar.alphaValue = alpha
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                titlebar.animator().alphaValue = alpha
            }
        }
    }
}
