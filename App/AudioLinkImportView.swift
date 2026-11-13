import AppKit
import SwiftUI
import ShinAppleKit
import ShinAppServices

/// 从链接下载音频、写入标签并导入「音乐」资料库的主界面页面（全宽单列纵向排布）。
struct AudioLinkImportView: View {
    @ObservedObject var model: AudioLinkImportModel
    var isMock: Bool = false
    var bottomContentInset: CGFloat = 100

    @State private var showToolsPopover = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.toolAvailability?.isReady != true {
                    AudioToolInstallGuideCard(model: model)
                }
                if case let .succeeded(result) = model.phase {
                    AudioLinkSuccessSection(model: model, result: result)
                } else {
                    formSections
                    AudioLinkRunningOrErrorSection(phase: model.phase)
                    actionFooter
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, bottomContentInset)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { model.startToolCheck() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("从链接导入音频")
                    .font(.system(size: 22, weight: .bold))
                Text("通过本机 yt-dlp 与 ffmpeg 转封装为 M4A 后写入「音乐」资料库，全流程仅在本地运行。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 10) {
                if isMock {
                    Text("模拟模式")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
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
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showToolsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("本机依赖工具路径")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("yt-dlp：\(tools.ytdlpURL?.path ?? "")")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Text("ffmpeg：\(tools.ffmpegURL?.path ?? "")")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("重新检测") { model.startToolCheck() }
                        .controlSize(.regular)
                        .disabled(model.isCheckingTools)
                }
            }
            .padding(14)
            .frame(width: 380)
        }
    }

    private var formSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            AudioLinkURLSection(model: model)
            AudioLinkMetadataSection(model: model)
            AudioLinkOptionsSection(model: model)
            AudioLinkCookieSection(model: model)
        }
        .disabled(model.isRunning)
    }

    private var actionFooter: some View {
        HStack {
            Spacer()
            if model.isRunning {
                Button(role: .cancel) { model.cancelImport() } label: {
                    Text("取消导入").padding(.horizontal, 12)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button { model.startImport() } label: {
                    Label("开始下载并导入", systemImage: "arrow.down.circle.fill")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .padding(.top, 4)
    }
}
