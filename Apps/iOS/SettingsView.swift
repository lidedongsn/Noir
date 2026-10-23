import NoirEngine
import SwiftUI

/// 设置：联网规则、缓存、WebDAV 服务器与关于
struct SettingsView: View {
    @Environment(NetworkSources.self) private var network
    @Environment(\.dismiss) private var dismiss
    @State private var usage: Int64?
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var network = network
        NavigationStack {
            Form {
                Section {
                    Toggle("用蜂窝网络播放", isOn: $network.cellularPlayback)
                    Toggle("用蜂窝网络下载", isOn: $network.cellularDownload)
                } header: {
                    Text("网络")
                } footer: {
                    Text("关闭时只在 Wi-Fi 下联网，个人热点视为蜂窝网络。用蜂窝网络播放时只往后缓存约 5 分钟。封面只在 Wi-Fi 下截取。")
                }

                Section {
                    Picker("缓存上限", selection: $network.cacheLimit) {
                        ForEach(NetworkSources.cacheLimitChoices, id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    LabeledContent("已使用", value: usage.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
                    Button("清除缓存", role: .destructive) { confirmingClear = true }
                        .disabled(usage == 0)
                } header: {
                    Text("缓存")
                } footer: {
                    Text("播放网络影片时边看边缓存的数据，超出上限时先删除最久没看的。始终为手机保留至少 10 GB 空闲空间。")
                }

                Section("WebDAV 服务器") {
                    ForEach(network.servers) { server in
                        NavigationLink {
                            ServerEditor(server: server)
                        } label: {
                            LabeledContent(server.name, value: server.url.host() ?? "")
                        }
                    }
                    NavigationLink("添加服务器…") { ServerEditor(server: nil) }
                }

                Section {
                    NavigationLink("关于墨影") { AboutView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("清除缓存？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清除缓存", role: .destructive) {
                    network.clearCache()
                    refreshUsage()
                }
            } message: {
                Text("已下载的影片与播放进度不受影响。")
            }
            .task(id: network.cacheLimit) { refreshUsage() }
        }
    }

    private func refreshUsage() {
        let root = network.streamRoot
        Task {
            usage = await Task.detached(priority: .utility) { BlockCache.usage(root: root) }.value
        }
    }
}

/// 添加或编辑 WebDAV 服务器：保存前测试连接，密码存钥匙串
struct ServerEditor: View {
    @Environment(NetworkSources.self) private var network
    @Environment(\.dismiss) private var dismiss
    let server: NetworkSources.Server?

    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var failure: String?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name, prompt: Text("例如：家里的 NAS"))
                TextField("地址", text: $address, prompt: Text("http://192.168.1.10:5244/dav"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("阿里云盘：开通三方应用权益包后，在阿里云盘 App「我的 › 三方应用 › WebDAV」创建账号，填入这里的地址、用户名和密码。")
            }
            Section {
                TextField("用户名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                    .textContentType(.password)
            }
            if server != nil {
                Section {
                    Button("删除服务器", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(server == nil ? "添加服务器" : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if testing {
                    ProgressView()
                } else {
                    Button("保存") { Task { await save(force: false) } }
                        .disabled(normalizedURL == nil)
                }
            }
        }
        .alert("无法连接", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("仍然保存") { Task { await save(force: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog("删除服务器？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let server { network.remove(server) }
                dismiss()
            }
        } message: {
            Text("这台服务器的缓存、封面与播放进度会一并删除，服务器上的文件不受影响。")
        }
        .onAppear {
            guard let server, name.isEmpty else { return }
            name = server.name
            address = server.url.absoluteString
            username = server.username
            password = Keychain.password(for: server.id) ?? ""
        }
    }

    /// 补全协议与结尾的斜杠
    private var normalizedURL: URL? {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        if !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), url.host() != nil, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    private func save(force: Bool) async {
        guard let url = normalizedURL else { return }
        let edited = NetworkSources.Server(
            id: server?.id ?? UUID(),
            name: name.isEmpty ? url.host() ?? "WebDAV" : name,
            url: url,
            username: username
        )
        if !force {
            testing = true
            defer { testing = false }
            do {
                try await NetworkSources.test(edited, password: password, allowsCellular: network.cellularPlayback)
            } catch {
                failure = "\(error)"
                return
            }
        }
        network.save(edited, password: password)
        dismiss()
    }
}
