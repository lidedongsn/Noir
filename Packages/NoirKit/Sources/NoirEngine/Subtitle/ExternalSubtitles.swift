import Foundation

/// 外挂字幕的查找与默认轨道选择
enum ExternalSubtitles {
    /// 与视频同名的字幕文件，例如 Movie.srt、Movie.chs.ass、Movie.zh-Hans.srt。
    /// 无法读取所在文件夹（沙盒未授权）时抛出错误。
    static func siblings(of video: URL) throws -> [URL] {
        let folder = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return files.filter { url in
            SubtitleText.fileExtensions.contains(url.pathExtension.lowercased())
                && url.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 外挂字幕的轨道信息；文件名中视频名之后的部分作为语言或标题
    static func info(for url: URL, video: URL?, id: Int) -> SubtitleTrackInfo {
        let name = url.deletingPathExtension().lastPathComponent
        var tag = name
        if let video {
            let base = video.deletingPathExtension().lastPathComponent
            if name.lowercased().hasPrefix(base.lowercased()) { tag = String(name.dropFirst(base.count)) }
        }
        tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: ". _-[]()"))
        let ext = url.pathExtension.lowercased()
        return SubtitleTrackInfo(
            id: id,
            format: ext == "srt" ? .srt : .ass,
            codec: ext,
            language: nil,
            title: tag.isEmpty ? nil : tag,
            isDefault: false,
            isForced: false,
            isExternal: true
        )
    }

    /// 默认字幕：优先中文（外挂、简体、标记为默认的优先），没有中文时不显示
    static func preferred(_ tracks: [SubtitleTrackInfo]) -> SubtitleTrackInfo? {
        tracks.filter { $0.format != nil && $0.isChinese && !$0.isForced }
            .enumerated()
            .max { a, b in
                score(a.element) != score(b.element) ? score(a.element) < score(b.element) : a.offset > b.offset
            }?
            .element
    }

    private static func score(_ track: SubtitleTrackInfo) -> Int {
        (track.isExternal ? 4 : 0) + (track.isSimplifiedChinese ? 2 : 0) + (track.isDefault ? 1 : 0)
    }
}
