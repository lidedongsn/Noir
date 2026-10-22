import CFFmpeg
import CoreGraphics
import Foundation
import Testing
@testable import NoirEngine

@Suite struct SubtitleParsingTests {
    @Test("读取内封字幕轨道信息") func embeddedTrackInfo() throws {
        let info = try TestMedia.demuxer("subs-srt-ass.mkv").info
        #expect(info.subtitleTracks.count == 2)
        let srt = try #require(info.subtitleTracks.first { $0.id == 2 })
        #expect(srt.format == .srt)
        #expect(srt.language == "eng")
        #expect(!srt.isChinese)
        let ass = try #require(info.subtitleTracks.first { $0.id == 3 })
        #expect(ass.format == .ass)
        #expect(ass.isDefault)
        #expect(ass.isChinese && ass.isSimplifiedChinese)
        #expect(ass.header?.contains("[V4+ Styles]") == true)

        let movText = try TestMedia.demuxer("subs-movtext.mp4").info.subtitleTracks
        #expect(movText.first?.format == .movText)
    }

    @Test("解析 ASS 脚本头与样式") func assHeader() throws {
        let script = ASSScript(header: Self.assFile)
        #expect(script.playResX == 1920 && script.playResY == 1080)
        let sign = script.style(named: "Sign")
        #expect(sign.fontSize == 50)
        #expect(sign.bold)
        #expect(sign.alignment == 8)
        #expect(sign.primary == ASSColor(red: 1, green: 1, blue: 0, alpha: 1))
        // 未知样式回退到 Default
        #expect(script.style(named: "Missing").fontSize == 70)
    }

    @Test("解析 ASS 覆盖标签") func assOverrides() {
        let script = ASSScript(header: Self.assFile)
        let base = script.style(named: "Default")
        let dialogue = ASSDialogue(
            text: #"{\an8\pos(100,200)\fad(300,400)}红{\c&H0000FF&\b1}色\N{\r}第二行{\p1}m 0 0 l 10 10{\p0}"#,
            style: base, script: script
        )
        #expect(dialogue.alignment == 8)
        #expect(dialogue.position == CGPoint(x: 100, y: 200))
        #expect(dialogue.fadeIn == 0.3 && dialogue.fadeOut == 0.4)
        #expect(dialogue.runs.map(\.text) == ["红", "色\n", "第二行"])
        #expect(dialogue.runs[1].style.primary == ASSColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(dialogue.runs[1].style.bold)
        // \r 恢复为基础样式
        #expect(!dialogue.runs[2].style.bold)
    }

    @Test("SRT 解析与 HTML 标签转换") func srt() throws {
        let text = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>斜体</i> 与 <font color=\"#FF0000\">红色</font>\r\n\r\n2\r\n00:00:03.000 --> 00:00:04.000\r\n{\\an8}顶部\r\n"
        let cues = SubtitleText.parseSRT(text)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1 && cues[0].end == 2.5)
        guard case .text(let first) = cues[0].content, case .text(let second) = cues[1].content else {
            Issue.record("应为文本字幕")
            return
        }
        #expect(first.runs.map(\.text).joined() == "斜体 与 红色")
        #expect(first.runs[0].style.italic)
        #expect(first.runs.last?.style.primary == ASSColor(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(second.alignment == 8)
    }

    @Test("识别 GB18030 编码的外挂字幕并判断为中文") func gb18030ExternalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let video = folder.appending(path: "Movie.mkv")
        try Data().write(to: video)
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n这是一条中文字幕\n"
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        try #require(srt.data(using: String.Encoding(rawValue: gb))).write(to: folder.appending(path: "Movie.srt"))
        try Self.assFile.write(to: folder.appending(path: "Movie.chs.ass"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "Other.srt"))

        let siblings = try ExternalSubtitles.siblings(of: video)
        #expect(siblings.map(\.lastPathComponent) == ["Movie.chs.ass", "Movie.srt"])

        let ass = ExternalSubtitles.info(for: siblings[0], video: video, id: 10_000)
        #expect(ass.title == "chs" && ass.isChinese && ass.isSimplifiedChinese)

        let srtInfo = ExternalSubtitles.info(for: siblings[1], video: video, id: 10_001)
        #expect(srtInfo.title == nil && !srtInfo.isChinese)
        let track = try SubtitleText.load(url: siblings[1], info: srtInfo)
        #expect(track.info.isChinese, "按内容识别为中文")
        guard case .text(let dialogue) = try #require(track.active(at: 1.5).first).content else {
            Issue.record("应为文本字幕")
            return
        }
        #expect(dialogue.runs.map(\.text).joined() == "这是一条中文字幕")
    }

    @Test("默认字幕优先外挂、简体中文") func preferredTrack() {
        func track(_ id: Int, _ language: String?, title: String? = nil, external: Bool = false, isDefault: Bool = false) -> SubtitleTrackInfo {
            SubtitleTrackInfo(id: id, format: .srt, codec: "subrip", language: language, title: title,
                              isDefault: isDefault, isForced: false, isExternal: external)
        }
        #expect(ExternalSubtitles.preferred([track(1, "eng"), track(2, "jpn")]) == nil)
        #expect(ExternalSubtitles.preferred([track(1, "eng"), track(2, "chi", title: "繁體"), track(3, "chi", title: "简体")])?.id == 3)
        #expect(ExternalSubtitles.preferred([track(1, "chi", title: "简体", isDefault: true), track(10_000, "chi", external: true)])?.id == 10_000)
        // "Scene" 等英文标题不应被误判为 sc（简体）
        #expect(!track(1, "eng", title: "Scene descriptions").isChinese)
    }

    static let assFile = """
    [Script Info]
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,PingFang SC,70,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,20,20,40,1
    Style: Sign,PingFang SC,50,&H0000FFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,0,8,20,20,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,中文字幕
    """
}

@Suite struct SubtitleDecodingTests {
    @Test("PGS 解码为图像并由清屏事件结束") func pgs() throws {
        var context = avformat_alloc_context()
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
        stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        stream.pointee.time_base = AVRational(num: 1, den: 1000)
        _ = context

        let info = SubtitleTrackInfo(id: 0, format: .pgs, codec: "hdmv_pgs_subtitle", language: "chi", title: nil,
                                     isDefault: true, isForced: false, isExternal: false)
        let track = SubtitleTrack(info: info, script: .plainText)
        let decoder = try SubtitleDecoder(stream: stream, track: track)

        decoder.decode(Self.packet(PGS.displaySet(objectCount: 1), pts: 1000))
        let cue = try #require(track.active(at: 1.5).first)
        #expect(cue.start == 1 && cue.end == .infinity)
        guard case .bitmaps(let bitmaps, let canvas) = cue.content else {
            Issue.record("应为图像字幕")
            return
        }
        #expect(canvas == CGSize(width: 1920, height: 1080))
        #expect(bitmaps.first?.rect == CGRect(x: 100, y: 900, width: 4, height: 2))
        #expect(bitmaps.first?.image.width == 4)

        decoder.decode(Self.packet(PGS.displaySet(objectCount: 0), pts: 2500))
        #expect(track.active(at: 2).count == 1)
        #expect(track.active(at: 2.6).isEmpty, "清屏后不再显示")
    }

    static func packet(_ bytes: [UInt8], pts: Int64) -> Packet {
        let packet = Packet()
        av_new_packet(packet.raw, Int32(bytes.count))
        bytes.withUnsafeBytes { packet.raw.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
        packet.raw.pointee.pts = pts
        packet.raw.pointee.dts = pts
        return packet
    }

    /// 构造最小的 PGS 显示集：4×2 像素、单一白色
    enum PGS {
        static func displaySet(objectCount: UInt8) -> [UInt8] {
            var pcs: [UInt8] = [0x07, 0x80, 0x04, 0x38, 0x10, 0x00, 0x01, 0x80, 0x00, 0x00, objectCount]
            if objectCount > 0 { pcs += [0x00, 0x00, 0x00, 0x00, 0x00, 100, 0x03, 0x84] }
            var result = segment(0x16, pcs)
            if objectCount > 0 {
                result += segment(0x14, [0x00, 0x00, 0x01, 235, 128, 128, 255])
                let rle: [UInt8] = [1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0]
                let length = rle.count + 4
                result += segment(0x15, [0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, UInt8(length), 0x00, 0x04, 0x00, 0x02] + rle)
            }
            return result + segment(0x80, [])
        }

        static func segment(_ type: UInt8, _ data: [UInt8]) -> [UInt8] {
            [type, UInt8(data.count >> 8), UInt8(data.count & 0xFF)] + data
        }
    }

    @Test("播放中读取内封 ASS 字幕", arguments: [3, 2]) func embeddedDuringPlayback(stream: Int) async throws {
        let session = PlaybackSession()
        defer { session.close() }
        let opened = try await session.open(source: FileByteSource(url: TestMedia.url("subs-srt-ass.mkv")))
        let info = try #require(opened.info.subtitleTracks.first { $0.id == stream })
        let track = SubtitleTrack(info: info, script: info.header.map(ASSScript.init(header:)) ?? .plainText)
        session.selectSubtitle(stream: stream, track: track)
        session.play()
        try await Task.sleep(for: .milliseconds(1500))

        let cue = try #require(track.active(at: 2).first, "第 2 秒应有字幕")
        guard case .text(let dialogue) = cue.content else {
            Issue.record("应为文本字幕")
            return
        }
        let text = dialogue.runs.map(\.text).joined()
        #expect(text == (stream == 3 ? "第一行字幕\n第二行" : "First line"))
        #expect(cue.start == 1 && cue.end == 3)
        #expect(track.active(at: 4).isEmpty)
    }

    @Test("MP4 Timed Text") func movText() async throws {
        let session = PlaybackSession()
        defer { session.close() }
        let opened = try await session.open(source: FileByteSource(url: TestMedia.url("subs-movtext.mp4")))
        let info = try #require(opened.info.subtitleTracks.first)
        let track = SubtitleTrack(info: info, script: .plainText)
        session.selectSubtitle(stream: info.id, track: track)
        session.play()
        try await Task.sleep(for: .milliseconds(1500))
        guard case .text(let dialogue) = try #require(track.active(at: 2).first).content else {
            Issue.record("应为文本字幕")
            return
        }
        #expect(dialogue.runs.map(\.text).joined() == "First line")
    }
}

@Suite struct SubtitleRenderingTests {
    @Test("底部字幕可被上移，定位字幕不受影响，同时出现的底部字幕不重叠") func layout() throws {
        let script = ASSScript(header: SubtitleParsingTests.assFile)
        let style = script.style(named: "Default")
        func cue(_ text: String, key: Int64) -> SubtitleCue {
            SubtitleCue(start: 0, end: 10, key: key, content: .text(ASSDialogue(text: text, style: style, script: script)))
        }
        let video = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = SubtitleRenderer().layout(
            cues: [cue("第一条", key: 1), cue("第二条", key: 2), cue(#"{\pos(960,100)\an8}定位"#, key: 3)],
            script: script, time: 1, video: video
        )
        #expect(layout.anchored.count == 2)
        #expect(layout.free.count == 1)
        let frames = layout.anchored.compactMap { item -> CGRect? in
            if case .text(let block) = item { block.frame } else { nil }
        }
        #expect(frames.count == 2 && !frames[0].intersects(frames[1]))
        // 第一条贴近底部边距，第二条在其上方
        #expect(abs(frames[0].maxY - (1080 - 40)) < 1)
        #expect(frames[1].maxY <= frames[0].minY + 0.5)
    }

    @Test("文本字幕绘制出可见像素") func drawsPixels() throws {
        let script = ASSScript.plainText
        let dialogue = ASSDialogue(text: "测试 Test", style: script.style(named: "Default"), script: script)
        let renderer = SubtitleRenderer()
        let layout = renderer.layout(
            cues: [SubtitleCue(start: 0, end: 1, key: 0, content: .text(dialogue))],
            script: script, time: 0.5, video: CGRect(x: 0, y: 0, width: 640, height: 360)
        )
        let context = try #require(CGContext(
            data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: 360)
        context.scaleBy(x: 1, y: -1)
        renderer.draw(layout.anchored, in: context)

        let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 640 * 360 * 4)
        var white = 0, minRow = Int.max
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i] > 200 && pixels[i + 3] > 200 {
            white += 1
            minRow = min(minRow, i / 4 / 640)
        }
        #expect(white > 200, "应绘制出白色文字")
        // 位图内存首行对应画面顶部；字幕应位于下半部分
        #expect(minRow > 180)
    }
}

@Suite struct SubtitleLayerTests {
    @Test("控制条显示时底部字幕上移") @MainActor func shiftsAboveControls() throws {
        let script = ASSScript(header: SubtitleParsingTests.assFile)
        let cue = SubtitleCue(start: 0, end: 10, key: 1, content: .text(ASSDialogue(text: "第一行\\N第二行", style: script.style(named: "Default"), script: script)))
        let info = SubtitleTrackInfo(id: 0, format: .ass, codec: "ass", language: "chi", title: nil, isDefault: true, isForced: false, isExternal: false)
        let layer = SubtitleLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        layer.layoutIfNeeded()
        layer.videoSize = CGSize(width: 1920, height: 1080)
        layer.bottomInset = 72
        layer.track = SubtitleTrack(info: info, script: script, cues: [cue])
        layer.update(time: 1)
        let anchored = try #require(layer.sublayers?.last)
        #expect(anchored.transform.m42 > 40, "实际平移 \(anchored.transform.m42)")
        // 平移后重新布局，平移量与位置都应保持
        layer.setNeedsLayout()
        layer.layoutIfNeeded()
        #expect(anchored.frame.minY > 40, "布局后图层位置 \(anchored.frame)")
    }
}
