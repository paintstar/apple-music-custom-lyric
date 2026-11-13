import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShinAppleKit
import ShinAppServices

// MARK: - 卡片容器与字段组件

struct AudioLinkSectionCard<Content: View>: View {
    var fillHeight: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
            if fillHeight { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct AudioLinkFieldColumn: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 前置工具安装引导卡片

struct AudioToolInstallGuideCard: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        if model.isCheckingTools && model.toolAvailability == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检测本机 yt-dlp 与 ffmpeg 工具……").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        } else if let tools = model.toolAvailability, !tools.isReady {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("需要先安装本机命令行依赖工具", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    Spacer()
                    Button("安装完成后重新检测") { model.startToolCheck() }
                        .controlSize(.small).disabled(model.isCheckingTools)
                }
                HStack(spacing: 12) {
                    toolBadge(name: "yt-dlp", role: "解析链接并提取音频", url: tools.ytdlpURL)
                    toolBadge(name: "ffmpeg", role: "封装 M4A 与写入封面标签", url: tools.ffmpegURL)
                }
                if let command = model.installCommand {
                    HStack(spacing: 8) {
                        Text(command).font(.caption.monospaced()).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Button(model.copiedInstallCommand ? "已复制" : "复制命令") { model.copyInstallCommand() }
                            .controlSize(.small)
                        Button("打开终端") { model.openTerminalApp() }.controlSize(.small)
                    }
                }
                Text("已扫描路径：/opt/homebrew/bin、/usr/local/bin、~/.local/bin 及环境变量 PATH")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.25), lineWidth: 1))
        }
    }

    private func toolBadge(name: String, role: String, url: URL?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: url != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(url != nil ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption.weight(.semibold))
                Text(url != nil ? "已就绪" : "未检测到 · \(role)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 第一段：链接输入卡片

struct AudioLinkURLSection: View {
    @ObservedObject var model: AudioLinkImportModel
    @FocusState private var isURLFocused: Bool

    var body: some View {
        AudioLinkSectionCard {
            HStack(spacing: 8) {
                Text("音频 / 视频链接").font(.callout.weight(.medium))
                if let inspection = model.urlInspection {
                    Text(inspection.platform.displayName)
                        .font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer()
                Button("粘贴链接") { model.pasteAndNormalizeFromClipboard() }.controlSize(.small)
                if !model.urlString.isEmpty {
                    Button("清空") { model.clearURLInput() }.controlSize(.small)
                }
            }
            TextField("https://www.bilibili.com/video/...", text: $model.urlString)
                .textFieldStyle(.roundedBorder).focused($isURLFocused)
                .onSubmit { model.applyNormalizedURLIfNeeded() }
                .onChange(of: isURLFocused) { _, focused in
                    if !focused { model.applyNormalizedURLIfNeeded() }
                }
            if let warning = model.urlInspection?.formatWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let notice = model.autoCleanedNotice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            Text(
                "支持格式：B 站 https://www.bilibili.com/video/BV...（可带 ?p=1） · "
                    + "YouTube https://www.youtube.com/watch?v=...（粘贴带追踪参数将自动裁剪）"
            )
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 第二段：左栏（歌曲标签与封面）与右栏（下载配置与保存）

struct AudioLinkMetadataColumn: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        AudioLinkSectionCard(fillHeight: true) {
            Text("歌曲标签与封面").font(.callout.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    AudioLinkFieldColumn(label: "歌名", placeholder: "留空用源标题", text: $model.title)
                    AudioLinkFieldColumn(label: "歌手", placeholder: "留空用源作者", text: $model.artist)
                }
                GridRow {
                    AudioLinkFieldColumn(label: "专辑", placeholder: "可选", text: $model.album)
                    AudioLinkFieldColumn(label: "流派", placeholder: "可选", text: $model.genre)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("嵌入视频封面为歌曲封面", isOn: $model.embedThumbnail)
                    .toggleStyle(.checkbox).font(.caption)
                Toggle("保留源站默认标签（--add-metadata）", isOn: $model.includeSourceMetadata)
                    .toggleStyle(.checkbox).font(.caption)
            }
            .padding(.top, 2)
        }
    }
}

struct AudioLinkOptionsColumn: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        AudioLinkSectionCard(fillHeight: true) {
            Text("下载配置与保存（yt-dlp）").font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: 8) {
                labeledRow("音频质量") {
                    Picker("音频质量", selection: $model.audioQuality) {
                        ForEach(AudioQualityOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                labeledRow("片段裁剪") {
                    HStack(spacing: 5) {
                        TextField("00:05", text: $model.trimStart)
                            .textFieldStyle(.roundedBorder).frame(width: 66)
                        Text("→").font(.caption).foregroundStyle(.secondary)
                        TextField("03:45", text: $model.trimEnd)
                            .textFieldStyle(.roundedBorder).frame(width: 66)
                        Text("留空不裁").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                labeledRow("网络代理") {
                    TextField("留空直连，如 127.0.0.1:7890", text: $model.proxy)
                        .textFieldStyle(.roundedBorder)
                }
                labeledRow("本地副本") {
                    HStack(spacing: 6) {
                        Toggle("保留 .m4a", isOn: $model.keepLocalCopy)
                            .toggleStyle(.checkbox).font(.caption)
                        Spacer(minLength: 4)
                        Text(model.localCopyDirectory?.lastPathComponent ?? "桌面")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .opacity(model.keepLocalCopy ? 1 : 0.45)
                        Button("更改…") { chooseLocalCopyDirectory() }
                            .controlSize(.small).disabled(!model.keepLocalCopy)
                    }
                }
            }
        }
    }

    private func labeledRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
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

// MARK: - 第三段：站点访问凭据（固定高度不跳动）

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
            Text("站点访问凭据 (Cookies)").font(.callout.weight(.medium))
            HStack(spacing: 12) {
                Picker("Cookies 来源", selection: cookieKindBinding) {
                    ForEach(CookieKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 236)

                cookieDetailSlot
            }
            Text("仅向 yt-dlp 透传来源参数，本应用不读取、展示或持久化 Cookies 内容。")
                .font(.caption2).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            case .browser(let current):
                HStack(spacing: 6) {
                    ForEach(AudioCookieBrowser.allCases) { browser in
                        browserPill(browser, isSelected: browser == current)
                    }
                }
            case .file(let url):
                HStack(spacing: 8) {
                    Text(url?.lastPathComponent ?? "未选择 Netscape cookies.txt")
                        .font(.caption).foregroundStyle(url == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择文件…") { chooseCookiesFile() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func browserPill(_ browser: AudioCookieBrowser, isSelected: Bool) -> some View {
        Button {
            selectedBrowser = browser
            model.cookieMode = .browser(browser)
        } label: {
            Text(browser.shortName)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.clear, in: Capsule())
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.clear : Color.primary.opacity(0.16),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
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

// MARK: - 进度、错误与成功反馈

struct AudioLinkRunningOrErrorSection: View {
    let phase: AudioLinkImportModel.Phase

    var body: some View {
        switch phase {
        case .idle, .succeeded:
            EmptyView()
        case let .running(stage, logTail):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(stage.statusTitle).font(.callout.weight(.medium))
                    Spacer()
                    if case let .downloading(progress, _) = stage, let progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if case let .downloading(progress, _) = stage, let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                if let logTail, !logTail.isEmpty {
                    Text(logTail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AudioLinkSuccessSection: View {
    @ObservedObject var model: AudioLinkImportModel
    let result: AudioLinkImportResult

    var body: some View {
        let track = result.importedTrack.track
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Label("已导入「音乐」资料库", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text(track.title).font(.title3.weight(.semibold))
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist).font(.callout).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                Text(result.storageSummary)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let copyURL = result.savedCopyURL {
                    Text("本地副本：\(copyURL.path)").font(.caption.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text("继续为这首歌配歌词").font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    Button("在线搜歌词（网易云）") { model.fetchOnlineLyrics() }.buttonStyle(.borderedProminent)
                    Button("导入本地歌词文件") { model.importManualLyrics() }.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
