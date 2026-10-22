import CoreGraphics
import CoreText
import Foundation

/// 字幕排版与绘制（CoreText），坐标均为左上角原点。
final class SubtitleRenderer {
    /// 排版结果
    enum Item {
        case text(TextBlock)
        case bitmap(CGImage, CGRect)
    }

    struct TextBlock {
        struct Line {
            var line: CTLine
            /// 基线起点
            var origin: CGPoint
            var box: CGRect
        }
        var lines: [Line]
        var frame: CGRect
        var opacity: Double
    }

    struct Layout {
        /// 底部字幕，控制条出现时整体上移
        var anchored: [Item] = []
        var free: [Item] = []
        /// 底部字幕的下边缘
        var anchoredBottom: CGFloat?
        /// 是否包含淡入淡出，需要逐帧刷新
        var animated = false
    }

    private var fonts: [FontKey: CTFont] = [:]
    private var baseFonts: [String: (font: CTFont, scale: CGFloat)] = [:]

    /// 自定义文本属性：描边、阴影与底框
    private enum Attribute {
        static let outlineColor = NSAttributedString.Key("noir.outlineColor")
        static let outlineWidth = NSAttributedString.Key("noir.outlineWidth")
        static let shadowColor = NSAttributedString.Key("noir.shadowColor")
        static let shadowOffset = NSAttributedString.Key("noir.shadowOffset")
        static let fillColor = NSAttributedString.Key("noir.fillColor")
        static let boxed = NSAttributedString.Key("noir.boxed")
        static let decoration = NSAttributedString.Key("noir.decoration")
    }

    // MARK: - 排版

    func layout(cues: [SubtitleCue], script: ASSScript, time: Double, video: CGRect) -> Layout {
        var layout = Layout()
        guard video.width > 0, video.height > 0 else { return layout }
        let scaleX = video.width / script.playResX
        let scaleY = video.height / script.playResY
        var placed: [Int: [CGRect]] = [:] // 按行（底、中、顶）记录已占用区域，用于避让

        let ordered = cues.enumerated().sorted { a, b in
            let la = a.element.layer, lb = b.element.layer
            return la != lb ? la < lb : a.offset < b.offset
        }.map(\.element)

        for cue in ordered {
            switch cue.content {
            case .bitmaps(let bitmaps, let canvas):
                guard canvas.width > 0, canvas.height > 0 else { continue }
                let sx = video.width / canvas.width, sy = video.height / canvas.height
                for bitmap in bitmaps {
                    let r = bitmap.rect
                    let rect = CGRect(x: video.minX + r.minX * sx, y: video.minY + r.minY * sy,
                                      width: r.width * sx, height: r.height * sy)
                    if r.midY > canvas.height / 2 {
                        layout.anchored.append(.bitmap(bitmap.image, rect))
                        layout.anchoredBottom = max(layout.anchoredBottom ?? 0, rect.maxY)
                    } else {
                        layout.free.append(.bitmap(bitmap.image, rect))
                    }
                }

            case .text(let dialogue):
                let opacity = fadeOpacity(dialogue, cue: cue, time: time)
                if dialogue.fadeIn > 0 || dialogue.fadeOut > 0 { layout.animated = true }
                guard opacity > 0,
                      var block = textBlock(dialogue, scaleX: scaleX, scaleY: scaleY, video: video, opacity: opacity)
                else { continue }

                let row = (dialogue.alignment - 1) / 3 // 0 底部，1 中部，2 顶部
                if dialogue.position == nil, row != 1 {
                    // 与已有字幕重叠时，底部向上、顶部向下依次排开
                    var moved = true
                    while moved {
                        moved = false
                        for other in placed[row, default: []] where other.intersects(block.frame.insetBy(dx: 0, dy: 0.5)) {
                            let dy = row == 0 ? other.minY - block.frame.maxY : other.maxY - block.frame.minY
                            block = offset(block, dy: dy)
                            moved = true
                        }
                    }
                    placed[row, default: []].append(block.frame)
                }
                if row == 0, dialogue.position == nil {
                    layout.anchored.append(.text(block))
                    layout.anchoredBottom = max(layout.anchoredBottom ?? 0, block.frame.maxY)
                } else {
                    layout.free.append(.text(block))
                }
            }
        }
        return layout
    }

    private func fadeOpacity(_ dialogue: ASSDialogue, cue: SubtitleCue, time: Double) -> Double {
        var opacity = 1.0
        if dialogue.fadeIn > 0 { opacity = min(opacity, (time - cue.start) / dialogue.fadeIn) }
        if dialogue.fadeOut > 0, cue.end.isFinite { opacity = min(opacity, (cue.end - time) / dialogue.fadeOut) }
        return min(max(opacity, 0), 1)
    }

    private func offset(_ block: TextBlock, dy: CGFloat) -> TextBlock {
        var block = block
        block.frame.origin.y += dy
        for i in block.lines.indices {
            block.lines[i].origin.y += dy
            block.lines[i].box.origin.y += dy
        }
        return block
    }

    private func textBlock(_ dialogue: ASSDialogue, scaleX: CGFloat, scaleY: CGFloat, video: CGRect, opacity: Double) -> TextBlock? {
        let string = NSMutableAttributedString()
        for run in dialogue.runs {
            string.append(NSAttributedString(string: run.text, attributes: attributes(run.style, scaleX: scaleX, scaleY: scaleY)))
        }
        guard string.length > 0 else { return nil }

        let marginL = dialogue.marginL * scaleX, marginR = dialogue.marginR * scaleX
        let maxWidth = dialogue.position == nil ? max(video.width - marginL - marginR, 40) : video.width

        // 按硬换行分段，段内按宽度折行
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let nsString = string.string as NSString
        var lines: [(line: CTLine, ascent: CGFloat, descent: CGFloat, width: CGFloat)] = []
        var paragraphStart = 0
        while paragraphStart <= nsString.length {
            let newline = nsString.range(of: "\n", range: NSRange(location: paragraphStart, length: nsString.length - paragraphStart))
            let paragraphEnd = newline.location == NSNotFound ? nsString.length : newline.location
            var start = paragraphStart
            if start == paragraphEnd {
                // 空行保留行高
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: max(start - 1, 0), length: 0))
                let metrics = lineMetrics(line, string: string, at: max(start - 1, 0))
                lines.append((line, metrics.ascent, metrics.descent, 0))
            }
            while start < paragraphEnd {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
                count = max(1, min(count, paragraphEnd - start))
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                let metrics = lineMetrics(line, string: string, at: start)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
                lines.append((line, metrics.ascent, metrics.descent, width))
                start += count
            }
            if newline.location == NSNotFound { break }
            paragraphStart = newline.location + 1
        }

        let blockWidth = lines.map(\.width).max() ?? 0
        let blockHeight = lines.reduce(0) { $0 + $1.ascent + $1.descent }
        let column = (dialogue.alignment - 1) % 3 // 0 左，1 中，2 右
        let row = (dialogue.alignment - 1) / 3

        var origin = CGPoint.zero
        if let position = dialogue.position {
            let anchor = CGPoint(x: video.minX + position.x * scaleX, y: video.minY + position.y * scaleY)
            origin.x = anchor.x - blockWidth * CGFloat(column) / 2
            origin.y = row == 0 ? anchor.y - blockHeight : row == 1 ? anchor.y - blockHeight / 2 : anchor.y
        } else {
            let left: CGFloat = video.minX + marginL
            let right: CGFloat = video.maxX - marginR
            let center: CGFloat = (left + right - blockWidth) / 2
            origin.x = column == 0 ? left : column == 2 ? right - blockWidth : center
            let marginV = dialogue.marginV * scaleY
            origin.y = row == 0 ? video.maxY - marginV - blockHeight
                : row == 2 ? video.minY + marginV
                : video.midY - blockHeight / 2
        }

        var placed: [TextBlock.Line] = []
        var y = origin.y
        for line in lines {
            let x = origin.x + (blockWidth - line.width) * CGFloat(column) / 2
            let box = CGRect(x: x, y: y, width: line.width, height: line.ascent + line.descent)
            placed.append(.init(line: line.line, origin: CGPoint(x: x, y: y + line.ascent), box: box))
            y += line.ascent + line.descent
        }
        return TextBlock(
            lines: placed,
            frame: CGRect(x: origin.x, y: origin.y, width: blockWidth, height: blockHeight),
            opacity: opacity
        )
    }

    /// 行高取字体的 ascent + descent，与 ASS 字号的定义一致
    private func lineMetrics(_ line: CTLine, string: NSAttributedString, at index: Int) -> (ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        if ascent + descent == 0, index < string.length,
           let font = string.attribute(.init(kCTFontAttributeName as String), at: index, effectiveRange: nil) {
            let font = font as! CTFont
            return (CTFontGetAscent(font), CTFontGetDescent(font))
        }
        return (ascent, descent)
    }

    private func attributes(_ style: ASSStyle, scaleX: CGFloat, scaleY: CGFloat) -> [NSAttributedString.Key: Any] {
        let font = font(style, scaleY: scaleY)
        var decoration = 0
        if style.underline { decoration |= 1 }
        if style.strikeout { decoration |= 2 }
        let outline = style.outline * scaleY
        let shadow = style.shadow * scaleY
        return [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorFromContextAttributeName as String): true,
            .init(kCTKernAttributeName as String): style.spacing * scaleX,
            Attribute.fillColor: style.primary,
            Attribute.outlineColor: style.outlineColor,
            Attribute.outlineWidth: outline,
            Attribute.shadowColor: style.backColor,
            Attribute.shadowOffset: shadow,
            Attribute.boxed: style.borderStyle == 3,
            Attribute.decoration: decoration,
        ]
    }

    // MARK: - 字体

    private struct FontKey: Hashable {
        var name: String
        var size: CGFloat
        var scaleX: CGFloat
        var bold: Bool
        var italic: Bool
    }

    private func font(_ style: ASSStyle, scaleY: CGFloat) -> CTFont {
        let base = baseFont(style.fontName)
        let key = FontKey(
            name: style.fontName, size: (style.fontSize * style.scaleY * scaleY * base.scale).rounded(toPlaces: 2),
            scaleX: style.scaleX / max(style.scaleY, 0.01), bold: style.bold, italic: style.italic
        )
        if let font = fonts[key] { return font }
        var matrix = CGAffineTransform(scaleX: key.scaleX, y: 1)
        var traits: CTFontSymbolicTraits = []
        if key.bold { traits.insert(.traitBold) }
        if key.italic { traits.insert(.traitItalic) }
        let font = CTFontCreateCopyWithSymbolicTraits(base.font, key.size, &matrix, traits, [.traitBold, .traitItalic])
            ?? CTFontCreateCopyWithAttributes(base.font, key.size, &matrix, nil)
        if fonts.count > 256 { fonts.removeAll() }
        fonts[key] = font
        return font
    }

    /// 解析字体名称；系统未安装时使用苹方。scale 将 ASS 字号（行高）换算为磅值。
    private func baseFont(_ name: String) -> (font: CTFont, scale: CGFloat) {
        if let cached = baseFonts[name] { return cached }
        var font = CTFontCreateWithName(name as CFString, 100, nil)
        let names = [kCTFontFamilyNameKey, kCTFontFullNameKey, kCTFontPostScriptNameKey].compactMap {
            CTFontCopyName(font, $0) as String?
        }
        if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            font = CTFontCreateWithName("PingFang SC" as CFString, 100, nil)
        }
        let height = CTFontGetAscent(font) + CTFontGetDescent(font)
        let entry = (font, height > 0 ? 100 / height : 1)
        baseFonts[name] = entry
        return entry
    }

    // MARK: - 绘制

    /// 绘制到左上角原点的上下文中
    func draw(_ items: [Item], in context: CGContext) {
        for item in items {
            switch item {
            case .bitmap(let image, let rect):
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
            case .text(let block):
                draw(block, in: context)
            }
        }
    }

    private enum Pass { case box, shadow, outline, fill }

    private func draw(_ block: TextBlock, in context: CGContext) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setLineJoin(.round)
        if block.opacity < 1 {
            context.setAlpha(block.opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for pass in [Pass.box, .shadow, .outline, .fill] {
            for line in block.lines {
                for run in CTLineGetGlyphRuns(line.line) as! [CTRun] {
                    draw(run, line: line, pass: pass, in: context)
                }
            }
        }
        if block.opacity < 1 { context.endTransparencyLayer() }
        context.restoreGState()
    }

    private func draw(_ run: CTRun, line: TextBlock.Line, pass: Pass, in context: CGContext) {
        let attributes = CTRunGetAttributes(run) as! [NSAttributedString.Key: Any]
        guard let fill = attributes[Attribute.fillColor] as? ASSColor,
              let outlineColor = attributes[Attribute.outlineColor] as? ASSColor,
              let shadowColor = attributes[Attribute.shadowColor] as? ASSColor else { return }
        let outline = attributes[Attribute.outlineWidth] as? CGFloat ?? 0
        let shadow = attributes[Attribute.shadowOffset] as? CGFloat ?? 0
        let boxed = attributes[Attribute.boxed] as? Bool ?? false
        let decoration = attributes[Attribute.decoration] as? Int ?? 0
        let font = attributes[.init(kCTFontAttributeName as String)] as! CTFont

        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil))
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        let x = line.origin.x + position.x
        let runBox = CGRect(x: x, y: line.box.minY, width: width, height: line.box.height)

        func glyphs(at origin: CGPoint, mode: CGTextDrawingMode) {
            context.textPosition = origin
            context.setTextDrawingMode(mode)
            CTRunDraw(run, context, CFRange())
        }

        switch pass {
        case .box:
            guard boxed else { return }
            // 不透明底框：底框用描边色，阴影用阴影色
            if shadow > 0, shadowColor.alpha > 0 {
                context.setFillColor(shadowColor.cgColor())
                context.fill(runBox.insetBy(dx: -outline, dy: -outline).offsetBy(dx: shadow, dy: shadow))
            }
            context.setFillColor(outlineColor.cgColor())
            context.fill(runBox.insetBy(dx: -outline, dy: -outline))
        case .shadow:
            guard !boxed, shadow > 0, shadowColor.alpha > 0 else { return }
            context.setFillColor(shadowColor.cgColor())
            context.setStrokeColor(shadowColor.cgColor())
            context.setLineWidth(outline * 2)
            glyphs(at: CGPoint(x: line.origin.x + shadow, y: line.origin.y + shadow), mode: outline > 0 ? .fillStroke : .fill)
        case .outline:
            guard !boxed, outline > 0, outlineColor.alpha > 0 else { return }
            context.setStrokeColor(outlineColor.cgColor())
            context.setLineWidth(outline * 2)
            glyphs(at: line.origin, mode: .stroke)
        case .fill:
            context.setFillColor(fill.cgColor())
            glyphs(at: line.origin, mode: .fill)
            if decoration != 0 {
                let thickness = max(CTFontGetUnderlineThickness(font), 1)
                if decoration & 1 != 0 {
                    context.fill(CGRect(x: x, y: line.origin.y - CTFontGetUnderlinePosition(font), width: width, height: thickness))
                }
                if decoration & 2 != 0 {
                    context.fill(CGRect(x: x, y: line.origin.y - CTFontGetXHeight(font) / 2, width: width, height: thickness))
                }
            }
        }
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
