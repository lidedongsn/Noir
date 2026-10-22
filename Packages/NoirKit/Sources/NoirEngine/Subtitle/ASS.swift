import CoreGraphics
import Foundation

// ASS / SSA 字幕的解析。渲染支持常用子集：字体、字号、颜色与透明度、粗斜体、下划线、删除线、
// 描边、阴影、缩放、字距、对齐、边距、\pos、\move（取起点）、\fad；动画、卡拉 OK、旋转与矢量绘图不还原。

/// 颜色，分量取值 0...1，alpha 为不透明度
struct ASSColor: Sendable, Equatable {
    var red: Double, green: Double, blue: Double, alpha: Double

    static let white = ASSColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = ASSColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// 解析 &HAABBGGRR 或十进制写法；ASS 的 alpha 为透明度（00 不透明）
    init?(ass text: Substring) {
        var s = text.trimmingCharacters(in: .whitespaces)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "&"))
        let value: UInt32?
        if s.uppercased().hasPrefix("H") {
            value = UInt32(s.dropFirst().prefix(8), radix: 16)
        } else {
            value = Int64(s).map { UInt32(truncatingIfNeeded: $0) }
        }
        guard let value else { return nil }
        self.init(abgr: value)
    }

    init(abgr value: UInt32) {
        red = Double(value & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double((value >> 16) & 0xFF) / 255
        alpha = 1 - Double((value >> 24) & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 解析 \alpha 等标签的透明度值（&HAA&）
    static func alpha(ass text: Substring) -> Double? {
        let s = text.trimmingCharacters(in: CharacterSet(charactersIn: "&Hh "))
        guard let value = UInt32(s, radix: 16) else { return nil }
        return 1 - Double(value & 0xFF) / 255
    }

    func cgColor(opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha * opacity)
    }
}

struct ASSStyle: Sendable {
    var name = "Default"
    var fontName = "PingFang SC"
    var fontSize = 20.0
    var primary = ASSColor.white
    var outlineColor = ASSColor.black
    var backColor = ASSColor.black
    var bold = false
    var italic = false
    var underline = false
    var strikeout = false
    var scaleX = 1.0
    var scaleY = 1.0
    var spacing = 0.0
    /// 1 为描边加阴影，3 为不透明底框
    var borderStyle = 1
    var outline = 2.0
    var shadow = 2.0
    /// 小键盘方位：1–3 底部，4–6 中部，7–9 顶部
    var alignment = 2
    var marginL = 10.0
    var marginR = 10.0
    var marginV = 10.0
}

/// 脚本头：分辨率与样式表
struct ASSScript: Sendable {
    var playResX = 384.0
    var playResY = 288.0
    var styles: [String: ASSStyle] = [:]
    var eventFormat = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    func style(named name: String) -> ASSStyle {
        styles[name] ?? styles[name.trimmingCharacters(in: CharacterSet(charactersIn: "*"))]
            ?? styles["Default"] ?? ASSStyle()
    }

    /// SRT、Timed Text 等纯文本字幕使用的默认样式（以 1080p 为基准）
    static let plainText: ASSScript = {
        var script = ASSScript(playResX: 1920, playResY: 1080)
        script.styles["Default"] = ASSStyle(
            fontSize: 66,
            backColor: ASSColor(red: 0, green: 0, blue: 0, alpha: 0.5),
            outline: 2.6, shadow: 1.5,
            marginL: 80, marginR: 80, marginV: 56
        )
        return script
    }()

    init(playResX: Double = 384, playResY: Double = 288) {
        self.playResX = playResX
        self.playResY = playResY
    }

    /// 解析 [Script Info] 与样式段；`header` 可以是完整的 .ass 文件
    init(header: String) {
        var resX: Double?, resY: Double?
        var section = ""
        var styleFormat: [String] = []
        for rawLine in header.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.lowercased()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case ("[script info]", "playresx"): resX = Double(value)
            case ("[script info]", "playresy"): resY = Double(value)
            case (_, "format") where section.contains("styles"):
                styleFormat = Self.fieldNames(value)
            case (_, "style") where section.contains("styles"):
                let legacy = section == "[v4 styles]"
                if let style = Self.parseStyle(value, format: styleFormat, legacy: legacy) {
                    styles[style.name] = style
                }
            case ("[events]", "format"):
                eventFormat = Self.fieldNames(value)
            default:
                break
            }
        }
        // 只给出一个分辨率时按 4:3 推算另一个，与 libass 一致
        switch (resX, resY) {
        case let (x?, y?): (playResX, playResY) = (x, y)
        case let (x?, nil): (playResX, playResY) = (x, x == 1280 ? 1024 : x * 3 / 4)
        case let (nil, y?): (playResX, playResY) = (y == 1024 ? 1280 : y * 4 / 3, y)
        case (nil, nil): break
        }
    }

    static func fieldNames(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func parseStyle(_ value: String, format: [String], legacy: Bool) -> ASSStyle? {
        let format = format.isEmpty
            ? ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour", "backcolour",
               "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing", "angle", "borderstyle",
               "outline", "shadow", "alignment", "marginl", "marginr", "marginv", "encoding"]
            : format
        let fields = value.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        var style = ASSStyle()
        for (name, field) in zip(format, fields) {
            let text = field.trimmingCharacters(in: .whitespaces)
            let number = Double(text)
            switch name {
            case "name": style.name = text
            case "fontname": style.fontName = text.hasPrefix("@") ? String(text.dropFirst()) : text
            case "fontsize": style.fontSize = number ?? style.fontSize
            case "primarycolour": style.primary = ASSColor(ass: field) ?? style.primary
            case "outlinecolour", "tertiarycolour": style.outlineColor = ASSColor(ass: field) ?? style.outlineColor
            case "backcolour": style.backColor = ASSColor(ass: field) ?? style.backColor
            case "bold": style.bold = (number ?? 0) != 0
            case "italic": style.italic = (number ?? 0) != 0
            case "underline": style.underline = (number ?? 0) != 0
            case "strikeout": style.strikeout = (number ?? 0) != 0
            case "scalex": style.scaleX = (number ?? 100) / 100
            case "scaley": style.scaleY = (number ?? 100) / 100
            case "spacing": style.spacing = number ?? 0
            case "borderstyle": style.borderStyle = Int(text) ?? 1
            case "outline": style.outline = number ?? style.outline
            case "shadow": style.shadow = number ?? style.shadow
            case "alignment":
                let value = Int(text) ?? 2
                style.alignment = legacy ? legacyAlignment(value) : value
            case "marginl": style.marginL = number ?? style.marginL
            case "marginr": style.marginR = number ?? style.marginR
            case "marginv": style.marginV = number ?? style.marginV
            default: break
            }
        }
        return style
    }

    /// SSA（V4）的对齐取值：1–3 底部，5–7 顶部，9–11 中部
    static func legacyAlignment(_ value: Int) -> Int {
        let column = (value - 1) % 4 + 1
        switch value {
        case 5...7: return column + 6
        case 9...11: return column + 3
        default: return min(max(column, 1), 3)
        }
    }
}

// MARK: - 对白

/// 一段文本连同其样式
struct ASSRun: Sendable {
    var text: String
    var style: ASSStyle
}

/// 解析后的一条对白，可直接用于排版
struct ASSDialogue: Sendable {
    var layer = 0
    var runs: [ASSRun] = []
    var alignment = 2
    var marginL = 0.0
    var marginR = 0.0
    var marginV = 0.0
    /// \pos 或 \move 起点（脚本坐标）
    var position: CGPoint?
    var fadeIn = 0.0
    var fadeOut = 0.0

    var isEmpty: Bool { runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// 解析对白文本中的覆盖标签。`margins` 为事件自带边距，0 表示使用样式边距。
    init(text: String, style base: ASSStyle, script: ASSScript, layer: Int = 0, margins: (Double, Double, Double) = (0, 0, 0)) {
        self.layer = layer
        alignment = base.alignment
        marginL = margins.0 != 0 ? margins.0 : base.marginL
        marginR = margins.1 != 0 ? margins.1 : base.marginR
        marginV = margins.2 != 0 ? margins.2 : base.marginV

        var style = base
        var buffer = ""
        var drawing = false
        var alignmentSet = false
        var chars = Substring(text)

        func flush() {
            if !buffer.isEmpty, !drawing { runs.append(ASSRun(text: buffer, style: style)) }
            buffer = ""
        }

        while let c = chars.first {
            if c == "{", let close = chars.firstIndex(of: "}") {
                flush()
                let block = chars[chars.index(after: chars.startIndex)..<close]
                for tag in Self.tags(in: block) {
                    apply(tag, to: &style, base: base, script: script, drawing: &drawing, alignmentSet: &alignmentSet)
                }
                chars = chars[chars.index(after: close)...]
                continue
            }
            if c == "\\", chars.count > 1 {
                let next = chars[chars.index(after: chars.startIndex)]
                switch next {
                case "N": buffer.append("\n")
                case "n": buffer.append(" ")
                case "h": buffer.append("\u{00A0}")
                default: buffer.append(c); buffer.append(next)
                }
                chars = chars.dropFirst(2)
                continue
            }
            buffer.append(c)
            chars = chars.dropFirst()
        }
        flush()
    }

    /// 拆分覆盖标签块；括号内的反斜杠（如 \t(...)）不作为分隔
    static func tags(in block: Substring) -> [Substring] {
        var result: [Substring] = []
        var depth = 0
        var start: Substring.Index?
        var i = block.startIndex
        while i < block.endIndex {
            let c = block[i]
            if c == "(" { depth += 1 }
            if c == ")" { depth = max(depth - 1, 0) }
            if c == "\\", depth == 0 {
                if let start { result.append(block[start..<i]) }
                start = block.index(after: i)
            }
            i = block.index(after: i)
        }
        if let start { result.append(block[start...]) }
        return result
    }

    private static let tagNames = [
        "iclip", "clip", "fade", "fad", "fscx", "fscy", "fsp", "fs", "fn", "fax", "fay", "frx", "fry", "frz", "fr", "fe",
        "xbord", "ybord", "bord", "xshad", "yshad", "shad", "blur", "be", "b", "i", "u", "s",
        "1c", "2c", "3c", "4c", "c", "1a", "2a", "3a", "4a", "alpha", "an", "a",
        "pos", "move", "org", "kf", "ko", "k", "K", "q", "r", "pbo", "p", "t",
    ].sorted { $0.count > $1.count }

    private mutating func apply(
        _ tag: Substring, to style: inout ASSStyle, base: ASSStyle, script: ASSScript,
        drawing: inout Bool, alignmentSet: inout Bool
    ) {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        guard let name = Self.tagNames.first(where: { tag.hasPrefix($0) }) else { return }
        let raw = tag.dropFirst(name.count)
        let arg = raw.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        let number = Double(arg)
        let list = arg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        switch name {
        case "b": style.bold = arg.isEmpty ? base.bold : (number ?? 0) != 0 && number != 400
        case "i": style.italic = arg.isEmpty ? base.italic : number == 1
        case "u": style.underline = arg.isEmpty ? base.underline : number == 1
        case "s": style.strikeout = arg.isEmpty ? base.strikeout : number == 1
        case "fn": style.fontName = arg.isEmpty ? base.fontName : String(arg)
        case "fs": style.fontSize = number.map { $0 > 0 ? $0 : base.fontSize } ?? base.fontSize
        case "fscx": style.scaleX = (number ?? base.scaleX * 100) / 100
        case "fscy": style.scaleY = (number ?? base.scaleY * 100) / 100
        case "fsp": style.spacing = number ?? base.spacing
        case "bord": style.outline = number ?? base.outline
        case "shad": style.shadow = number ?? base.shadow
        case "c", "1c": style.primary = color(arg, keeping: style.primary, base: base.primary)
        case "3c": style.outlineColor = color(arg, keeping: style.outlineColor, base: base.outlineColor)
        case "4c": style.backColor = color(arg, keeping: style.backColor, base: base.backColor)
        case "alpha":
            let alpha = ASSColor.alpha(ass: Substring(arg)) ?? 1
            style.primary.alpha = alpha
            style.outlineColor.alpha = alpha
            style.backColor.alpha = alpha
        case "1a": style.primary.alpha = ASSColor.alpha(ass: Substring(arg)) ?? base.primary.alpha
        case "3a": style.outlineColor.alpha = ASSColor.alpha(ass: Substring(arg)) ?? base.outlineColor.alpha
        case "4a": style.backColor.alpha = ASSColor.alpha(ass: Substring(arg)) ?? base.backColor.alpha
        case "an":
            // 同一行内只有第一个对齐标签生效
            if !alignmentSet, let value = Int(arg), (1...9).contains(value) {
                alignment = value
                alignmentSet = true
            }
        case "a":
            if !alignmentSet, let value = Int(arg) {
                alignment = ASSScript.legacyAlignment(value)
                alignmentSet = true
            }
        case "pos", "move":
            if position == nil, list.count >= 2 { position = CGPoint(x: list[0], y: list[1]) }
        case "fad":
            if list.count == 2 {
                fadeIn = list[0] / 1000
                fadeOut = list[1] / 1000
            }
        case "r":
            style = arg.isEmpty ? base : script.style(named: String(arg))
        case "p":
            drawing = (number ?? 0) > 0
        default:
            break
        }
    }

    private func color(_ arg: String, keeping current: ASSColor, base: ASSColor) -> ASSColor {
        guard !arg.isEmpty, var color = ASSColor(ass: Substring(arg)) else { return base }
        // 颜色标签不含透明度，保留当前值
        color.alpha = current.alpha
        return color
    }
}

// MARK: - 时间

enum ASSTime {
    /// 解析 H:MM:SS.cc
    static func parse(_ text: Substring) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }
}
