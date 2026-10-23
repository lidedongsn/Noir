import SwiftUI

/// 片库首页：继续观看、最近打开与墨影文件夹，影片以截图封面的卡片展示
struct LibraryView: View {
    @Environment(Library.self) private var library
    /// 播放影片；fromStart 为 true 时忽略续播位置
    let play: (_ url: URL, _ fromStart: Bool) -> Void
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Header { importing = true }

                if let item = library.continueWatching {
                    HeroCard(item: item) { play(item.url, false) }
                        .contextMenu { menu(for: item) }
                }
                if !library.recent.isEmpty {
                    Shelf(title: "最近打开", items: library.recent, menu: menu, play: play)
                }
                if !library.local.isEmpty {
                    Shelf(title: "墨影文件夹", items: library.local, menu: menu, play: play)
                }
                if library.recent.isEmpty, library.local.isEmpty {
                    EmptyState { importing = true }
                        .padding(.top, 80)
                } else {
                    Text("把影片放进「文件」App 的「我的 iPhone › 墨影」，会自动出现在这里")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .refreshable { library.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: VideoFiles.contentTypes) { result in
            if case .success(let url) = result { play(url, false) }
        }
    }

    @ViewBuilder
    private func menu(for item: Library.Item) -> some View {
        Button("播放", systemImage: "play.fill") { play(item.url, false) }
        if library.progress[item.key] != nil {
            Button("从头播放", systemImage: "backward.end.fill") { play(item.url, true) }
        }
        Divider()
        if library.local.contains(item) {
            Button("删除影片", systemImage: "trash", role: .destructive) { library.delete(item) }
        } else {
            Button("从列表移除", systemImage: "minus.circle") { library.forget(item) }
        }
    }
}

// MARK: - 顶部

private struct Header: View {
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("墨影")
                    .font(.system(size: 34, weight: .light, design: .serif))
                    .foregroundStyle(.white.opacity(0.95))
                Text("NOIR")
                    .font(.system(size: 10, weight: .light))
                    .tracking(7)
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button(action: open) {
                Image(systemName: "folder")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("打开文件")
        }
        .padding(.top, 12)
    }
}

// MARK: - 继续观看

private struct HeroCard: View {
    @Environment(Library.self) private var library
    let item: Library.Item
    let action: () -> Void

    var body: some View {
        let progress = library.progress[item.key]
        Button(action: action) {
            Thumbnail(item: item, width: 960, resume: true)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("继续观看")
                            .font(.caption.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(item.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let progress {
                            HStack(spacing: 10) {
                                ProgressLine(fraction: progress.fraction)
                                    .frame(maxWidth: 160)
                                Text("剩余 \(formatTime(progress.remaining))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                }
                .overlay(alignment: .center) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                }
                .clipShape(.rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(CardStyle())
    }
}

// MARK: - 影片列表

private struct Shelf<Menu: View>: View {
    let title: String
    let items: [Library.Item]
    @ViewBuilder let menu: (Library.Item) -> Menu
    let play: (URL, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14, alignment: .top)], spacing: 20) {
                ForEach(items) { item in
                    FilmCard(item: item) { play(item.url, false) }
                        .contextMenu { menu(item) }
                }
            }
        }
    }
}

private struct FilmCard: View {
    @Environment(Library.self) private var library
    let item: Library.Item
    let action: () -> Void

    var body: some View {
        let details = library.details[item.key]
        let progress = library.progress[item.key]
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // 看过的影片显示上次停下时的画面
                Thumbnail(item: item, width: 280, resume: progress != nil)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        if let progress {
                            ProgressLine(fraction: progress.fraction)
                                .padding(8)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.white.opacity(0.92))
                    Text(subtitle(details))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(CardStyle())
    }

    /// 例如「2:15:30 · 4K · HDR10 · 58.2 GB」
    private func subtitle(_ details: Library.Details?) -> String {
        var parts: [String] = []
        if let duration = details?.duration { parts.append(formatTime(duration)) }
        parts += details?.tags ?? []
        parts.append(item.size.formatted(.byteCount(style: .file)))
        return parts.joined(separator: " · ")
    }
}

// MARK: - 组件

/// 封面图：出现在屏幕上时才读取；尚未生成时显示占位
private struct Thumbnail: View {
    @Environment(Library.self) private var library
    @Environment(\.displayScale) private var scale
    let item: Library.Item
    /// 最大显示宽度（点），按此解码
    let width: CGFloat
    /// 优先显示上次看到的画面（有播放进度时）
    var resume = false
    @State private var image: UIImage?

    var body: some View {
        let details = library.details[item.key]
        let loading = details == nil && !library.failed.contains(item.key)
        Rectangle()
            .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if loading {
                    ProgressView().tint(.white.opacity(0.5))
                } else {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .animation(.easeOut(duration: 0.3), value: image != nil)
            .clipped()
            // 封面或续播封面生成完成后重新读取
            .task(id: ReloadKey(key: item.key, hasImage: details?.hasImage, resume: resume ? library.resumeStamps[item.key] : nil)) {
                let pixels = min(Int(width * scale), 960)
                if resume, let frame = await library.resumeThumbnail(for: item, maxPixels: pixels) {
                    image = frame
                } else if details?.hasImage == true {
                    image = await library.thumbnail(for: item, maxPixels: pixels)
                }
            }
    }

    private struct ReloadKey: Equatable {
        /// 「继续观看」换成另一部影片时同一视图需重新读取
        var key: String
        var hasImage: Bool?
        var resume: Date?
    }
}

private struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.25))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(.white).frame(width: geo.size.width * fraction)
                }
            }
    }
}

/// 卡片按下时轻微缩小
private struct CardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

private struct EmptyState: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("还没有影片")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
            Text("从「文件」中打开影片，\n或把影片放进「我的 iPhone › 墨影」文件夹")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
            Button("打开文件", action: open)
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}
