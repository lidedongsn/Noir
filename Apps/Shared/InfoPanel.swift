import NoirEngine
import SwiftUI

/// 信息面板：展示片源参数与播放统计
struct InfoPanel: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        // 内容超出可用高度时（如 iPhone 横屏）改为滚动
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollIndicators(.hidden)
        }
        .frame(width: 400, alignment: .leading)
        .background(.black.opacity(0.72), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
        .foregroundStyle(.white)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let video = player.videoTrack {
                Section("视频") {
                    Row("编码", [video.codec.uppercased(), video.profile].compactMap { $0 }.joined(separator: " "))
                    Row("分辨率", "\(video.width)×\(video.height)" + (video.frameRate.map { String(format: " · %.3f fps", $0) } ?? ""))
                    Row("位深", video.bitDepth.map { "\($0)-bit" } ?? "—")
                    Row("动态范围", video.dynamicRange.rawValue + (video.dolbyVisionProfile.map { " Profile \($0)" } ?? ""))
                    Row("色域", video.colorPrimaries)
                    Row("传输函数", video.transfer)
                    Row("矩阵", video.matrix)
                    if let mastering = video.masteringDisplay { Row("母版亮度", mastering) }
                    if let light = video.contentLightLevel { Row("内容亮度", light) }
                    Row("解码", video.hardwareDecodable ? "VideoToolbox 硬件解码" : "本机无此编码的硬件解码器")
                }
            }
            if let audio = player.audioTrack {
                Section("音频") {
                    Row("格式", [audio.profile ?? audio.codec, audio.channelLayout, "\(audio.sampleRate / 1000) kHz"].joined(separator: " · "))
                    Row("路径", player.stats.audioRoute?.rawValue ?? audio.route.rawValue)
                    if let channels = player.stats.outputChannels { Row("输出", "\(channels) 声道") }
                }
            }
            if let subtitle = player.subtitleTrack {
                Section("字幕") {
                    Row("轨道", subtitle.displayName)
                }
            }
            Section("播放") {
                Row("缓冲", String(format: "视频 %.1f s · 音频 %.1f s", player.stats.videoBuffered, player.stats.audioBuffered))
                Row("渲染器", "视频 \(player.stats.videoRendererStatus) · 音频 \(player.stats.audioRendererStatus)")
                if let info = player.info {
                    Row("容器", info.container.components(separatedBy: ",").first ?? info.container)
                    if info.bitRate > 0 { Row("码率", String(format: "%.1f Mbps", Double(info.bitRate) / 1_000_000)) }
                }
                if let error = player.stats.lastError { Row("错误", error) }
                if let error = player.subtitleError { Row("字幕错误", error) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            content
        }
    }
}

private struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}
