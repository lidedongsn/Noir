import SwiftUI

/// 片库首页：继续观看、最近打开、网络与墨影文件夹，影片以截图封面的卡片展示
struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(NetworkSources.self) private var network
    /// 播放影片；fromStart 为 true 时忽略续播位置
    let play: (_ item: Library.Item, _ fromStart: Bool) -> Void
    /// 播放从「文件」中选择的影片
    let openFile: (URL) -> Void
    @State private var importing = false
    @State private var showsSettings = false
    @State private var addingServer = false
    /// 内容已向上滚动，固定在顶部的标题栏显示背景
    @State private var scrolled = false
    /// 正在浏览的网络文件夹
    @State private var path: [Browse] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Browse.self) { browse in
                    BrowserView(server: browse.server, folder: browse.folder, title: browse.title, play: play)
                }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $addingServer) {
            NavigationStack {
                ServerEditor(server: nil)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { addingServer = false }
                        }
                    }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let item = library.continueWatching {
                    HeroCard(item: item) { play(item, false) }
                        .contextMenu { menu(for: item) }
                }
                if !library.recent.isEmpty {
                    Shelf(title: "最近打开", items: library.recent, menu: menu, play: play)
                }
                if !library.local.isEmpty {
                    Shelf(title: "墨影文件夹", items: library.local, menu: menu, play: play)
                }
                if library.recent.isEmpty, library.local.isEmpty, network.servers.isEmpty {
                    EmptyState(open: { importing = true }, addServer: { addingServer = true })
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
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // 标题与按钮固定在顶部，内容在下方滚动；滚动后淡入磨砂背景
        .safeAreaInset(edge: .top, spacing: 0) {
            Header(browse: { path = [$0] }, addServer: { addingServer = true },
                   open: { importing = true }, settings: { showsSettings = true })
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.55))
                        .overlay(alignment: .bottom) { Divider().overlay(.white.opacity(0.08)) }
                        .ignoresSafeArea(edges: .top)
                        .opacity(scrolled ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.2), value: scrolled)
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 2 } action: { _, value in
            scrolled = value
        }
        .background(Color.black.ignoresSafeArea())
        .refreshable { library.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: VideoFiles.contentTypes) { result in
            if case .success(let url) = result { openFile(url) }
        }
    }

    @ViewBuilder
    private func menu(for item: Library.Item) -> some View {
        Button("播放", systemImage: "play.fill") { play(item, false) }
        if library.progress[item.key] != nil {
            Button("从头播放", systemImage: "backward.end.fill") { play(item, true) }
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
    let browse: (Browse) -> Void
    let addServer: () -> Void
    let open: () -> Void
    let settings: () -> Void

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
            HStack(spacing: 10) {
                NetworkMenu(browse: browse, addServer: addServer)
                CircleButton("folder", label: "打开文件", action: open)
                CircleButton("gearshape", label: "设置", action: settings)
            }
        }
        .padding(.top, 12)
    }
}

/// 网络片源：列出 WebDAV 服务器，选择后进入浏览
private struct NetworkMenu: View {
    @Environment(NetworkSources.self) private var network
    let browse: (Browse) -> Void
    let addServer: () -> Void

    var body: some View {
        Menu {
            ForEach(network.servers) { server in
                Button {
                    browse(Browse(server: server.id, folder: server.url, title: server.name))
                } label: {
                    Text(server.name)
                    Text(network.canStream ? server.url.host() ?? server.url.absoluteString : "仅在 Wi-Fi 下可用")
                }
            }
            if !network.servers.isEmpty { Divider() }
            Button("添加服务器…", systemImage: "plus", action: addServer)
        } label: {
            CircleIcon(symbol: "externaldrive.connected.to.line.below")
        }
        .accessibilityLabel("网络")
    }
}

private struct CircleIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.1), in: Circle())
    }
}

private struct CircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            CircleIcon(symbol: symbol)
        }
        .accessibilityLabel(label)
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

struct Shelf<Menu: View>: View {
    let title: String
    let items: [Library.Item]
    @ViewBuilder let menu: (Library.Item) -> Menu
    let play: (Library.Item, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14, alignment: .top)], spacing: 20) {
                ForEach(items) { item in
                    FilmCard(item: item) { play(item, false) }
                        .contextMenu { menu(item) }
                }
            }
        }
    }
}

struct FilmCard: View {
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
                    .overlay(alignment: .topTrailing) {
                        if item.isRemote {
                            Image(systemName: "network")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(5)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(6)
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
        // 浏览网络文件夹时，出现在屏幕上才读取或生成封面
        .task(id: item.key) { library.requestDetails(for: item) }
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
    @Environment(NetworkSources.self) private var network
    @Environment(\.displayScale) private var scale
    let item: Library.Item
    /// 最大显示宽度（点），按此解码
    let width: CGFloat
    /// 优先显示上次看到的画面（有播放进度时）
    var resume = false
    @State private var image: UIImage?

    var body: some View {
        let details = library.details[item.key]
        // 网络影片的封面只在 Wi-Fi 下生成，其他网络下显示占位图
        let loading = details == nil && !library.failed.contains(item.key) && (!item.isRemote || network.onWiFi)
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
struct CardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

private struct EmptyState: View {
    let open: () -> Void
    let addServer: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("还没有影片")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
            Text("从「文件」中打开影片，把影片放进「我的 iPhone › 墨影」文件夹，\n或添加 WebDAV 服务器（如阿里云盘官方 WebDAV、NAS）")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 12) {
                Button("打开文件", action: open)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                Button("添加服务器", action: addServer)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}
