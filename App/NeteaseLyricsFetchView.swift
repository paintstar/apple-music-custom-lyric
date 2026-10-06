import SwiftUI
import ShinLyricsProvider

// 在线获取歌词弹窗：搜索 → 候选 → 取词。
// 取词完成后不直接写库：文本交回既有导入流程（预览 → 用户确认），
// 用户在这里看到的承诺是「选一首对的歌」，不是「歌词已保存」。

struct NeteaseLyricsFetchView: View {
    @ObservedObject var model: NeteaseLyricsFetchModel
    var isMock: Bool
    var onClose: () -> Void

    @State private var selectedSongId: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchFields
            switch model.phase {
            case .idle, .searching:
                idleContent
            case let .candidates(ranked):
                candidateList(ranked)
            case let .fetching(candidate):
                fetchingContent(candidate)
            case .delivered:
                deliveredContent
            }
            if let message = model.alertMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onDisappear { model.cancel() }
    }

    // MARK: - 头部与搜索

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("在线获取歌词")
                    .font(.headline)
                Spacer()
                if isMock {
                    Text("模拟模式：虚构候选")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("取消") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("目标：\(model.target.titleHint ?? "当前曲目")\(model.target.artistHint.map { " — \($0)" } ?? "")"
                + "。获取后进入导入预览，确认才会写库；已有手动歌词不会被静默覆盖。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchFields: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("歌名").font(.caption).foregroundStyle(.secondary)
                TextField("歌名", text: $model.queryTitle)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("歌手（可选）").font(.caption).foregroundStyle(.secondary)
                TextField("歌手", text: $model.queryArtist)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                Task { await model.search() }
            } label: {
                if case .searching = model.phase {
                    ProgressView().controlSize(.small)
                } else {
                    Text("搜索").frame(minWidth: 44)
                }
            }
            .disabled(!canSearch)
            .padding(.top, 16)
        }
    }

    private var canSearch: Bool {
        guard case .delivered = model.phase else { return true }
        return false
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .searching = model.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在搜索网易云音乐……")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Text("输入歌名（可加歌手）搜索网易云音乐的歌词。\n同名歌曲很多，请按歌手和时长核对候选。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 候选列表

    private func candidateList(_ ranked: [RankedCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("候选（按匹配度排序，请核对歌手与时长）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(ranked) { item in
                        candidateRow(item)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("选中候选后点「获取歌词」；获取内容进入导入预览后再确认保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    guard let id = selectedSongId,
                          let item = ranked.first(where: { $0.candidate.songId == id }) else { return }
                    Task { await model.deliver(item) }
                } label: {
                    Text("获取歌词")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSongId == nil)
            }
        }
    }

    private func candidateRow(_ item: RankedCandidate) -> some View {
        let isSelected = selectedSongId == item.candidate.songId
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.candidate.title)
                        .lineLimit(1)
                    confidenceBadge(item.score.confidence)
                }
                HStack(spacing: 8) {
                    Text(item.candidate.artistLine.isEmpty ? "（无歌手信息）" : item.candidate.artistLine)
                    if let album = item.candidate.album {
                        Text("· \(album)")
                    }
                    if let text = durationLine(item) {
                        Text("· \(text)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedSongId = item.candidate.songId }
    }

    private func confidenceBadge(_ confidence: MatchConfidence) -> some View {
        Text(confidence.displayName)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(badgeColor(confidence).opacity(0.16))
            )
            .foregroundStyle(badgeColor(confidence))
    }

    private func badgeColor(_ confidence: MatchConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    /// 时长对照行：本地已知时长时显示差值，否则显示候选自身时长。
    private func durationLine(_ item: RankedCandidate) -> String? {
        guard let remote = item.candidate.durationMs else { return nil }
        if let local = model.matchQuery.durationMs {
            let delta = abs(local - remote)
            return "时长差 \(String(format: "%.1f", Double(delta) / 1000))s"
        }
        return "时长 \(String(format: "%.1f", Double(remote) / 1000))s"
    }

    // MARK: - 取词与完成态

    private func fetchingContent(_ candidate: NeteaseSongCandidate) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text("正在获取《\(candidate.title)》的歌词……")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deliveredContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("歌词已获取，正在打开导入预览……")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
