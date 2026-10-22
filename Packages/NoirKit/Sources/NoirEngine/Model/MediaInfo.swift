import Foundation

/// 片源的媒体信息
public struct MediaInfo: Sendable {
    public var container: String
    public var duration: Double?
    public var bitRate: Int64
    public var videoTracks: [VideoTrackInfo]
    public var audioTracks: [AudioTrackInfo]
    /// 内封字幕轨道
    public var subtitleTracks: [SubtitleTrackInfo]
}

public enum DynamicRange: String, Sendable {
    case sdr = "SDR"
    case hdr10 = "HDR10"
    case hlg = "HLG"
    case dolbyVision = "Dolby Vision"
}

public struct VideoTrackInfo: Sendable, Identifiable {
    /// FFmpeg 的流序号
    public var id: Int
    public var codec: String
    public var profile: String?
    public var width: Int
    public var height: Int
    /// 像素宽高比（SAR），非方形像素的片源（如部分 DVD、变形宽银幕）不为 1
    public var pixelAspectRatio: Double
    public var frameRate: Double?
    public var bitDepth: Int?
    public var dynamicRange: DynamicRange
    public var colorPrimaries: String
    public var transfer: String
    public var matrix: String
    public var masteringDisplay: String?
    public var contentLightLevel: String?
    public var dolbyVisionProfile: Int?
    /// 本机是否有该编码的硬件解码器
    public var hardwareDecodable: Bool

    /// 画面实际显示的宽高（考虑像素宽高比）
    public var displaySize: CGSize {
        CGSize(width: Double(width) * pixelAspectRatio, height: Double(height))
    }
}

/// 音频的处理路径
public enum AudioRoute: String, Sendable {
    /// 压缩码流直接提交给系统渲染器（AC3 / E-AC3，可保留杜比全景声）
    case system = "系统解码"
    /// 由 AudioToolbox 解码为 LPCM
    case audioToolbox = "AudioToolbox → LPCM"
    /// 系统不支持的格式，由 FFmpeg 解码为 LPCM
    case ffmpeg = "FFmpeg 软解 → LPCM"
    /// 源为 PCM，直接提交
    case pcm = "LPCM 直送"
    case unsupported = "不支持"
}

public struct AudioTrackInfo: Sendable, Identifiable {
    public var id: Int
    public var codec: String
    public var profile: String?
    public var language: String?
    public var title: String?
    public var channels: Int
    public var channelLayout: String
    public var sampleRate: Int
    public var isDefault: Bool
    public var route: AudioRoute

    /// 用于界面展示的音轨名称
    public var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, language != "und" { parts.append(language.uppercased()) }
        parts.append(profile ?? codec)
        parts.append(channelLayout)
        return parts.joined(separator: " · ")
    }
}

/// 播放过程中的运行时统计
public struct PlaybackStats: Sendable {
    /// 视频已送入渲染器、尚未播放的时长（秒）
    public var videoBuffered: Double = 0
    public var audioBuffered: Double = 0
    public var videoRendererStatus: String = "—"
    public var audioRendererStatus: String = "—"
    public var outputChannels: Int?
    public var audioRoute: AudioRoute?
    public var lastError: String?
}
