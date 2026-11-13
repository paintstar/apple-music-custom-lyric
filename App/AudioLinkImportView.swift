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
        VStack(alignment: .leading, spacing: 14) {
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
        .padding(22)
        .frame(width: 700)
        .frame(minHeight: 550, idealHeight: 575, maxHeight: 740)
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
                HStack(alignment: .top, spacing: 14) {
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
}
