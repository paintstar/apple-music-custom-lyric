import SwiftUI
import ShinAppleKit
import ShinAppServices

// MARK: - 前置工具安装引导卡片

struct AudioToolInstallGuideCard: View {
    @ObservedObject var model: AudioLinkImportModel

    var body: some View {
        if model.isCheckingTools && model.toolAvailability == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在检测本机 yt-dlp 与 ffmpeg 工具……")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        } else if let tools = model.toolAvailability, !tools.isReady {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("需要先安装本机命令行依赖工具", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("安装完成后重新检测") { model.startToolCheck() }
                        .controlSize(.regular)
                        .disabled(model.isCheckingTools)
                }
                HStack(spacing: 14) {
                    toolBadge(name: "yt-dlp", role: "解析链接并提取音频", url: tools.ytdlpURL)
                    toolBadge(name: "ffmpeg", role: "封装 M4A 与写入封面标签", url: tools.ffmpegURL)
                }
                if let command = model.installCommand {
                    HStack(spacing: 10) {
                        Text(command)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Button(model.copiedInstallCommand ? "已复制" : "复制命令") { model.copyInstallCommand() }
                            .controlSize(.regular)
                        Button("打开终端") { model.openTerminalApp() }
                            .controlSize(.regular)
                    }
                }
                Text("已扫描路径：/opt/homebrew/bin、/usr/local/bin、~/.local/bin 及环境变量 PATH")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.25), lineWidth: 1))
        }
    }

    private func toolBadge(name: String, role: String, url: URL?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: url != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(url != nil ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(url != nil ? "已就绪" : "未检测到 · \(role)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(stage.statusTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                    Spacer()
                    if case let .downloading(progress, _) = stage, let progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 13).monospacedDigit())
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
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(18)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

struct AudioLinkSuccessSection: View {
    @ObservedObject var model: AudioLinkImportModel
    let result: AudioLinkImportResult

    var body: some View {
        let track = result.importedTrack.track
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("已导入「音乐」资料库", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
                Text(track.title)
                    .font(.system(size: 18, weight: .bold))
                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                Text(result.storageSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let copyURL = result.savedCopyURL {
                    Text("本地副本：\(copyURL.path)")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Text("继续为这首歌配歌词")
                    .font(.system(size: 14.5, weight: .semibold))
                HStack(spacing: 12) {
                    Button("在线搜歌词（网易云）") { model.fetchOnlineLyrics() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("导入本地歌词文件") { model.importManualLyrics() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
