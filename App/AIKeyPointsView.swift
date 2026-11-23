import SwiftUI
import ShinAIProvider

/// AI 提炼本曲重点词汇与句型预习卡弹窗：勾选后批量收入单词本并自动标注歌词下划线。
struct AIKeyPointsView: View {
    @ObservedObject var model: AIKeyPointsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            noticeBanner
            if let warning = model.missingKeyWarning {
                warningBanner(warning)
            }
            Divider()
            contentSection
            Divider()
            footerSection
        }
        .padding(18)
        .frame(width: 660, height: 560)
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { model.startIfIdle() }
        .onDisappear { model.invalidate() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("本曲重点词汇预习卡", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                if model.isMock {
                    Text("模拟模式")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(model.configuredServiceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(songSummaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var songSummaryLine: String {
        let cleanTitle = model.songTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = model.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (cleanTitle, cleanArtist) {
        case let (t?, a?) where !t.isEmpty && !a.isEmpty:
            return "目标曲目：\(t) — \(a)（共 \(model.nonEmptyLineCount) 行非空歌词）"
        case let (t?, _) where !t.isEmpty:
            return "目标曲目：\(t)（共 \(model.nonEmptyLineCount) 行非空歌词）"
        default:
            return "共 \(model.nonEmptyLineCount) 行非空歌词"
        }
    }

    private var noticeBanner: some View {
        Label(
            "AI 自动提炼本曲核心词汇与句型，请勾选后收入单词本",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var contentSection: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 10) {
                Text("点击下方按钮开始提炼本曲重点词汇。")
                    .foregroundStyle(.secondary)
                Button("开始提炼") { model.extract() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            loadingContent

        case let .ready(items):
            readyContent(items)

        case .saving:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在批量收入单词本并更新歌词下划线……")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .saved(count):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text("已将 \(count) 条重点词汇收入单词本")
                    .font(.headline)
                Text("歌词中的对应词汇已标注下划线，可在「单词本与笔记」或盲听挖空模式中复习。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("重新提炼") { model.extract() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingContent: some View {
        let startedAt = model.loadingStartedAt ?? .now
        return VStack(spacing: 14) {
            VStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在分析 \(model.nonEmptyLineCount) 行歌词并提炼重点词汇…… · 已耗时 \(elapsedSeconds) 秒")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !model.configuredServiceSummary.isEmpty {
                    Text("当前服务：\(model.configuredServiceSummary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .frame(minWidth: 380, maxWidth: 480)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            Button("取消提炼", role: .destructive) {
                model.cancelExtraction()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func readyContent(_ items: [SelectableKeyPoint]) -> some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                Text("未能从当前歌词中提炼出重点词汇。")
                    .foregroundStyle(.secondary)
                Button("重新提炼") { model.extract() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("共 \(items.count) 条 · 已选 \(model.selectedCount) 项")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button(model.allSelected ? "取消全选" : "全选") {
                        if model.allSelected {
                            model.deselectAll()
                        } else {
                            model.selectAll()
                        }
                    }
                    .controlSize(.small)
                    Button("重新提炼") { model.extract() }
                        .controlSize(.small)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            AIKeyPointCardRow(
                                item: item,
                                selectionBinding: Binding(
                                    get: { item.isSelected },
                                    set: { model.setSelected($0, for: item.id) }
                                )
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footerSection: some View {
        HStack {
            if case .saved = model.phase {
                Spacer()
                Button("完成") {
                    model.invalidate()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("关闭") {
                    model.invalidate()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)

                Spacer()

                if case .ready = model.phase {
                    Button(model.selectedCount > 0 ? "批量加入单词本（\(model.selectedCount)）" : "批量加入单词本") {
                        model.saveSelected()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedCount == 0)
                }
            }
        }
    }
}

private struct AIKeyPointCardRow: View {
    let item: SelectableKeyPoint
    let selectionBinding: Binding<Bool>

    var body: some View {
        let point = item.point
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: selectionBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 2)
                .accessibilityLabel("选择词汇：\(point.surface)")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(point.surface)
                        .font(.headline)
                    if !point.lemma.isEmpty, point.lemma != point.surface {
                        Text("原形：\(point.lemma)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reading = point.reading, !reading.isEmpty {
                        tagPill(reading, tint: .teal)
                    }
                    if let pos = point.partOfSpeech, !pos.isEmpty {
                        tagPill(pos, tint: .secondary)
                    }
                }

                if !item.lineTextExcerpt.isEmpty {
                    Text("原句：\(item.lineTextExcerpt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("句中义：\(point.contextualMeaning)")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !point.generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("通用义：\(point.generalMeaning)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tagPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}
