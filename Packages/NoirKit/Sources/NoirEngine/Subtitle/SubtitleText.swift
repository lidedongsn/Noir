import Foundation

/// 文本字幕（SRT、ASS、Timed Text、WebVTT）的解析
enum SubtitleText {
    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        case empty(String)

        var description: String {
            switch self {
            case .unreadable(let name): "无法识别字幕文件的编码：\(name)"
            case .empty(let name): "字幕文件中没有可显示的内容：\(name)"
            }
        }
    }

    static let fileExtensions: Set<String> = ["srt", "ass", "ssa"]

    // MARK: - 外挂文件

    /// 读取外挂字幕文件
    static func load(url: URL, info: SubtitleTrackInfo) throws -> SubtitleTrack {
        let data = try Data(contentsOf: url)
        guard let text = decode(data) else { throw LoadError.unreadable(url.lastPathComponent) }
        let isSRT = url.pathExtension.lowercased() == "srt"
        let script = isSRT ? ASSScript.plainText : ASSScript(header: text)
        let cues = isSRT ? parseSRT(text) : parseASSEvents(text, script: script)
        guard !cues.isEmpty else { throw LoadError.empty(url.lastPathComponent) }
        var info = info
        // 文件名未标注语言时按内容判断是否为中文
        if info.language == nil, !info.isChinese, containsChinese(cues) { info.language = "chi" }
        return SubtitleTrack(info: info, script: script, cues: cues)
    }

    /// 抽样检查字幕文本中是否以汉字为主
    static func containsChinese(_ cues: [SubtitleCue]) -> Bool {
        var han = 0, letters = 0
        for cue in cues.prefix(200) {
            guard case .text(let dialogue) = cue.content else { continue }
            for scalar in dialogue.runs.map(\.text).joined().unicodeScalars where scalar.properties.isAlphabetic {
                letters += 1
                if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) { han += 1 }
            }
        }
        return letters > 0 && Double(han) / Double(letters) > 0.3
    }

    /// 识别文本编码：BOM、UTF-8，中文字幕常见的 GB18030 与 Big5
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return text }
        for encoding in [CFStringEncodings.GB_18030_2000, .big5] {
            let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: ns)) { return text }
        }
        return nil
    }

    // MARK: - SRT

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            guard let arrow = lines[i].range(of: "-->"),
                  let start = srtTime(lines[i][..<arrow.lowerBound]),
                  let end = srtTime(lines[i][arrow.upperBound...].split(separator: " ", omittingEmptySubsequences: true).first ?? "")
            else {
                i += 1
                continue
            }
            i += 1
            var body: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                // 缺少空行分隔时，遇到下一条的时间行即停止
                if lines[i].contains("-->"), srtTime(lines[i].prefix { $0 != "-" }) != nil { break }
                body.append(lines[i])
                i += 1
            }
            // 去掉误收的下一条序号行
            if let last = body.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil, i < lines.count, lines[i].contains("-->") {
                body.removeLast()
            }
            if let cue = plainCue(body.joined(separator: "\n"), start: start, end: end, key: Int64(cues.count)) {
                cues.append(cue)
            }
        }
        return cues
    }

    /// 解析 HH:MM:SS,mmm（允许省略小时、使用小数点）
    static func srtTime(_ text: Substring) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// 纯文本字幕条目：HTML 样式标签转换为 ASS 覆盖标签，ASS 标签（如 {\an8}）原样保留
    static func plainCue(_ text: String, start: Double, end: Double, key: Int64) -> SubtitleCue? {
        let script = ASSScript.plainText
        let dialogue = ASSDialogue(text: htmlToASS(text), style: script.style(named: "Default"), script: script)
        guard !dialogue.isEmpty, end > start else { return nil }
        return SubtitleCue(start: start, end: end, key: key, content: .text(dialogue))
    }

    static func htmlToASS(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\n", with: "\\N")
        let replacements = [
            "<i>": "{\\i1}", "</i>": "{\\i0}", "<b>": "{\\b1}", "</b>": "{\\b0}",
            "<u>": "{\\u1}", "</u>": "{\\u0}", "<s>": "{\\s1}", "</s>": "{\\s0}", "</font>": "{\\c}",
        ]
        for (tag, ass) in replacements {
            result = result.replacingOccurrences(of: tag, with: ass, options: .caseInsensitive)
        }
        // <font color="#RRGGBB"> → {\c&HBBGGRR&}
        while let open = result.range(of: "<font", options: .caseInsensitive),
              let close = result[open.upperBound...].firstIndex(of: ">") {
            let attributes = result[open.upperBound..<close]
            var replacement = ""
            if let hash = attributes.firstIndex(of: "#") {
                let hex = attributes[attributes.index(after: hash)...].prefix(6)
                if hex.count == 6 {
                    let rr = hex.prefix(2), gg = hex.dropFirst(2).prefix(2), bb = hex.suffix(2)
                    replacement = "{\\c&H\(bb)\(gg)\(rr)&}"
                }
            }
            result.replaceSubrange(open.lowerBound...close, with: replacement)
        }
        // 去掉其余 HTML 标签
        while let open = result.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) {
            result.removeSubrange(open)
        }
        return result
    }

    // MARK: - ASS

    /// 解析 .ass 文件的 [Events] 段
    static func parseASSEvents(_ text: String, script: ASSScript) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        let format = script.eventFormat
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, line.lowercased().hasPrefix("dialogue:") else { continue }
            let body = line.dropFirst("dialogue:".count)
            let fields = body.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
            var values: [String: Substring] = [:]
            for (name, field) in zip(format, fields) { values[name] = field }
            guard let start = values["start"].flatMap(ASSTime.parse),
                  let end = values["end"].flatMap(ASSTime.parse),
                  let text = values["text"] else { continue }
            let event = assDialogue(values: values, text: text, script: script)
            guard !event.isEmpty, end > start else { continue }
            cues.append(SubtitleCue(start: start, end: end, key: Int64(cues.count), content: .text(event)))
        }
        return cues
    }

    /// 内封 ASS 数据包：ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
    static func assPacket(_ text: String, start: Double, end: Double, script: ASSScript) -> SubtitleCue? {
        let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return nil }
        let names = ["readorder", "layer", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var values: [String: Substring] = [:]
        for (name, field) in zip(names, fields) { values[name] = field }
        let event = assDialogue(values: values, text: fields[8], script: script)
        guard !event.isEmpty, end > start else { return nil }
        let order = Int64(fields[0].trimmingCharacters(in: .whitespaces)) ?? Int64(start * 1000)
        return SubtitleCue(start: start, end: end, key: order, content: .text(event))
    }

    private static func assDialogue(values: [String: Substring], text: Substring, script: ASSScript) -> ASSDialogue {
        func number(_ key: String) -> Double { values[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0 }
        let style = script.style(named: values["style"].map { $0.trimmingCharacters(in: .whitespaces) } ?? "Default")
        return ASSDialogue(
            text: String(text), style: style, script: script, layer: Int(number("layer")),
            margins: (number("marginl"), number("marginr"), number("marginv"))
        )
    }
}
