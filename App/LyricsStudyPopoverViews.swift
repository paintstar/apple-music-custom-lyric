import SwiftUI

/// 划词窗口优先展示本机词典，语境解析由用户按需触发。
struct WordStudyPopoverView: View {
    @ObservedObject var studyModel: LyricsStudyModel
    let initialState: WordPopoverState

    @State private var isDictionaryExpanded = false
    @State private var isEditExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: WordPopoverState {
        studyModel.wordPopover?.id == initialState.id ? (studyModel.wordPopover ?? initialState) : initialState
    }

    private var generalMeaningBinding: Binding<String> {
        Binding(
            get: { state.draftGeneralMeaning },
            set: { newValue in
                guard var current = studyModel.wordPopover,
                      current.id == initialState.id,
                      newValue != current.draftGeneralMeaning else { return }
                current.draftGeneralMeaning = newValue
                current.hasEditedGeneralMeaning = true
                current.saveSuccessMessage = nil
                studyModel.wordPopover = current
            }
        )
    }

    private var contextualMeaningBinding: Binding<String> {
        Binding(
            get: { state.draftContextualMeaning },
            set: { newValue in
                guard var current = studyModel.wordPopover,
                      current.id == initialState.id,
                      newValue != current.draftContextualMeaning else { return }
                current.draftContextualMeaning = newValue
                current.hasEditedContextualMeaning = true
                current.saveSuccessMessage = nil
                studyModel.wordPopover = current
            }
        )
    }

    private var userNoteBinding: Binding<String> {
        Binding(
            get: { state.draftUserNote },
            set: { newValue in
                guard var current = studyModel.wordPopover,
                      current.id == initialState.id,
                      newValue != current.draftUserNote else { return }
                current.draftUserNote = newValue
                current.saveSuccessMessage = nil
                studyModel.wordPopover = current
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WordStudyHeaderSection(
                    state: state,
                    onSave: { studyModel.saveCurrentWordFromPopover() }
                )
                WordStudyDictionarySection(
                    state: state,
                    isExpanded: $isDictionaryExpanded,
                    reduceMotion: reduceMotion
                )
                WordStudyAISection(
                    state: state,
                    isMock: studyModel.isMock,
                    missingKeyWarning: studyModel.missingKeyWarning,
                    onRequestAI: { studyModel.requestAIWordExplanation() },
                    onOpenSettings: openSettings
                )
                Divider()
                WordStudyCustomEditSection(
                    state: state,
                    isExpanded: $isEditExpanded,
                    reduceMotion: reduceMotion,
                    generalMeaning: generalMeaningBinding,
                    contextualMeaning: contextualMeaningBinding,
                    userNote: userNoteBinding,
                    onSave: { studyModel.saveCurrentWordFromPopover() }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .contentMargins(.vertical, 12, for: .scrollContent)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .onChange(of: state.id) { _, _ in
            isDictionaryExpanded = false
            isEditExpanded = false
        }
    }

    private func openSettings() {
        studyModel.dismissWordPopover()
        NotificationCenter.default.post(name: .shinSelectSettingsPage, object: SettingsCategory.aiStudy)
    }
}

// MARK: - 底部折叠自定义释义与笔记区

struct WordStudyCustomEditSection: View {
    let state: WordPopoverState
    @Binding var isExpanded: Bool
    var reduceMotion: Bool
    let generalMeaning: Binding<String>
    let contextualMeaning: Binding<String>
    let userNote: Binding<String>
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Label("编辑释义和笔记", systemImage: "square.and.pencil")
                        .font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")

            if isExpanded {
                expandedEditor
            }
        }
    }

    private var expandedEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudyLabeledTextField(
                title: "释义摘要",
                placeholder: "释义摘要（可编辑，留空亦可先收录）",
                text: generalMeaning,
                titleFont: .subheadline.weight(.semibold),
                font: .body,
                lineLimit: 1...3
            )
            StudyLabeledTextField(
                title: "本句语境释义（可选）",
                placeholder: "本句中的特定含义（可选）",
                text: contextualMeaning,
                titleFont: .subheadline.weight(.semibold),
                font: .body,
                lineLimit: 1...2
            )
            StudyLabeledTextField(
                title: "个人笔记（可选）",
                placeholder: "记忆技巧或个人笔记（可选）",
                text: userNote,
                titleFont: .subheadline.weight(.semibold),
                font: .body,
                lineLimit: 1...3
            )

            HStack {
                Spacer()
                Button(action: onSave) {
                    if state.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("保存修改")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isSaving)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - 词句弹窗共享轻量组件

/// 自动换行流式布局，用于词条属性胶囊与重点表达标签。
struct StudyFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    private struct PlacedItem {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [PlacedItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrangeRows(maxWidth: maxWidth, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        let totalHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        let resolvedWidth = maxWidth.isFinite ? maxWidth : (rows.map(\.width).max() ?? 0)
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func arrangeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        let itemProposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(itemProposal)
            let neededWidth = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.items.isEmpty, maxWidth.isFinite, neededWidth > maxWidth {
                rows.append(current)
                current = Row(items: [PlacedItem(index: index, size: size)], width: size.width, height: size.height)
            } else {
                current.items.append(PlacedItem(index: index, size: size))
                current.width = neededWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

/// 词句学习弹窗通用胶囊标签。
struct StudyCapsuleBadge: View {
    let text: String
    let tint: Color
    var backgroundOpacity: Double = 0.14

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(backgroundOpacity), in: Capsule())
    }
}

/// 词句弹窗带标题的多行输入项。
struct StudyLabeledTextField: View {
    let title: String
    let placeholder: String
    let text: Binding<String>
    var titleFont: Font = .caption2.weight(.semibold)
    var font: Font = .caption
    var lineLimit: ClosedRange<Int> = 1...3
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(font)
                .lineLimit(lineLimit)
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 词句学习弹窗加载提示条。
struct StudyLoadingBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 词句学习弹窗错误提示。
struct StudyErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 词句学习弹窗保存结果提示。
struct StudySaveStatusLabel: View {
    let successMessage: String?
    let errorMessage: String?

    var body: some View {
        if let success = successMessage {
            Label(success, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if let error = errorMessage {
            StudyErrorLabel(message: error)
        }
    }
}

enum StudyTextHelpers {
    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func languageDisplay(_ code: String?) -> String? {
        guard let code = nonEmpty(code)?.lowercased() else { return nil }
        switch code {
        case "ja": return "日语"
        case "en": return "英语"
        case "ko": return "韩语"
        case "zh", "zh-hans", "zh-hant": return "中文"
        default: return code.uppercased()
        }
    }
}
