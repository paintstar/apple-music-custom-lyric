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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            AudioToolStatusBanner(model: model)
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
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 540, idealHeight: 620, maxHeight: 720)
        .interactiveDismissDisabled(model.isRunning)
        .onAppear {
            model.startToolCheck()
        }
    }

    // MARK: - 头部与表单

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("从链接导入音频")
                    .font(.title3.weight(.semibold))
                Text("通过本机 yt-dlp 与 ffmpeg 转封装为 M4A 后写入「音乐」资料库，全流程仅在本地运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isMock {
                Text("模拟模式")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                linkInputSection
                metadataSection
                AudioLinkCookieSection(model: model)
                saveOptionsSection
            }
            .padding(.trailing, 4)
        }
        .disabled(model.isRunning)
    }

    private var linkInputSection: some View {
        AudioLinkSectionCard(title: "音频 / 视频链接") {
            TextField("https://www.bilibili.com/video/...", text: $model.urlString)
                .textFieldStyle(.roundedBorder)
            Text("支持 B 站（bilibili.com）等 yt-dlp 支持的公开视频或音频页面链接。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var metadataSection: some View {
        AudioLinkSectionCard(title: "歌曲标签（可选，留空保留源信息）") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    AudioLinkFieldColumn(label: "歌名", placeholder: "留空使用源标题", text: $model.title)
                    AudioLinkFieldColumn(label: "歌手", placeholder: "留空使用源作者", text: $model.artist)
                }
                GridRow {
                    AudioLinkFieldColumn(label: "专辑", placeholder: "可选", text: $model.album)
                    AudioLinkFieldColumn(label: "流派", placeholder: "可选", text: $model.genre)
                }
            }
            Toggle("将视频封面嵌入为歌曲封面", isOn: $model.embedThumbnail)
                .padding(.top, 2)
        }
    }

    private var saveOptionsSection: some View {
        AudioLinkSectionCard(title: "保存方式") {
            Text("默认仅导入「音乐」App。若「音乐」未启用“拷贝文件到媒体文件夹”，"
                + "源文件将保存在应用支持目录以防断链。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("同时在本地保留 .m4a 副本", isOn: $model.keepLocalCopy)
            if model.keepLocalCopy {
                HStack(spacing: 10) {
                    Text(model.localCopyDirectory?.path ?? "桌面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("更改目录…") {
                        chooseLocalCopyDirectory()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 底部按钮与面板

    private var footerButtons: some View {
        HStack {
            if model.isRunning {
                Button("取消导入", role: .cancel) {
                    model.cancelImport()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
            } else if case .succeeded = model.phase {
                Button("再导一首") {
                    model.resetForAnotherImport()
                }
                Spacer()
                Button("完成") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("关闭") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始下载并导入") {
                    model.startImport()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.localCopyDirectory = url
    }
}

// MARK: - 子视图卡片

private struct AudioLinkSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.medium))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AudioLinkFieldColumn: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AudioToolStatusBanner: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        if model.isCheckingTools && model.toolAvailability == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检测本机 yt-dlp 与 ffmpeg 工具……")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if let tools = model.toolAvailability {
            if tools.isReady {
                readyBanner(tools)
            } else {
                missingToolsBanner(tools)
            }
        }
    }

    private func readyBanner(_ tools: AudioToolAvailability) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("本机依赖工具已就绪", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Text("yt-dlp：\(tools.ytdlpURL?.path ?? "")")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("ffmpeg：\(tools.ffmpegURL?.path ?? "")")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func missingToolsBanner(_ tools: AudioToolAvailability) -> some View {
        let missing = [
            tools.ytdlpURL == nil ? "yt-dlp" : nil,
            tools.ffmpegURL == nil ? "ffmpeg" : nil
        ].compactMap { $0 }.joined(separator: "、")
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("未检测到 \(missing)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("重新检测") {
                    model.startToolCheck()
                }
                .controlSize(.small)
                .disabled(model.isCheckingTools)
            }
            Text("可使用 Homebrew 安装：brew install yt-dlp ffmpeg")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
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
        AudioLinkSectionCard(title: "站点访问凭据（可选，用于高音质或需登录页面）") {
            Picker("Cookies 来源", selection: cookieKindBinding) {
                ForEach(CookieKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch model.cookieMode {
            case .none:
                EmptyView()
            case .browser:
                Picker("浏览器", selection: browserBinding) {
                    ForEach(AudioCookieBrowser.allCases) { browser in
                        Text(browser.displayName).tag(browser)
                    }
                }
                .pickerStyle(.menu)
            case .file(let url):
                HStack(spacing: 10) {
                    Text(url?.path ?? "未选择 cookies.txt 文件")
                        .font(.caption)
                        .foregroundStyle(url == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择文件…") { chooseCookiesFile() }
                        .controlSize(.small)
                }
            }
            Text("本应用不会读取、展示或持久化 Cookies 内容，仅在调用 yt-dlp 时传递来源参数。")
                .font(.caption)
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
                    Text(stageTitle(stage))
                        .font(.callout.weight(.medium))
                    Spacer()
                    if case let .downloading(progress, _) = stage, let progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if case let .downloading(progress, _) = stage, let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                if let logTail, !logTail.isEmpty {
                    Text(logTail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stageTitle(_ stage: AudioLinkImportStage) -> String {
        switch stage {
        case .validating: return "正在校验链接与工具……"
        case .downloading: return "正在下载并提取音频……"
        case .tagging: return "正在写入歌曲标签与封面……"
        case .importingToMusic: return "正在导入「音乐」资料库……"
        case .savingCopy: return "正在保存本地 .m4a 副本……"
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
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(track.title)
                    .font(.title3.weight(.semibold))
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                Text(storageSummary(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let copyURL = result.savedCopyURL {
                    Text("本地副本：\(copyURL.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text("继续为这首歌配歌词")
                    .font(.callout.weight(.medium))
                HStack(spacing: 10) {
                    Button("在线搜歌词（网易云）") {
                        model.fetchOnlineLyrics()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("导入本地歌词文件") {
                        model.importManualLyrics()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func storageSummary(_ result: AudioLinkImportResult) -> String {
        if result.keptInStaging, let stagedURL = result.stagedFileURL {
            return "「音乐」App 直接引用源文件，已在应用支持目录保留：\(stagedURL.path)"
        }
        if let resolved = result.importedTrack.resolvedFileURL {
            return "「音乐」App 已拷贝至媒体库（\(resolved.path)），临时暂存已清理。"
        }
        return "已完成导入「音乐」资料库。"
    }
}
