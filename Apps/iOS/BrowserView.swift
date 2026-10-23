import NoirEngine
import SwiftUI

/// 浏览网络文件夹的导航目标
struct Browse: Hashable {
    var server: UUID
    var folder: URL
    var title: String
}

/// 网络文件夹：子文件夹在上，影片以封面卡片排列在下
struct BrowserView: View {
    @Environment(Library.self) private var library
    @Environment(NetworkSources.self) private var network
    let server: UUID
    let folder: URL
    let title: String
    let play: (Library.Item, Bool) -> Void

    @State private var entries: [WebDAVEntry]?
    @State private var error: String?

    private var folders: [WebDAVEntry] { entries?.filter(\.isDirectory) ?? [] }
    private var videos: [Library.Item] {
        (entries ?? [])
            .filter { !$0.isDirectory && VideoFiles.extensions.contains(($0.name as NSString).pathExtension.lowercased()) }
            .map { Library.Item(remote: $0, server: server) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !network.canStream {
                    Notice(symbol: "wifi.slash", title: "仅在 Wi-Fi 下可用", message: "可在设置中允许使用蜂窝网络")
                } else if let error {
                    Notice(symbol: "exclamationmark.triangle", title: "无法连接", message: error)
                } else if entries == nil {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 80)
                } else if folders.isEmpty, videos.isEmpty {
                    Notice(symbol: "folder", title: "没有影片", message: "这个文件夹里没有可播放的影片")
                }
                if !folders.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(folders) { entry in
                            NavigationLink(value: Browse(server: server, folder: entry.url, title: entry.name)) {
                                FolderRow(name: entry.name)
                            }
                            if entry != folders.last {
                                Divider().overlay(.white.opacity(0.06)).padding(.leading, 52)
                            }
                        }
                    }
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                }
                if !videos.isEmpty {
                    Shelf(title: "影片", items: videos, menu: menu, play: play)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .refreshable { await load() }
        .task(id: network.canStream) { await load() }
    }

    private func load() async {
        guard network.canStream, let client = network.client(for: server) else { return }
        do {
            entries = try await client.list(folder)
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }

    @ViewBuilder
    private func menu(for item: Library.Item) -> some View {
        Button("播放", systemImage: "play.fill") { play(item, false) }
        if library.progress[item.key] != nil {
            Button("从头播放", systemImage: "backward.end.fill") { play(item, true) }
        }
    }
}

private struct FolderRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 24)
            Text(name)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

private struct Notice: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}
