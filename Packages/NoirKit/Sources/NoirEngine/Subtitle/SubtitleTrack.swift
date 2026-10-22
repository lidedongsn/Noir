import CoreGraphics
import Foundation
import Synchronization

/// 字幕格式
public enum SubtitleFormat: String, Sendable {
    case pgs = "PGS"
    case srt = "SRT"
    case ass = "ASS"
    case movText = "Timed Text"
    case webVTT = "WebVTT"

    var isText: Bool { self != .pgs }
}

public struct SubtitleTrackInfo: Sendable, Identifiable {
    /// 内封字幕为 FFmpeg 流序号，外挂字幕从 `externalIDBase` 起编号
    public var id: Int
    /// 不支持的格式为 nil
    public var format: SubtitleFormat?
    public var codec: String
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isExternal: Bool
    /// 内封 ASS 的脚本头（样式定义）
    var header: String?

    static let externalIDBase = 10_000

    public var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, language != "und", language != title { parts.append(language.uppercased()) }
        parts.append(format?.rawValue ?? codec)
        if isForced { parts.append("强制") }
        if isExternal { parts.append("外挂") }
        return parts.joined(separator: " · ")
    }

    /// 是否为中文字幕（依据语言代码与标题）
    var isChinese: Bool {
        let language = (language ?? "").lowercased()
        if ["chi", "zho", "zh", "chs", "cht", "chn"].contains(where: { language == $0 || language.hasPrefix($0 + "-") }) {
            return true
        }
        return Self.matches(title, ["中", "简", "繁", "chs", "cht", "chinese", "zh", "sc", "tc", "gb", "big5"])
    }

    /// 是否为简体中文
    var isSimplifiedChinese: Bool {
        let language = (language ?? "").lowercased()
        return ["zh-cn", "zh-hans", "chs", "zh-sg"].contains(language)
            || Self.matches(title, ["简", "chs", "sc", "gb", "hans", "simplified"])
    }

    private static func matches(_ text: String?, _ keywords: [String]) -> Bool {
        guard let text = text?.lowercased(), !text.isEmpty else { return false }
        // 按分隔符切词，避免 "sc" 之类的短关键词误匹配英文单词
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return keywords.contains { keyword in
            keyword.unicodeScalars.allSatisfy(\.isASCII)
                ? tokens.contains(keyword)
                : text.contains(keyword)
        }
    }
}

// MARK: - 字幕条目

/// 一条字幕：文本事件或 PGS 图像
struct SubtitleCue: @unchecked Sendable {
    enum Content {
        case text(ASSDialogue)
        case bitmaps([SubtitleBitmap], canvas: CGSize)
    }

    var start: Double
    /// PGS 没有显式结束时间，由下一条字幕的开始时间确定，确定前为 infinity
    var end: Double
    /// 去重键：同一条字幕在跳转后可能被重复读取
    var key: Int64
    var content: Content

    /// 绘制层级，数值大的在上
    var layer: Int {
        if case .text(let dialogue) = content { dialogue.layer } else { 0 }
    }
}

struct SubtitleBitmap: @unchecked Sendable {
    var image: CGImage
    /// 在画布坐标中的位置（左上角原点）
    var rect: CGRect
}

/// 字幕轨道的数据存储，可在播放队列写入、主线程读取。
final class SubtitleTrack: Sendable {
    let info: SubtitleTrackInfo
    let script: ASSScript
    private let cues = Mutex<[SubtitleCue]>([])

    /// 结束时间未知的 PGS 字幕最长显示时长
    private static let openEndedLimit = 10.0

    init(info: SubtitleTrackInfo, script: ASSScript) {
        self.info = info
        self.script = script
    }

    convenience init(info: SubtitleTrackInfo, script: ASSScript, cues initial: [SubtitleCue]) {
        self.init(info: info, script: script)
        cues.withLock { $0 = initial.sorted { $0.start < $1.start } }
    }

    var count: Int { cues.withLock(\.count) }

    /// 按开始时间插入；已存在相同去重键的条目时忽略。
    func insert(_ cue: SubtitleCue) {
        cues.withLock { cues in
            let index = cues.partitionIndex { $0.start >= cue.start }
            var i = index
            while i < cues.count, cues[i].start == cue.start {
                if cues[i].key == cue.key { return }
                i += 1
            }
            cues.insert(cue, at: index)
            closeOpenEnded(&cues, before: index, at: cue.start)
        }
    }

    /// PGS 清屏事件：结束此前尚在显示的字幕
    func close(at time: Double) {
        cues.withLock { cues in
            closeOpenEnded(&cues, before: cues.partitionIndex { $0.start >= time }, at: time)
        }
    }

    private func closeOpenEnded(_ cues: inout [SubtitleCue], before index: Int, at time: Double) {
        guard index > 0 else { return }
        let previous = index - 1
        if cues[previous].end == .infinity, cues[previous].start < time {
            cues[previous].end = time
        }
    }

    /// 指定时间应显示的字幕，按开始时间排序
    func active(at time: Double) -> [SubtitleCue] {
        cues.withLock { cues in
            let upper = cues.partitionIndex { $0.start > time }
            return cues[..<upper].filter { cue in
                cue.end == .infinity ? time - cue.start < Self.openEndedLimit : time < cue.end
            }
        }
    }
}

extension Array {
    /// 第一个满足条件的下标；要求数组按该条件有序（前段不满足、后段满足）
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
