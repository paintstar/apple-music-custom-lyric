import SwiftUI
import ShinAppleKit

/// 整句歌词深度解析与笔记保存 Popover：阅读态与编辑态分离，避免开窗聚焦边框与重复图标。
struct LineStudyPopoverView: View {
    @ObservedObject var studyModel: LyricsStudyModel
    let initialState: LinePopoverState

    @State private var isEditing = false

    private var state: LinePopoverState {
        studyModel.linePopover?.id == initialState.id ? (studyModel.linePopover ?? initialState) : initialState
    }

    private var hasReadableContent: Bool {
        state.aiExplanation != nil
            || state.existingNote != nil
            || StudyTextHelpers.nonEmpty(state.draftGrammarSummary) != nil
    }

    private var canUseAI: Bool {
        studyModel.missingKeyWarning == nil || studyModel.isMock
    }

    private var grammarBinding: Binding<String> {
        Binding(
            get: { state.draftGrammarSummary },
            set: { newValue in
                guard var current = studyModel.linePopover,
                      current.id == initialState.id,
                      newValue != current.draftGrammarSummary else { return }
                current.draftGrammarSummary = newValue
                if current.usedAIForDraft { current.hasEditedAfterAI = true }
                current.saveSuccessMessage = nil
                studyModel.linePopover = current
            }
        )
    }

    private var singingTipsBinding: Binding<String> {
        Binding(
            get: { state.draftSingingTips },
            set: { newValue in
                guard var current = studyModel.linePopover,
                      current.id == initialState.id,
                      newValue != current.draftSingingTips else { return }
                current.draftSingingTips = newValue
                if current.usedAIForDraft { current.hasEditedAfterAI = true }
                current.saveSuccessMessage = nil
                studyModel.linePopover = current
            }
        )
    }

    private var culturalNoteBinding: Binding<String> {
        Binding(
            get: { state.draftCulturalNote },
            set: { newValue in
                guard var current = studyModel.linePopover,
                      current.id == initialState.id,
                      newValue != current.draftCulturalNote else { return }
                current.draftCulturalNote = newValue
                if current.usedAIForDraft { current.hasEditedAfterAI = true }
                current.saveSuccessMessage = nil
                studyModel.linePopover = current
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                lineQuoteCard
                Divider()
                studyContentSection
                Divider()
                footerSection
            }
            .padding(14)
        }
        .frame(width: 396)
        .frame(maxHeight: 520)
        .onChange(of: state.id) { _, _ in
            isEditing = false
        }
        .onChange(of: state.aiExplanation) { _, newValue in
            if newValue != nil { isEditing = false }
        }
        .onChange(of: state.saveSuccessMessage) { _, newValue in
            if newValue != nil { isEditing = false }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 6) {
            Label("整句学习解析", systemImage: "text.book.closed")
                .font(.headline)
            if let note = state.existingNote {
                sourceBadge(note.source)
                if note.needsReview {
                    StudyCapsuleBadge(text: "待复核", tint: .orange, backgroundOpacity: 0.16)
                }
            } else if studyModel.isMock {
                StudyCapsuleBadge(text: "模拟模式", tint: .orange, backgroundOpacity: 0.16)
            }
            Spacer()
            Button {
                studyModel.dismissLinePopover()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var lineQuoteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.lineText)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let translation = StudyTextHelpers.nonEmpty(state.lineTranslation) {
                Text(translation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var studyContentSection: some View {
        if state.isLoadingAI {
            StudyLoadingBanner(message: "正在解析本句语法、重点表达与唱法贴士…")
        } else if isEditing {
            LineStudyEditingSection(
                state: state,
                hasReadableContent: hasReadableContent,
                canUseAI: canUseAI,
                grammarBinding: grammarBinding,
                singingTipsBinding: singingTipsBinding,
                culturalNoteBinding: culturalNoteBinding,
                onRequestAI: { studyModel.requestAILineExplanation() },
                onFinishEditing: { isEditing = false }
            )
        } else if hasReadableContent {
            readingSection
        } else {
            LineStudyEmptyCard(
                canUseAI: canUseAI,
                errorMessage: state.aiErrorMessage,
                onOpenSettings: openSettings,
                onRequestAI: { studyModel.requestAILineExplanation() },
                onStartManualEdit: { isEditing = true }
            )
        }
    }

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if canUseAI {
                    Button {
                        studyModel.requestAILineExplanation()
                    } label: {
                        Label("重新用 AI 解析本句", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("前往设置配置 AI…", action: openSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    isEditing = true
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let error = state.aiErrorMessage {
                StudyErrorLabel(message: error)
            }

            LineStudyReadCardsView(content: resolvedDisplayContent)
        }
    }

    private var footerSection: some View {
        HStack(spacing: 8) {
            StudySaveStatusLabel(
                successMessage: state.saveSuccessMessage,
                errorMessage: state.saveErrorMessage
            )
            Spacer(minLength: 4)
            Button {
                studyModel.saveLineStudyNote()
            } label: {
                if state.isSavingNote {
                    ProgressView().controlSize(.small)
                } else {
                    Text("保存到本句笔记")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                state.isSavingNote
                    || state.draftGrammarSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private var resolvedDisplayContent: LineDisplayContent {
        if let ai = state.aiExplanation, !state.hasEditedAfterAI {
            return LineDisplayContent(
                grammarSummary: ai.grammarSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                keyExpressions: ai.keyExpressions.compactMap(StudyTextHelpers.nonEmpty),
                singingTips: StudyTextHelpers.nonEmpty(state.draftSingingTips),
                culturalNote: StudyTextHelpers.nonEmpty(state.draftCulturalNote)
            )
        }
        let rawGrammar = state.draftGrammarSummary
        let marker = "\n\n重点表达："
        if let range = rawGrammar.range(of: marker) {
            let summary = String(rawGrammar[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let expressions = String(rawGrammar[range.upperBound...])
                .components(separatedBy: " · ")
                .compactMap(StudyTextHelpers.nonEmpty)
            return LineDisplayContent(
                grammarSummary: summary,
                keyExpressions: expressions,
                singingTips: StudyTextHelpers.nonEmpty(state.draftSingingTips),
                culturalNote: StudyTextHelpers.nonEmpty(state.draftCulturalNote)
            )
        }
        return LineDisplayContent(
            grammarSummary: rawGrammar.trimmingCharacters(in: .whitespacesAndNewlines),
            keyExpressions: [],
            singingTips: StudyTextHelpers.nonEmpty(state.draftSingingTips),
            culturalNote: StudyTextHelpers.nonEmpty(state.draftCulturalNote)
        )
    }

    private func openSettings() {
        studyModel.dismissLinePopover()
        NotificationCenter.default.post(name: .shinSelectSettingsPage, object: SettingsCategory.aiStudy)
    }

    private func sourceBadge(_ source: StudyAnnotationSource) -> some View {
        let label: String
        let tint: Color
        switch source.kind {
        case .manual:
            label = "人工笔记"
            tint = .teal
        case .ai:
            label = source.model.map { "AI · \($0)" } ?? "AI 解析"
            tint = .accentColor
        case .imported:
            label = "导入笔记"
            tint = .secondary
        }
        return StudyCapsuleBadge(text: label, tint: tint)
    }
}

private struct LineDisplayContent {
    let grammarSummary: String
    let keyExpressions: [String]
    let singingTips: String?
    let culturalNote: String?
}

private struct LineStudyEmptyCard: View {
    let canUseAI: Bool
    let errorMessage: String?
    let onOpenSettings: () -> Void
    let onRequestAI: () -> Void
    let onStartManualEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                StudyErrorLabel(message: errorMessage)
            }

            if !canUseAI {
                VStack(alignment: .leading, spacing: 6) {
                    Label("尚未配置 AI 学习服务密钥", systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                    Text("配置 DeepSeek / OpenAI 等密钥后可自动生成句法拆解与唱法贴士，也可直接手动记录本句笔记。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("前往设置配置 AI…", action: onOpenSettings)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("手动编写笔记", action: onStartManualEdit)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 8) {
                    Button(action: onRequestAI) {
                        Label("AI 解析本句", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("手动编写笔记", action: onStartManualEdit)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct LineStudyEditingSection: View {
    let state: LinePopoverState
    let hasReadableContent: Bool
    let canUseAI: Bool
    let grammarBinding: Binding<String>
    let singingTipsBinding: Binding<String>
    let culturalNoteBinding: Binding<String>
    let onRequestAI: () -> Void
    let onFinishEditing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if canUseAI {
                    Button(action: onRequestAI) {
                        Label(
                            hasReadableContent ? "重新用 AI 解析本句" : "AI 解析本句",
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(state.isLoadingAI)
                }
                Spacer()
                Button(hasReadableContent ? "完成" : "返回", action: onFinishEditing)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let error = state.aiErrorMessage {
                StudyErrorLabel(message: error)
            }

            StudyLabeledTextField(
                title: "语法拆解",
                placeholder: "语法结构、助词与重点表达……",
                text: grammarBinding,
                titleFont: .caption.weight(.semibold),
                font: .callout,
                lineLimit: 2...6
            )

            if let expressions = state.aiExplanation?.keyExpressions.compactMap(StudyTextHelpers.nonEmpty),
               !expressions.isEmpty,
               !state.hasEditedAfterAI {
                VStack(alignment: .leading, spacing: 4) {
                    Text("重点表达")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    StudyFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Array(expressions.enumerated()), id: \.offset) { _, expr in
                            StudyCapsuleBadge(text: expr, tint: .teal)
                        }
                    }
                }
            }

            StudyLabeledTextField(
                title: "演唱连读 / 唱法贴士",
                placeholder: "连读、弱读或断句参考（可选）",
                text: singingTipsBinding,
                titleFont: .caption.weight(.semibold),
                font: .caption,
                lineLimit: 1...3,
                footnote: "仅供参考，不代表实际唱法"
            )

            StudyLabeledTextField(
                title: "文化背景",
                placeholder: "意象背景或语境补充（可选）",
                text: culturalNoteBinding,
                titleFont: .caption.weight(.semibold),
                font: .caption,
                lineLimit: 1...3
            )
        }
    }
}

private struct LineStudyReadCardsView: View {
    let content: LineDisplayContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !content.grammarSummary.isEmpty {
                layeredCard(title: "语法拆解") {
                    Text(content.grammarSummary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !content.keyExpressions.isEmpty {
                layeredCard(title: "重点表达") {
                    StudyFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Array(content.keyExpressions.enumerated()), id: \.offset) { _, expr in
                            StudyCapsuleBadge(text: expr, tint: .teal)
                        }
                    }
                }
            }

            if let tips = content.singingTips {
                layeredCard(title: "演唱连读 / 唱法贴士", subtitle: "仅供参考，不代表实际唱法") {
                    Text(tips)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let cultural = content.culturalNote {
                layeredCard(title: "文化背景") {
                    Text(cultural)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func layeredCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
