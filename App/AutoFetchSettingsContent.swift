import SwiftUI
import ShinAppleKit
import ShinAppServices

// 自动获取设置区内容。语义要点（与管线行为一一对应）：
// - 勾选歌单后，新加入的歌自动获取（高置信直接落位、低置信进待确认）；
// - 歌移出歌单时，只有「自动获取且从未编辑」的歌词会被清理，
//   手动导入/人工编辑过的永远保留；
// - 取消勾选只停止监控，已获取的歌词保留；
// - 全部动作可在下方记录里核对。

struct AutoFetchSettingsContent: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var model: AutoFetchModel
    @State private var isAuditExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            mainToggle
            if model.settings.isEnabled {
                playlistPicker
                pendingList
            }
            runControls
            if let message = model.actionMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            auditDisclosure
            behaviorNote
        }
        .disabled(appModel.isSwitchingStorage)
    }

    // MARK: - 总开关

    private var mainToggle: some View {
        Toggle("启用：新加入勾选播放列表的歌曲自动获取歌词", isOn: Binding(
            get: { model.settings.isEnabled },
            set: { newValue in Task { await model.setEnabled(newValue) } }
        ))
        .help("获取由网易云音乐提供（匿名、仅歌词文本）；手动导入的歌词永远优先，不会被自动获取覆盖或删除")
    }

    // MARK: - 歌单勾选

    private var playlistPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("监控这些播放列表：")
                .font(.callout.weight(.medium))
            if model.playlists.isEmpty {
                Text("正在读取播放列表……（需「音乐」App 可用）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.playlists.filter { !$0.isFolder }) { playlist in
                    Toggle(isOn: Binding(
                        get: { model.settings.playlistIDs.contains(playlist.id) },
                        set: { _ in Task { await model.togglePlaylist(playlist.id) } }
                    )) {
                        HStack(spacing: 6) {
                            Text(playlist.name)
                            if playlist.isSmart {
                                Text("智能歌单")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - 待确认队列

    @ViewBuilder
    private var pendingList: some View {
        if !model.pendingItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("待确认（\(model.pendingItems.count) 首匹配度不足，请人工确认）")
                    .font(.callout.weight(.medium))
                ForEach(model.pendingItems) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.title)\(item.artist.map { " — \($0)" } ?? "")")
                                .font(.callout)
                                .lineLimit(1)
                            if let candidate = item.topCandidateTitle {
                                Text("最接近的候选：\(candidate)\(item.topCandidateArtist.map { " \($0)" } ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("搜索无结果，可换个关键词试试")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("搜索候选") {
                            appModel.beginOnlineFetch(for: item)
                        }
                        .help("为这首歌人工搜索并确认歌词（确认后不再自动删除）")
                        Button("不再获取") {
                            Task { await model.ignorePending(item) }
                        }
                        .help("这首歌不再自动获取歌词")
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        }
    }

    // MARK: - 刷新与摘要

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    if model.isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在核对播放列表……")
                        }
                    } else {
                        Text("立即刷新")
                    }
                }
                .disabled(model.isRefreshing)
                .help("对比勾选播放列表的当前成员与上次快照：新歌获取、移出的歌按规则清理")
            }
            if let summary = model.lastRunSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 审计

    private var auditDisclosure: some View {
        DisclosureGroup("自动动作记录（最近 20 条）", isExpanded: $isAuditExpanded) {
            if model.recentAudit.isEmpty {
                Text("暂无记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recentAudit) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.action.rawValue)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(actionColor(entry.action))
                            Text(entry.title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.timeText(entry.happenedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .font(.callout)
    }

    private func actionColor(_ action: AutoFetchAuditEntry.Action) -> Color {
        switch action {
        case .imported: return .green
        case .deleted: return .red
        case .pending: return .orange
        case .skipped, .failed: return .secondary
        }
    }

    private static func timeText(_ iso8601: String) -> String {
        guard let date = LyricTimestamp.date(from: iso8601) else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 行为说明

    private var behaviorNote: some View {
        Text("行为说明：歌词来自网易云音乐（匿名获取，仅歌词文本与翻译，不碰音频）；自动获取的内容标记「自动获取，未核对」。你手动导入或人工编辑过的歌词永远优先——不会被自动获取覆盖，移出播放列表时也不会被自动删除。取消勾选播放列表只停止监控，已获取的歌词保留。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
