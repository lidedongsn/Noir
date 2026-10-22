import AVFoundation
import QuartzCore

/// 字幕图层，覆盖在视频图层之上，字幕区域跟随画面而非窗口。
///
/// 底部字幕单独绘制在 anchored 子图层中：控制条出现时（bottomInset > 0）只平移这一层，
/// 位置以动画过渡，避免被控制条遮挡；顶部与定位字幕保持不动。
/// 仅在主线程访问。
public final class SubtitleLayer: CALayer, @unchecked Sendable {
    /// 视频的显示尺寸，用于计算画面区域
    public var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { redraw() } }
    }

    /// 底部被界面遮挡的高度
    public var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { updateShift() } }
    }

    override public var contentsScale: CGFloat {
        didSet {
            anchored.contentsScale = contentsScale
            free.contentsScale = contentsScale
        }
    }

    var track: SubtitleTrack? {
        didSet {
            if track !== oldValue {
                activeKeys = nil
                update(time: time)
            }
        }
    }

    private let anchored = Canvas()
    private let free = Canvas()
    private let renderer = SubtitleRenderer()
    private var time = 0.0
    private var activeKeys: [Int64]?
    private var animated = false
    private var anchoredBottom: CGFloat?

    override public init() {
        super.init()
        for canvas in [free, anchored] {
            canvas.renderer = renderer
            addSublayer(canvas)
        }
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override public func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 不能设置 frame：anchored 带平移变换时，设置 frame 会抵消平移
        for canvas in [anchored, free] {
            canvas.bounds = bounds
            canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CATransaction.commit()
        redraw()
    }

    /// 按播放时间刷新；显示内容不变时不重绘
    func update(time: Double) {
        self.time = time
        let cues = track?.active(at: time) ?? []
        let keys = cues.map(\.key)
        guard keys != activeKeys || animated else { return }
        activeKeys = keys
        redraw(cues)
    }

    private func redraw() {
        redraw(track?.active(at: time) ?? [])
    }

    private func redraw(_ cues: [SubtitleCue]) {
        let video = videoSize.width > 0 && videoSize.height > 0
            ? AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
            : bounds
        let layout = track.map {
            renderer.layout(cues: cues, script: $0.script, time: time, video: video)
        } ?? SubtitleRenderer.Layout()
        animated = layout.animated
        anchoredBottom = layout.anchoredBottom
        anchored.items = layout.anchored
        free.items = layout.free
        updateShift()
    }

    private func updateShift() {
        // 仅在字幕下边缘进入遮挡区域时上移
        let overlap = anchoredBottom.map { $0 - (bounds.height - bottomInset) } ?? 0
        let shift = bottomInset > 0 ? max(overlap, 0) : 0
        #if os(macOS)
        let transform = CATransform3DMakeTranslation(0, shift, 0)
        #else
        let transform = CATransform3DMakeTranslation(0, -shift, 0)
        #endif
        guard !CATransform3DEqualToTransform(anchored.transform, transform) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        anchored.transform = transform
        CATransaction.commit()
    }

    /// 绘制一组排版结果的子图层
    private final class Canvas: CALayer, @unchecked Sendable {
        var renderer: SubtitleRenderer?
        var items: [SubtitleRenderer.Item] = [] {
            didSet { setNeedsDisplay() }
        }

        override init() {
            super.init()
            needsDisplayOnBoundsChange = true
            // 内容与尺寸变化不做隐式动画，只保留平移动画
            actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draw(in context: CGContext) {
            guard let renderer, !items.isEmpty else { return }
            #if os(macOS)
            // macOS 图层坐标原点在左下角，翻转为排版使用的左上角原点
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            #endif
            renderer.draw(items, in: context)
        }
    }
}
