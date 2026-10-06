import SwiftUI
import ShinAppServices

// 双语导入区：导入预览页的「包含译文」开关、模式选择与配对对照区。
// 识别只发生在导入策略层（BilingualImportMapper 纯函数），预览所见即确认后
// 写入的译文；关闭开关回到单语导入。切换模式即时在后台重算（不冻结界面）。

/// 模式单选的 UI 标签（区分「成对/分隔符」两个选项）。
private enum BilingualUISelection {
    case paired
    case inline
}

struct ImportBilingualSection: View {
    @ObservedObject var flow: ImportFlowModel
    let preview: ImportPreview

    /// 对照区最多展示的行数（全量数据在预览统计中汇总）。
    private static let pairRowPreviewLimit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("包含译文", isOn: translationIncludedBinding)
                if flow.isRecomputingBilingual {
                    ProgressView().controlSize(.small)
                    Text("正在重新计算……")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if flow.translationIncluded {
                bilingualModeControls
                if let info = preview.bilingual {
                    bilingualResultSection(info)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 模式选择

    /// 模式选择（成对仅在 LRC 且存在行组时可选，置灰附原因）与分隔符单选。
    @ViewBuilder
    private var bilingualModeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("识别方式", selection: bilingualModeSelection) {
                Text("同时间戳成对").tag(BilingualUISelection.paired)
                Text("同行分隔符").tag(BilingualUISelection.inline)
            }
            .pickerStyle(.radioGroup)
            .disabled(!preview.pairedTimestampsAvailable)
            if !preview.pairedTimestampsAvailable {
                Text(pairedUnavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .inlineSeparator = flow.bilingualMode {
                Picker("分隔符", selection: inlineSeparatorSelection) {
                    ForEach(InlineSeparator.allCases, id: \.self) { separator in
                        Text(separator.displayName).tag(separator)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            }
        }
    }

    private var pairedUnavailableReason: String {
        if preview.sourceFormat == .text {
            return "本文件是纯文本（无时间戳），成对模式不可用；请使用「同行分隔符」模式。"
        }
        return "本文件没有同时间戳的行组，成对模式不可用；请使用「同行分隔符」模式。"
    }

    // MARK: - 统计、警告与对照区

    /// 统计行 + 警告 + 配对对照区（前 10 行）。
    @ViewBuilder
    private func bilingualResultSection(_ info: BilingualPreviewInfo) -> some View {
        Text("\(info.originalLineCount) 行原文 / \(info.translatedLineCount) 行配到译文 / \(info.warnings.count) 条警告")
            .font(.callout.weight(.medium))
        if !info.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(info.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !info.pairRows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("配对对照（前 \(min(Self.pairRowPreviewLimit, info.pairRows.count)) 行）")
                    .font(.callout.weight(.semibold))
                ForEach(
                    Array(info.pairRows.prefix(Self.pairRowPreviewLimit).enumerated()),
                    id: \.offset
                ) { _, row in
                    pairRowView(row)
                }
            }
        }
    }

    /// 对照区一行：原文一行、译文一行缩进显示；未配对/有警告标橙。
    private func pairRowView(_ row: BilingualPairRow) -> some View {
        let needsAttention = row.translationText == nil || row.warningMessage != nil
        return VStack(alignment: .leading, spacing: 2) {
            Text(row.originalText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let translation = row.translationText {
                Text(translation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = row.warningMessage {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            needsAttention ? Color.orange.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    // MARK: - 绑定

    private var translationIncludedBinding: Binding<Bool> {
        Binding(
            get: { flow.translationIncluded },
            set: { included in Task { await flow.setTranslationIncluded(included) } }
        )
    }

    private var bilingualModeSelection: Binding<BilingualUISelection> {
        Binding(
            get: {
                if case .pairedTimestamps = flow.bilingualMode { return .paired }
                return .inline
            },
            set: { selection in
                Task {
                    if selection == .paired {
                        await flow.selectPairedMode()
                    } else {
                        await flow.selectInlineMode(separator: currentInlineSeparator)
                    }
                }
            }
        )
    }

    private var inlineSeparatorSelection: Binding<InlineSeparator> {
        Binding(
            get: { currentInlineSeparator },
            set: { separator in Task { await flow.selectInlineMode(separator: separator) } }
        )
    }

    private var currentInlineSeparator: InlineSeparator {
        if case let .inlineSeparator(separator) = flow.bilingualMode { return separator }
        return .doubleSlash
    }
}
