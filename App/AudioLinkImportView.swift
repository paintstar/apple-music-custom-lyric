import AppKit
import SwiftUI
import ShinAppleKit
import ShinAppServices

/// 从链接下载音频、写入标签并导入「音乐」资料库的交互弹窗（三段式双栏布局）。
struct AudioLinkImportView: View {
    @ObservedObject var model: AudioLinkImportModel
    var isMock: Bool = false
    let onClose: () -> Void

    @State private var showToolsPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 780)
        .frame(minHeight: 620, idealHeight: 680, maxHeight: 820)
        .interactiveDismissDisabled(model.isRunning)
        .onAppear { model.startToolCheck() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("从链接导入音频")
                    .font(.system(size: 20, weight: .bold))
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

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AudioLinkURLSection(model: model)
                HStack(alignment: .top, spacing: 18) {
                    AudioLinkMetadataColumn(model: model)
                    AudioLinkOptionsColumn(model: model)
                }
                .fixedSize(horizontal: false, vertical: true)
                AudioLinkCookieSection(model: model)
            }
            .padding(.trailing, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .disabled(model.isRunning)
    }

    private var footerButtons: some View {
        HStack {
            if model.isRunning {
                Button(role: .cancel) { model.cancelImport() } label: {
                    Text("取消导入").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                Spacer()
            } else if case .succeeded = model.phase {
                Button { model.resetForAnotherImport() } label: {
                    Text("再导一首").padding(.horizontal, 8)
                }
                .controlSize(.large)
                Spacer()
                Button { onClose() } label: {
                    Text("完成").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button { onClose() } label: {
                    Text("关闭").padding(.horizontal, 8)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button { model.startImport() } label: {
                    Text("开始下载并导入").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
    }
}
