import SwiftUI
import ShinAppleKit
import ShinAppServices

/// AI 一键注音 / 译文预览弹窗：用户主动触发、预览并可逐行编辑或勾选覆盖，确认后才写入。
struct AIStudyPreviewView: View {
    @ObservedObject var model: AIStudyPreviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            noticeBanner
            if let warning = model.missingKeyWarning {
                warningBanner(warning)
            }
            controlsSection
            Divider()
            contentSection
            if let error = model.errorMessage {
                errorBanner(error)
            }
            Divider()
            footerSection
        }
        .padding(18)
        .frame(width: 680, height: 580)
        .interactiveDismissDisabled(model.isApplying)
        .onDisappear { model.invalidate() }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("AI 生成注音 / 译文", systemImage: "sparkles")
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
            if let title = songSummaryLine {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var songSummaryLine: String? {
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
            "AI 生成由用户主动触发，确认后才写入；已人工编辑的条目默认保留不覆盖。文本注音仅供参考，不代表歌手实际演唱唱法。",
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

    private var controlsSection: some View {
        HStack(spacing: 12) {
            Picker("生成任务", selection: $model.selectedTaskOption) {
                ForEach(AIStudyPreviewModel.TaskOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .disabled(model.isGenerating || model.isApplying)

            if model.selectedTaskOption == .pronunciation {
                Picker("注音形式", selection: $model.selectedStyle) {
                    ForEach(AIStudyPreviewModel.selectablePronunciationStyles, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 170)
                .disabled(model.isGenerating || model.isApplying)
            }

            Spacer()

            actionControlButton
        }
    }

    @ViewBuilder
    private var actionControlButton: some View {
        switch model.phase {
        case .idle:
            Button("开始生成") {
                model.generate()
            }
            .disabled(model.nonEmptyLineCount == 0)
        case .generating:
            Button("取消任务", role: .destructive) {
                model.cancelGeneration()
            }
        case .preview:
            Button("重新生成") {
                model.resetToIdle()
            }
        case .applying:
            Button("重新生成") {}
                .disabled(true)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        switch model.phase {
        case .idle:
            idleContent
        case let .generating(progress):
            generatingContent(progress: progress)
        case let .preview(lines):
            previewContent(lines)
        case .applying:
            VStack(spacing: 10) {
                ProgressView()
                Text("正在应用选中结果……")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var idleContent: some View {
        VStack(spacing: 8) {
            Text(model.nonEmptyLineCount == 0
                 ? "当前歌词没有可供 AI 处理的非空行。"
                 : "选择需要生成的学习内容后，点击「开始生成」获取预览。")
                .foregroundStyle(.secondary)
            Text("生成完成后可逐行修改结果、按行勾选是否写入，已人工编辑的条目默认不勾选覆盖。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generatingContent(progress: AIStudyBatchProgress) -> some View {
        let percentage = Int((progress.fractionCompleted * 100).rounded())
        let isFinalizing = progress.totalBatches > 0 && progress.completedBatches >= progress.totalBatches
        let statusText = isFinalizing
            ? "正在整理生成结果……"
            : "正在生成第 \(progress.currentBatchNumber) / \(progress.totalBatches) 批"
        let startedAt = model.generationStartedAt ?? .now

        return VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(statusText)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(percentage)%")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ProgressView(value: progress.fractionCompleted, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.25),
                        value: progress.fractionCompleted
                    )

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("已完成 \(progress.completedLines) / \(progress.totalLines) 行 · 已耗时 \(elapsedSeconds) 秒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
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
            .frame(width: 380)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            Text("可随时点击「取消任务」中止后续请求。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewContent(_ lines: [AIStudyPreviewLine]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("共 \(lines.count) 行 · 已选 \(model.selectedCount) 项")
                    .font(.callout.weight(.medium))
                if model.manualProtectedCount > 0 {
                    Text("· 已保留 \(model.manualProtectedCount) 条人工编辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全选未人工编辑项") { model.selectAllNonManual() }
                    .controlSize(.small)
                Button("反选") { model.invertSelection() }
                    .controlSize(.small)
                Button("全不选") { model.deselectAll() }
                    .controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { line in
                        AIStudyPreviewRow(
                            line: line,
                            selectionBinding: Binding(
                                get: { line.isSelected },
                                set: { model.setSelected($0, for: line.lineId) }
                            ),
                            textBinding: Binding(
                                get: { line.generatedText },
                                set: { model.setGeneratedText($0, for: line.lineId) }
                            )
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footerSection: some View {
        HStack {
            Button("取消") {
                model.invalidate()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isApplying)

            Spacer()

            Button(model.isApplying ? "正在应用……" : "确认应用") {
                model.applyPreview()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApply)
        }
    }
}

private struct AIStudyPreviewRow: View {
    let line: AIStudyPreviewLine
    let selectionBinding: Binding<Bool>
    let textBinding: Binding<String>

    private var hasGeneratedContent: Bool {
        !line.generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: selectionBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!hasGeneratedContent)
                .padding(.top, 2)
                .accessibilityLabel("应用此行生成结果：\(line.originalText)")

            VStack(alignment: .leading, spacing: 4) {
                Text(line.originalText)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                if let existing = line.existingText, !existing.isEmpty {
                    HStack(spacing: 6) {
                        Text("现有：\(existing)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if line.existingIsManual {
                            Text("已有人工版本，默认保留")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.16), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }

                TextField("生成结果（可手动修改，留空则不应用）", text: textBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
