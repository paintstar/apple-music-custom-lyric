import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShinAppleKit
import ShinAppServices

/// 从链接下载音频、写入标签并导入「音乐」资料库的交互弹窗。
struct AudioLinkImportView: View {
    @ObservedObject var model: AudioLinkImportModel
    var isMock: Bool = false
    let onClose: () -> Void

    @State private var showToolsPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.toolAvailability?.isReady != true {
                AudioToolInstallGuideCard(model: model)
            }
            Divider()
            if case let .succeeded(result) = model.phase {
                AudioLinkSuccessSection(model: model, result: result)
            } else {
                formContent
                AudioLinkRunningOrErrorSection(phase: model.phase)
            }
            Spacer(minLength: 0)
            footerButtons
        }
        .padding(24)
        .frame(width: 640)
        .frame(minHeight: 620, idealHeight: 660, maxHeight: 780)
        .interactiveDismissDisabled(model.isRunning)
        .onAppear { model.startToolCheck() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("从链接导入音频").font(.title3.weight(.semibold))
                Text("通过本机 yt-dlp 与 ffmpeg 转封装为 M4A 后写入「音乐」资料库，全流程仅在本地运行。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 8) {
                if isMock {
                    Text("模拟模式").font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                }
                if let tools = model.toolAvailability, tools.isReady {
                    readyToolsBadge(tools)
                }
            }
        }
    }

    private func readyToolsBadge(_ tools: AudioToolAvailability) -> some View {
        Button { showToolsPopover.toggle() } label: {
            Label("yt-dlp · ffmpeg 已就绪", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showToolsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("本机依赖工具路径").font(.callout.weight(.semibold))
                Text("yt-dlp：\(tools.ytdlpURL?.path ?? "")").font(.caption2.monospaced()).textSelection(.enabled)
                Text("ffmpeg：\(tools.ffmpegURL?.path ?? "")").font(.caption2.monospaced()).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("重新检测") { model.startToolCheck() }
                        .controlSize(.small).disabled(model.isCheckingTools)
                }
            }
            .padding(12).frame(width: 360)
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AudioLinkURLSection(model: model)
                metadataSection
                AudioLinkCookieSection(model: model)
                saveOptionsSection
            }
            .padding(.trailing, 2)
        }
        .disabled(model.isRunning)
    }

    private var metadataSection: some View {
        AudioLinkSectionCard {
            HStack {
                Text("歌曲标签（可选，留空保留源信息）").font(.callout.weight(.medium))
                Spacer()
                Toggle("嵌入视频封面为歌曲封面", isOn: $model.embedThumbnail)
                    .toggleStyle(.checkbox).font(.caption)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    AudioLinkFieldColumn(label: "歌名", placeholder: "留空使用源标题", text: $model.title)
                    AudioLinkFieldColumn(label: "歌手", placeholder: "留空使用源作者", text: $model.artist)
                }
                GridRow {
                    AudioLinkFieldColumn(label: "专辑", placeholder: "可选", text: $model.album)
                    AudioLinkFieldColumn(label: "流派", placeholder: "可选", text: $model.genre)
                }
            }
        }
    }

    private var saveOptionsSection: some View {
        AudioLinkSectionCard {
            Text("保存方式").font(.callout.weight(.medium))
            Text("默认仅导入「音乐」App；若未开启“拷贝文件到媒体文件夹”，源文件将保存在应用支持目录以防断链。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Toggle("同时在本地保留 .m4a 副本", isOn: $model.keepLocalCopy).toggleStyle(.checkbox)
                if model.keepLocalCopy {
                    Spacer(minLength: 4)
                    Text(model.localCopyDirectory?.path ?? "桌面")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("更改目录…") { chooseLocalCopyDirectory() }.controlSize(.small)
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            if model.isRunning {
                Button("取消导入", role: .cancel) { model.cancelImport() }.keyboardShortcut(.cancelAction)
                Spacer()
            } else if case .succeeded = model.phase {
                Button("再导一首") { model.resetForAnotherImport() }
                Spacer()
                Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Button("关闭") { onClose() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始下载并导入") { model.startImport() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.canStart)
            }
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

// MARK: - 卡片容器与字段组件

private struct AudioLinkSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct AudioLinkFieldColumn: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 前置工具安装引导卡片

private struct AudioToolInstallGuideCard: View {
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

// MARK: - 链接输入、凭据、进度与结果卡片

private struct AudioLinkURLSection: View {
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

private struct AudioLinkCookieSection: View {
    @ObservedObject var model: AudioLinkImportModel
    @State private var selectedBrowser: AudioCookieBrowser = .chrome
    @State private var selectedCookiesFile: URL?

    private enum CookieKind: String, CaseIterable, Identifiable {
        case none = "不使用"
        case browser = "从浏览器读取"
        case file = "Cookies 文件"
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

    private var browserBinding: Binding<AudioCookieBrowser> {
        Binding(
            get: {
                if case let .browser(browser) = model.cookieMode { return browser }
                return selectedBrowser
            },
            set: { browser in
                selectedBrowser = browser
                model.cookieMode = .browser(browser)
            }
        )
    }

    var body: some View {
        AudioLinkSectionCard {
            Text("站点访问凭据（可选，用于高音质或需登录页面）").font(.callout.weight(.medium))
            HStack(spacing: 12) {
                Picker("Cookies 来源", selection: cookieKindBinding) {
                    ForEach(CookieKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                }
                .pickerStyle(.segmented).labelsHidden()

                if case .browser = model.cookieMode {
                    Picker("浏览器", selection: browserBinding) {
                        ForEach(AudioCookieBrowser.allCases) { browser in
                            Text(browser.displayName).tag(browser)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(width: 150)
                }
            }
            if case let .file(url) = model.cookieMode {
                HStack(spacing: 10) {
                    Text(url?.path ?? "未选择 cookies.txt 文件")
                        .font(.caption).foregroundStyle(url == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择文件…") { chooseCookiesFile() }.controlSize(.small)
                }
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

private struct AudioLinkRunningOrErrorSection: View {
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

private struct AudioLinkSuccessSection: View {
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
