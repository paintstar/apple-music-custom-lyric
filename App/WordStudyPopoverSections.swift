import SwiftUI
import ShinAIProvider
import ShinAppleKit
import ShinAppServices

// MARK: - 划词弹窗头部区

struct WordStudyHeaderSection: View {
    let state: WordPopoverState
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.surface)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let phonetics = StudyTextHelpers.nonEmpty(state.formattedDictionary?.phonetics)
                        ?? StudyTextHelpers.nonEmpty(state.localResult.reading) {
                        Text(phonetics)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                saveCTAButton.fixedSize()
            }

            tagRow
            StudySaveStatusLabel(
                successMessage: state.saveSuccessMessage,
                errorMessage: state.saveErrorMessage
            )
        }
    }

    @ViewBuilder
    private var saveCTAButton: some View {
        if state.savedEntryId != nil {
            Button(action: onSave) {
                saveLabel("已收录", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.green)
            .disabled(state.isSaving)
            .help("已加入生词本，再次点击可更新本句出处")
        } else {
            Button(action: onSave) {
                saveLabel("加入生词本", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isSaving)
        }
    }

    private func saveLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(.medium))
            .opacity(state.isSaving ? 0 : 1)
            .overlay {
                if state.isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在保存")
                }
            }
    }

    @ViewBuilder
    private var tagRow: some View {
        let lemmaTag = StudyTextHelpers.nonEmpty(state.localResult.lemma).flatMap { $0 != state.surface ? $0 : nil }
        let posTag = StudyTextHelpers.nonEmpty(state.localResult.partOfSpeech)
        let langTag = StudyTextHelpers.languageDisplay(state.localResult.detectedLanguage)
        if lemmaTag != nil || posTag != nil || langTag != nil {
            StudyFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                if let lemmaTag {
                    metadataPill("原形 \(lemmaTag)")
                }
                if let posTag {
                    metadataPill(posTag)
                }
                if let langTag {
                    metadataPill(langTag)
                }
            }
        }
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - AI 语境解析区

struct WordStudyAISection: View {
    let state: WordPopoverState
    let isMock: Bool
    let missingKeyWarning: String?
    let onRequestAI: () -> Void
    let onOpenSettings: () -> Void

    private var canRequestAI: Bool {
        missingKeyWarning == nil || isMock
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("AI 语境解析", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if isMock {
                    StudyCapsuleBadge(text: "模拟模式", tint: .orange)
                }
                Spacer()
                if state.isLoadingAI {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text("解析中…")
                            .foregroundStyle(.secondary)
                    }
                } else if canRequestAI {
                    Button(state.aiExplanation == nil ? "解析当前歌词" : "重新解析", action: onRequestAI)
                        .buttonStyle(.bordered)
                } else {
                    Button("前往设置", action: onOpenSettings)
                        .buttonStyle(.bordered)
                }
            }

            if !state.isLoadingAI {
                if let error = state.aiErrorMessage {
                    StudyErrorLabel(message: error)
                }
                if let ai = state.aiExplanation {
                    resultCard(ai)
                } else if !canRequestAI {
                    Text("配置 AI 服务后即可解析歌词语境。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func resultCard(_ ai: AIWordExplanation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            resultDetail("在本句歌词中的含义", value: ai.contextualMeaning)
            if let general = StudyTextHelpers.nonEmpty(ai.generalMeaning) {
                resultDetail("通用释义", value: general)
            }
            if let lemma = StudyTextHelpers.nonEmpty(ai.lemma),
               lemma != state.surface, lemma != StudyTextHelpers.nonEmpty(state.localResult.lemma) {
                resultDetail("原形", value: lemma)
            }
            if let partOfSpeech = StudyTextHelpers.nonEmpty(ai.partOfSpeech),
               partOfSpeech != StudyTextHelpers.nonEmpty(state.localResult.partOfSpeech) {
                resultDetail("词性", value: partOfSpeech)
            }
            let localPhonetics = StudyTextHelpers.nonEmpty(state.formattedDictionary?.phonetics)
                ?? StudyTextHelpers.nonEmpty(state.localResult.reading)
            if let reading = StudyTextHelpers.nonEmpty(ai.reading),
               reading != localPhonetics {
                resultDetail("读音", value: reading)
            }
            if !ai.examples.isEmpty {
                examplesBlock(ai.examples)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultDetail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func examplesBlock(_ examples: [VocabularyExample]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("典型例句")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(examples.enumerated()), id: \.offset) { _, example in
                VStack(alignment: .leading, spacing: 3) {
                    Text(example.text)
                        .font(.body)
                        .textSelection(.enabled)
                    if let translation = StudyTextHelpers.nonEmpty(example.translation) {
                        Text(translation)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 本机离线词典结构化卡片区

struct WordStudyDictionarySection: View {
    let state: WordPopoverState
    @Binding var isExpanded: Bool
    var reduceMotion: Bool

    private let previewSectionLimit = 2
    private let previewSenseLimit = 3
    private let previewExampleLimit = 1
    private let cardShape = RoundedRectangle(cornerRadius: 14)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("本机离线词典")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            } icon: {
                Image(systemName: "book.closed")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            if let formatted = state.formattedDictionary, !formatted.sections.isEmpty {
                structuredContent(formatted.sections)
            } else if let definition = StudyTextHelpers.nonEmpty(state.formattedDictionary?.fallbackRawText)
                ?? StudyTextHelpers.nonEmpty(state.localResult.systemDefinition) {
                Text(definition)
                    .font(.title3)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("本机词典未找到释义。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: cardShape)
        .overlay {
            cardShape
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func structuredContent(_ sections: [DictionaryPOSSection]) -> some View {
        let previewSections = sections.prefix(previewSectionLimit)
        let visibleSections = isExpanded ? sections[...] : previewSections
        let hasMoreSenses = sections.count > previewSectionLimit
            || previewSections.contains { $0.senses.count > previewSenseLimit }
        let hasMoreExamples = previewSections.contains { section in
            section.senses.prefix(previewSenseLimit).contains { $0.examples.count > previewExampleLimit }
        }

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleSections) { section in
                if section.id != visibleSections.first?.id {
                    Divider()
                }
                sectionContent(section, showHeading: sections.count > 1 || !section.compactTag.isEmpty)
            }

            if hasMoreSenses || hasMoreExamples {
                Button {
                    if reduceMotion {
                        isExpanded.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isExpanded.toggle()
                        }
                    }
                } label: {
                    Label {
                        Text(isExpanded ? "收起" : (hasMoreSenses ? "展开全部释义" : "展开全部例句"))
                            .font(.body.weight(.medium))
                    } icon: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func sectionContent(_ section: DictionaryPOSSection, showHeading: Bool) -> some View {
        let visibleSenses = isExpanded ? section.senses[...] : section.senses.prefix(previewSenseLimit)
        return VStack(alignment: .leading, spacing: 10) {
            if showHeading {
                HStack(spacing: 8) {
                    Text(section.partOfSpeechLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if section.isContextMatch {
                        StudyCapsuleBadge(text: "匹配当前句", tint: .teal)
                    }
                }
            }

            ForEach(visibleSenses) { sense in
                senseRow(sense)
            }
        }
    }

    private func senseRow(_ sense: DictionarySenseItem) -> some View {
        let visibleExamples = isExpanded ? sense.examples[...] : sense.examples.prefix(previewExampleLimit)
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            if let number = StudyTextHelpers.nonEmpty(sense.numberLabel) {
                Text(number)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let qualifier = StudyTextHelpers.nonEmpty(sense.qualifier) {
                    Text(qualifier)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let definition = StudyTextHelpers.nonEmpty(sense.definition) {
                    Text(definition)
                        .font(.title3.weight(.semibold))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !visibleExamples.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(visibleExamples) { example in
                            Text(example.text)
                                .font(.body)
                                .lineSpacing(3)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.33))
                            .frame(width: 2)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}
