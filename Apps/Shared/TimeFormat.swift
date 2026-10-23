import Foundation

/// 格式化时间；负值表示剩余时间（如 -1:23）
func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let sign = seconds < -0.5 ? "-" : ""
    let s = Int(abs(seconds).rounded(.down))
    return sign + (s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60))
}
