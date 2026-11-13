import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShinAppleKit
import ShinAppServices

// MARK: - 卡片容器与通用标题组件

struct AudioLinkSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct AudioLinkSectionHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            trailing()
        }
    }
}

struct AudioLinkFieldColumn: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 第一段：链接输入卡片

struct AudioLinkURLSection: View {
    @ObservedObject var model: AudioLinkImportModel
    @FocusState private var isURLFocused: Bool

    var body: some View {
        AudioLinkSectionCard {
            AudioLinkSectionHeader("音频 / 视频链接", systemImage: "link") {
                if let inspection = model.urlInspection {
                    Text(inspection.platform.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Button("粘贴链接") { model.pasteAndNormalizeFromClipboard() }
                    .controlSize(.regular)
                if !model.urlString.isEmpty {
                    Button("清空") { model.clearURLInput() }
                        .controlSize(.regular)
                }
            }

            TextField("https://www.bilibili.com/video/...", text: $model.urlString)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.system(size: 14))
                .focused($isURLFocused)
                .onSubmit { model.applyNormalizedURLIfNeeded() }
                .onChange(of: isURLFocused) { _, focused in
                    if !focused { model.applyNormalizedURLIfNeeded() }
                }

            if let warning = model.urlInspection?.formatWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = model.autoCleanedNotice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "支持格式：B 站 https://www.bilibili.com/video/BV...（可带 ?p=1） · "
                    + "YouTube https://www.youtube.com/watch?v=...（粘贴带追踪参数将自动裁剪）"
            )
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 第二段：歌曲标签与封面

struct AudioLinkMetadataSection: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        AudioLinkSectionCard {
            AudioLinkSectionHeader("歌曲标签与封面", systemImage: "music.note.list", subtitle: "留空保留源信息")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    AudioLinkFieldColumn(label: "歌名", placeholder: "留空用源标题", text: $model.title)
                    AudioLinkFieldColumn(label: "歌手", placeholder: "留空用源作者", text: $model.artist)
                }
                GridRow {
                    AudioLinkFieldColumn(label: "专辑", placeholder: "可选", text: $model.album)
                    AudioLinkFieldColumn(label: "流派", placeholder: "可选", text: $model.genre)
                }
            }
            HStack(spacing: 22) {
                Toggle("嵌入视频封面", isOn: $model.embedThumbnail)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .help("将视频封面嵌入为歌曲封面")
                Toggle("保留源站标签", isOn: $model.includeSourceMetadata)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                    .help("保留源站默认简介与标签（--add-metadata）")
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - 第三段：下载配置与保存

struct AudioLinkOptionsSection: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        AudioLinkSectionCard {
            AudioLinkSectionHeader("下载配置与保存", systemImage: "slider.horizontal.3", subtitle: "yt-dlp")
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("音频质量") {
                    Picker("音频质量", selection: $model.audioQuality) {
                        ForEach(AudioQualityOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.regular)
                    .font(.system(size: 13))
                    .frame(maxWidth: 320, alignment: .leading)
                }
                labeledRow("片段裁剪") {
                    HStack(spacing: 8) {
                        TextField("00:05", text: $model.trimStart)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .font(.system(size: 13))
                            .frame(width: 100)
                        Text("→").font(.system(size: 13)).foregroundStyle(.secondary)
                        TextField("03:45", text: $model.trimEnd)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .font(.system(size: 13))
                            .frame(width: 100)
                        Text("留空不裁，支持 mm:ss 或 hh:mm:ss")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
                labeledRow("网络代理") {
                    TextField("留空直连，如 127.0.0.1:7890", text: $model.proxy)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .font(.system(size: 13))
                        .frame(maxWidth: 420)
                }
                labeledRow("本地副本") {
                    HStack(spacing: 12) {
                        Toggle("在本地同时保留 .m4a 副本", isOn: $model.keepLocalCopy)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13))
                            .fixedSize()
                        Text(model.localCopyDirectory?.path ?? "~/Desktop")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .opacity(model.keepLocalCopy ? 1 : 0.45)
                        Button("选择文件夹…") { chooseLocalCopyDirectory() }
                            .controlSize(.regular)
                            .disabled(!model.keepLocalCopy)
                    }
                }
            }
        }
    }

    private func labeledRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            control()
        }
    }

    private func chooseLocalCopyDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择本地 .m4a 副本的保存文件夹"
        if panel.runModal() == .OK, let url = panel.url { model.localCopyDirectory = url }
    }
}

// MARK: - 第四段：站点访问凭据

struct AudioLinkCookieSection: View {
    @ObservedObject var model: AudioLinkImportModel
    @State private var selectedBrowser: AudioCookieBrowser = .chrome
    @State private var selectedCookiesFile: URL?

    private enum CookieKind: String, CaseIterable, Identifiable {
        case none = "不使用"
        case browser = "浏览器读取"
        case file = "文件"
        var id: String { rawValue }
    }

    private var cookieKindBinding: Binding<CookieKind> {
        Binding(
            get: {
                switch model.cookieMode {
                case .none: return .none
                case .browser: return .browser
                case .file: return .file
                }
            },
            set: { next in
                switch next {
                case .none: model.cookieMode = .none
                case .browser: model.cookieMode = .browser(selectedBrowser)
                case .file: model.cookieMode = .file(selectedCookiesFile)
                }
            }
        )
    }

    var body: some View {
        AudioLinkSectionCard {
            AudioLinkSectionHeader("站点访问凭据 (Cookies)", systemImage: "key.fill", subtitle: "可选")
            VStack(alignment: .leading, spacing: 12) {
                Picker("Cookies 来源", selection: cookieKindBinding) {
                    ForEach(CookieKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.regular)
                .frame(maxWidth: 340, alignment: .leading)

                cookieDetailSlot
            }
            Text("仅向 yt-dlp 透传来源参数，本应用不读取、展示或持久化 Cookies 内容。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            switch model.cookieMode {
            case .none: break
            case .browser(let browser): selectedBrowser = browser
            case .file(let url): selectedCookiesFile = url
            }
        }
    }

    private var cookieDetailSlot: some View {
        ZStack(alignment: .leading) {
            switch model.cookieMode {
            case .none:
                Text("公开内容无需凭据；需大会员音轨或登录可见时请切至浏览器读取")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .browser(let current):
                HStack(spacing: 10) {
                    ForEach(AudioCookieBrowser.allCases) { browser in
                        browserPill(browser, isSelected: browser == current)
                    }
                }
            case .file(let url):
                HStack(spacing: 10) {
                    Text(url?.path ?? "未选择 Netscape cookies.txt")
                        .font(.system(size: 12.5))
                        .foregroundStyle(url == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择文件…") { chooseCookiesFile() }
                        .controlSize(.regular)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func browserPill(_ browser: AudioCookieBrowser, isSelected: Bool) -> some View {
        Button {
            selectedBrowser = browser
            model.cookieMode = .browser(browser)
        } label: {
            Text(browser.shortName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        isSelected ? Color.clear : Color.primary.opacity(0.16),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chooseCookiesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, .data]
        panel.message = "选择 Netscape 格式的 cookies.txt 文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedCookiesFile = url
        model.cookieMode = .file(url)
    }
}
