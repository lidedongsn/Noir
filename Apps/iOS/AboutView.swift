import NoirEngine
import SwiftUI

/// 关于：版本、源代码与开源许可（含 FFmpeg 的 LGPL 声明）
struct AboutView: View {
    private static let repository = URL(string: "https://github.com/lidedongsn/Noir")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    if let icon = UIImage(named: "AppIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 72, height: 72)
                            .clipShape(.rect(cornerRadius: 16))
                    }
                    Text("墨影 Noir")
                        .font(.title3.weight(.semibold))
                    Text("版本 \(Self.appVersion)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: Self.repository) {
                    LabeledContent("源代码", value: "GitHub")
                }
            }

            Section {
                NavigationLink {
                    LicenseText(title: "墨影", resource: "LICENSE", extension: nil)
                } label: {
                    LabeledContent("墨影", value: "MIT")
                }
                NavigationLink {
                    LicenseText(title: "FFmpeg", resource: "FFmpeg-LGPL-2.1", extension: "txt")
                } label: {
                    LabeledContent("FFmpeg \(FFmpegLibrary.version)", value: "LGPL 2.1+")
                }
            } header: {
                Text("开源许可")
            } footer: {
                Text(Self.ffmpegNotice)
            }
        }
        .navigationTitle("关于墨影")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// LGPL 要求说明所用的库、许可与获取源码的方式，并允许用户替换修改后的库重新链接
    private static var ffmpegNotice: String {
        """
        本应用使用了 FFmpeg（\(FFmpegLibrary.license)），以静态库形式链接，未启用 GPL 与 nonfree 组件。\
        FFmpeg 源码：https://ffmpeg.org/releases/ffmpeg-\(FFmpegLibrary.version).tar.xz。\
        墨影的全部源代码与 FFmpeg 构建脚本（scripts/build-ffmpeg.sh）公开在源代码仓库中，\
        你可以替换为修改后的 FFmpeg 重新编译本应用。
        """
    }
}

/// 许可证全文
private struct LicenseText: View {
    let title: String
    let resource: String
    let `extension`: String?

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        Bundle.main.url(forResource: resource, withExtension: `extension`)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}
