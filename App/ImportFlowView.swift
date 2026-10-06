import SwiftUI
import UniformTypeIdentifiers
import ShinAppleKit
import ShinAppServices

// 歌词导入流程页（全中文）：
// 粘贴文本（默认入口）或选文件（系统文件面板）→ 预览（诊断、
// 统计、元信息、目标歌曲确认卡与「将被替换」提示）→ 确认/取消。
// 双语导入：预览页提供「包含译文」开关与模式选择（同时间戳成对 /
// 同行分隔符），切换即时在后台重算并刷新对照区；确认才写入。
// 目标歌曲在打开本页时固定，导入过程中切换播放不会改变关联对象。
//
// 键盘约定：文本输入框只存在于 idle 阶段，
// 「确认导入」（.defaultAction，Return 触发）只存在于 ready 阶段——二者
// 绝不同时在场，Return 在文本框内始终是换行；idle 阶段的按钮一律不挂
// 键盘热键，避免吞掉文本输入按键。Esc = 取消（.cancelAction）。

struct ImportFlowView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var flow: ImportFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @FocusState private var isPastedTextFocused: Bool

    /// 模式单选的 UI 标签（区分「成对/分隔符」两个选项）。
    private enum BilingualUISelection {
        case paired
        case inline
    }

    /// 对照区最多展示的行数（全量数据在预览统计中汇总）。
    private static let pairRowPreviewLimit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入歌词")
                .font(.title3.weight(.semibold))
            targetCard
            Divider()
            stageContent
            if let message = flow.alertMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            footerButtons
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.data],
            allowsMultipleSelection: false
        ) { result in
            handleFilePick(result)
        }
    }

    // MARK: - 目标歌曲确认卡

    @ViewBuilder
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("导入目标歌曲", systemImage: "music.note")
                .font(.headline)
            if let target = flow.target {
                Text(displayTitle(target))
                    .font(.body.weight(.medium))
                Text(targetSubtitle(target))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("未指定目标歌曲。")
                    .foregroundStyle(.secondary)
            }
            Text("目标在打开本窗口时已固定；导入过程中切换播放不会改变关联对象。确认前不会改动任何已有数据。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let existing = flow.existingForTarget {
                existingBindingNote(existing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 「将被替换」提示：目标已有绑定时的现有文档信息。
    private func existingBindingNote(_ existing: ExistingBindingInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("该歌曲已有本地歌词，确认后将替换关联", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(existingDescription(existing))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !existing.otherBindings.isEmpty {
                Text("该歌词文档还被另外 \(existing.otherBindings.count) 首歌曲共享；替换本曲关联不影响它们。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 阶段内容

    /// idle 阶段输入区：粘贴优先，文件选择保留为次要入口。
    private var idleInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("粘贴歌词文本（LRC 或纯文本），或从文件选择。内容只在本机解析与保存。")
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $flow.pastedText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .focused($isPastedTextFocused)
                if flow.pastedText.isEmpty {
                    Text("在此粘贴歌词（⌘V）：支持带时间戳的 LRC 与纯文本")
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .padding(.top, 8)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .onAppear {
                // 打开/回到输入阶段即就绪粘贴，不需要先点文本框。
                isPastedTextFocused = true
            }
            HStack(spacing: 12) {
                Button("解析文本") {
                    isPastedTextFocused = false
                    Task { await flow.ingestPastedText() }
                }
                .disabled(flow.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("从文件选择…") {
                    showFilePicker = true
                }
            }
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch flow.phase {
        case .idle:
            idleInputSection
        case .loadingPreview:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在解析歌词内容……")
                    .foregroundStyle(.secondary)
            }
        case let .ready(preview, existing):
            previewSection(preview, existing: existing)
        case .saving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在保存……")
            }
        case let .succeeded(confirmation):
            successSection(confirmation)
        }
    }

    private func previewSection(
        _ preview: ImportPreview,
        existing: ExistingBindingInfo?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                statsRow(preview)
                ImportBilingualSection(flow: flow, preview: preview)
                metadataRow(preview)
                offsetNote(preview)
                diagnosticsList(preview)
                if let existing {
                    existingBindingNote(existing)
                }
                if !preview.isImportable {
                    Text("内容存在无法保存的错误，请修正后重新输入。")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func statsRow(_ preview: ImportPreview) -> some View {
        Text("共 \(preview.totalLineCount) 行：已打轴 \(preview.timedLineCount) 行，未打轴 \(preview.untimedLineCount) 行。")
            .font(.callout)
    }

    @ViewBuilder
    private func metadataRow(_ preview: ImportPreview) -> some View {
        let title = preview.firstMetadataValue(for: "ti")
        let artist = preview.firstMetadataValue(for: "ar")
        let album = preview.firstMetadataValue(for: "al")
        if title != nil || artist != nil || album != nil {
            Text("文件元信息：\(title ?? "未知歌名") / \(artist ?? "未知歌手")"
                + (album.map { " / 专辑：\($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func offsetNote(_ preview: ImportPreview) -> some View {
        Text("文件 offset：\(preview.sourceOffsetMs) ms。\n\(ImportPreview.sourceOffsetNote)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func diagnosticsList(_ preview: ImportPreview) -> some View {
        if preview.diagnostics.isEmpty {
            Text("解析完成：未发现诊断。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("解析诊断（\(preview.diagnostics.count) 条）")
                    .font(.callout.weight(.semibold))
                ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    diagnosticRow(diagnostic)
                }
            }
        }
    }

    private func diagnosticRow(_ diagnostic: LyricDiagnostic) -> some View {
        let color: Color = diagnostic.severity == .error ? .red : .orange
        return VStack(alignment: .leading, spacing: 2) {
            Label(diagnostic.message, systemImage: diagnostic.severity == .error
                ? "xmark.octagon" : "exclamationmark.triangle")
                .foregroundStyle(color)
                .font(.caption)
            Text(positionDescription(diagnostic))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func successSection(_ confirmation: ImportConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("已保存并关联到当前目标歌曲。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.headline)
            Text(summaryText(confirmation))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("完成") {
                flow.finish()
                dismiss()
            }
        }
    }

    // MARK: - 底部按钮

    @ViewBuilder
    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("取消") {
                Task {
                    await flow.cancel()
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            switch flow.phase {
            case let .ready(preview, _):
                Button("重新输入") {
                    flow.resetToIdle()
                }
                Button("确认导入") {
                    Task { await flow.confirm() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.isImportable)
            case .idle:
                EmptyView()
            case .loadingPreview, .saving, .succeeded:
                EmptyView()
            }
        }
    }

    // MARK: - 文件选择与文案

    private func handleFilePick(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task { await flow.ingestFile(at: url) }
        case let .failure(error):
            flow.alertMessage = "无法读取所选文件：\(ErrorText.describe(error))"
        }
    }

    private func displayTitle(_ target: ImportSessionTarget) -> String {
        target.titleHint ?? "（未获得歌名提示）"
    }

    private func targetSubtitle(_ target: ImportSessionTarget) -> String {
        var parts: [String] = []
        if let artist = target.artistHint {
            parts.append("歌手：\(artist)")
        }
        if let duration = target.durationHintMs {
            parts.append("时长提示：\(Self.formatDuration(duration))")
        }
        parts.append("身份：\(target.trackKey)")
        return parts.joined(separator: "　")
    }

    private func existingDescription(_ existing: ExistingBindingInfo) -> String {
        var parts: [String] = []
        if let filename = existing.document?.originalFilename {
            parts.append("文件「\(filename)」")
        }
        if let updatedAt = existing.document?.updatedAt {
            parts.append("更新于 \(updatedAt)")
        }
        if parts.isEmpty {
            parts.append("文档 ID：\(existing.binding.lyricDocumentId.uuidString)")
        }
        parts.append("旧文档确认后仍保留在本地库中")
        return parts.joined(separator: "；")
    }

    private func summaryText(_ confirmation: ImportConfirmation) -> String {
        var parts = [
            "共 \(confirmation.document.lines.count) 行歌词已保存到本机。"
        ]
        if confirmation.replacedBinding != nil {
            parts.append("已替换旧关联；旧歌词文档仍保留，可在后续版本中管理。")
        }
        return parts.joined(separator: " ")
    }

    private func positionDescription(_ diagnostic: LyricDiagnostic) -> String {
        var parts: [String] = []
        if let line = diagnostic.line {
            parts.append("第 \(line) 行")
        }
        if let column = diagnostic.column {
            parts.append("第 \(column) 列")
        }
        if let snippet = diagnostic.snippet, !snippet.isEmpty {
            parts.append("「\(snippet)」")
        }
        return parts.isEmpty ? "位置未知" : parts.joined(separator: "　")
    }

    private static func formatDuration(_ ms: Int64) -> String {
        let totalSeconds = ms / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
