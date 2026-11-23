import SwiftUI
import ShinAppleKit

// MARK: - 共享高亮与徽标助手

enum VocabularyTextHighlight {
    static func attributedLine(for occurrence: VocabularyOccurrence) -> AttributedString {
        let line = occurrence.lineTextSnapshot
        var attributed = AttributedString(line)
        guard !line.isEmpty else { return attributed }

        if let range = matchedRange(in: line, occurrence: occurrence),
           let attrRange = Range(range, in: attributed) {
            attributed[attrRange].foregroundColor = Color.appleMusicPink
            attributed[attrRange].font = .body.weight(.semibold)
            attributed[attrRange].backgroundColor = Color.appleMusicPink.opacity(0.12)
        }
        return attributed
    }

    private static func matchedRange(
        in line: String,
        occurrence: VocabularyOccurrence
    ) -> Range<String.Index>? {
        let nsLine = line as NSString
        if occurrence.utf16Length > 0,
           occurrence.utf16Location >= 0,
           occurrence.utf16Location + occurrence.utf16Length <= nsLine.length {
            let nsRange = NSRange(location: occurrence.utf16Location, length: occurrence.utf16Length)
            if let range = Range(nsRange, in: line) {
                let slice = String(line[range])
                if slice.caseInsensitiveCompare(occurrence.surfaceInLine) == .orderedSame
                    || occurrence.surfaceInLine.isEmpty {
                    return range
                }
            }
        }
        let target = occurrence.surfaceInLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return line.range(of: target, options: .caseInsensitive)
    }
}

// swiftlint:disable inclusive_language
struct VocabularyMasteryBadge: View {
    let mastery: VocabularyMastery

    var body: some View {
        Text(mastery.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tintColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tintColor.opacity(0.14), in: Capsule())
    }

    private var tintColor: Color {
        switch mastery {
        case .learning: return .orange
        case .reviewing: return .blue
        case .mastered: return .green
        }
    }
}
// swiftlint:enable inclusive_language

// MARK: - 右侧单词详情与原声例句区

struct VocabularyEntryDetailView: View {
    private enum DetailField: Hashable {
        case reading
        case partOfSpeech
        case generalMeaning
        case userNote
    }

    @ObservedObject var book: VocabularyBookModel
    let entry: VocabularyEntry
    var bottomContentInset: CGFloat = 96
    let onRequestDelete: (VocabularyEntry) -> Void

    @State private var draftReading = ""
    @State private var draftPartOfSpeech = ""
    @State private var draftGeneralMeaning = ""
    @State private var draftUserNote = ""
    @State private var syncedEntryId: UUID?
    @State private var syncedUpdatedAt: String?
    @FocusState private var focusedField: DetailField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                metadataEditSection
                meaningAndNoteSection
                if !entry.examples.isEmpty {
                    examplesSection
                }
                occurrencesSection
            }
            .padding(24)
            .padding(.bottom, bottomContentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncDrafts(force: true) }
        .onChange(of: entry.id) { _, _ in syncDrafts(force: true) }
        .onChange(of: entry.updatedAt) { _, _ in
            if !hasUnsavedChanges { syncDrafts(force: true) }
        }
        .onChange(of: focusedField) { previous, current in
            if previous != nil, current == nil, hasUnsavedChanges {
                saveDrafts()
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.surface)
                        .font(.system(size: 26, weight: .bold))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let lemma = normalizedLemmaHint {
                            infoChip("原型：\(lemma)", tint: .accentColor)
                        }
                        if let language = VocabularyBookModel.languageDisplayName(entry.language) {
                            infoChip(language, tint: .secondary)
                        }
                        if let pos = VocabularyBookModel.nonEmptyTrimmed(entry.partOfSpeech) {
                            infoChip(pos, tint: .teal)
                        }
                    }
                }
                Spacer(minLength: 12)
                Button(role: .destructive) {
                    focusedField = nil
                    onRequestDelete(entry)
                } label: {
                    Label("删除词条", systemImage: "trash")
                }
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                Text("掌握程度")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("掌握程度", selection: masteryBinding) {
                    ForEach(VocabularyMastery.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 250)
            }
        }
    }

    private var metadataEditSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("读音标注")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("如假名、音标或罗马音", text: $draftReading)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .reading)
                    .onSubmit { saveDrafts() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("词性")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("如名词、动词、形容词", text: $draftPartOfSpeech)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .partOfSpeech)
                    .onSubmit { saveDrafts() }
            }
        }
    }

    private var meaningAndNoteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("释义与学习笔记")
                    .font(.headline)
                Spacer()
                if hasUnsavedChanges {
                    Button("还原") {
                        syncDrafts(force: true)
                        focusedField = nil
                    }
                    .controlSize(.small)
                    Button("保存修改") {
                        saveDrafts()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(book.isMutating)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("通用释义")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("填写词语通用释义", text: $draftGeneralMeaning, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .focused($focusedField, equals: .generalMeaning)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("个人笔记")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("记录词义辨析、语法要点或记忆技巧……", text: $draftUserNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .focused($focusedField, equals: .userNote)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通用例句")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entry.examples.enumerated()), id: \.offset) { _, example in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(example.text)
                            .font(.callout)
                            .textSelection(.enabled)
                        if let translation = VocabularyBookModel.nonEmptyTrimmed(example.translation) {
                            Text(translation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var occurrencesSection: some View {
        let occurrences = book.occurrences(for: entry.id)
        return VStack(alignment: .leading, spacing: 10) {
            Text("在歌曲中出现过的原声例句（\(occurrences.count)）")
                .font(.headline)
            if occurrences.isEmpty {
                Text("暂无关联的歌曲原声出处，可在歌词面板划词并收录到本词条。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(occurrences) { occurrence in
                    VocabularyOccurrenceCard(
                        occurrence: occurrence,
                        isPlaying: book.playingOccurrenceId == occurrence.id,
                        isPlaybackBusy: book.playingOccurrenceId != nil,
                        onPlay: { book.playOccurrence(occurrence) },
                        onRemove: { book.deleteOccurrence(occurrence.id) }
                    )
                }
            }
        }
    }

    // swiftlint:disable inclusive_language
    private var masteryBinding: Binding<VocabularyMastery> {
        Binding(
            get: { entry.mastery },
            set: { book.updateMastery($0, for: entry) }
        )
    }
    // swiftlint:enable inclusive_language

    private var normalizedLemmaHint: String? {
        guard let lemma = VocabularyBookModel.nonEmptyTrimmed(entry.lemma),
              lemma != entry.surface else { return nil }
        return lemma
    }

    private var hasUnsavedChanges: Bool {
        VocabularyBookModel.nonEmptyTrimmed(draftReading) != VocabularyBookModel.nonEmptyTrimmed(entry.reading)
            || VocabularyBookModel.nonEmptyTrimmed(draftPartOfSpeech) != VocabularyBookModel.nonEmptyTrimmed(entry.partOfSpeech)
            || draftGeneralMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
                != entry.generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
            || VocabularyBookModel.nonEmptyTrimmed(draftUserNote) != VocabularyBookModel.nonEmptyTrimmed(entry.userNote)
    }

    private func syncDrafts(force: Bool) {
        guard force || syncedEntryId != entry.id || syncedUpdatedAt != entry.updatedAt else { return }
        draftReading = entry.reading ?? ""
        draftPartOfSpeech = entry.partOfSpeech ?? ""
        draftGeneralMeaning = entry.generalMeaning
        draftUserNote = entry.userNote ?? ""
        syncedEntryId = entry.id
        syncedUpdatedAt = entry.updatedAt
    }

    private func saveDrafts() {
        book.updateEntryDetails(
            entryId: entry.id,
            reading: draftReading,
            partOfSpeech: draftPartOfSpeech,
            generalMeaning: draftGeneralMeaning,
            userNote: draftUserNote
        )
    }

    private func infoChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - 原声例句卡片

private struct VocabularyOccurrenceCard: View {
    let occurrence: VocabularyOccurrence
    let isPlaying: Bool
    let isPlaybackBusy: Bool
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(trackTitleLine, systemImage: "music.note")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timestampText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(occurrence.startMsSnapshot != nil ? Color.appleMusicPink : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        (occurrence.startMsSnapshot != nil ? Color.appleMusicPink : Color.secondary).opacity(0.12),
                        in: Capsule()
                    )
            }

            Text(VocabularyTextHighlight.attributedLine(for: occurrence))
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let translation = VocabularyBookModel.nonEmptyTrimmed(occurrence.lineTranslationSnapshot) {
                Text(translation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let contextual = VocabularyBookModel.nonEmptyTrimmed(occurrence.contextualMeaning) {
                HStack(alignment: .top, spacing: 6) {
                    Text("语境释义")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.12), in: Capsule())
                    Text(contextual)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button(action: onPlay) {
                    if isPlaying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在定位播放……")
                        }
                    } else {
                        Label("播放原声例句", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPlaybackBusy)

                Spacer()

                Button("移除此出处", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private var trackTitleLine: String {
        VocabularyBookModel.trackAttributionText(for: occurrence, fallback: "未知曲目")
    }

    private var timestampText: String {
        guard let startMs = occurrence.startMsSnapshot else { return "未打轴" }
        return "[\(VocabularyBookModel.formatTimestampMMSS(startMs))]"
    }
}
