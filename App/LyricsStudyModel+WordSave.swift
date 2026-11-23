import Foundation
import ShinAppleKit
import ShinAppServices

// MARK: - 单词收录与出处快照写入

@MainActor
extension LyricsStudyModel {

    func saveCurrentWordFromPopover() {
        guard let popover = wordPopover else { return }
        let ai = popover.aiExplanation
        let local = popover.localResult
        let resolvedLemma = Self.nonEmpty(ai?.lemma) ?? Self.nonEmpty(local.lemma)
        let resolvedReading = Self.nonEmpty(ai?.reading)
            ?? Self.nonEmpty(popover.formattedDictionary?.phonetics)
        let resolvedPOS = Self.nonEmpty(ai?.partOfSpeech) ?? Self.nonEmpty(local.partOfSpeech)
        let resolvedGeneral = Self.nonEmpty(popover.draftGeneralMeaning)
            ?? Self.nonEmpty(ai?.generalMeaning)
            ?? Self.prefillMeaning(from: local, formatted: popover.formattedDictionary)
        let resolvedContextual = Self.nonEmpty(popover.draftContextualMeaning)
            ?? Self.nonEmpty(ai?.contextualMeaning)
            ?? ""

        saveWordToVocabulary(
            surface: popover.surface,
            lemma: resolvedLemma,
            reading: resolvedReading,
            partOfSpeech: resolvedPOS,
            language: local.detectedLanguage,
            generalMeaning: resolvedGeneral,
            contextualMeaning: resolvedContextual,
            examples: ai?.examples ?? [],
            userNote: Self.nonEmpty(popover.draftUserNote)
        )
    }

    func quickSaveWord(from selection: LyricsWordSelection) {
        guard !isInvalidated else { return }
        let local = studyService.lookupLocalWord(selection.surface, contextLine: selection.lineText)
        let formatted = LocalDictionaryFormatter.format(local)
        let generalMeaning = Self.prefillMeaning(from: local, formatted: formatted)
        let hints = trackHintProvider()

        wordSaveTask?.cancel()
        wordSaveSequence += 1
        let expectedSequence = wordSaveSequence
        let entry = VocabularyEntry(
            surface: selection.surface,
            lemma: Self.nonEmpty(local.lemma) ?? selection.surface,
            reading: Self.nonEmpty(formatted?.phonetics),
            language: Self.nonEmpty(local.detectedLanguage),
            partOfSpeech: Self.nonEmpty(local.partOfSpeech),
            generalMeaning: generalMeaning
        )
        let occurrence = VocabularyOccurrence(
            entryId: entry.id,
            lyricDocumentId: selection.documentId,
            lineId: selection.lineId,
            utf16Location: selection.utf16Location,
            utf16Length: selection.utf16Length,
            surfaceInLine: selection.surface,
            contextualMeaning: "",
            lineTextSnapshot: selection.lineText,
            lineTranslationSnapshot: selection.lineTranslation,
            startMsSnapshot: selection.startMs,
            trackKeyHint: hints.trackKey,
            trackTitleHint: hints.title,
            artistHint: hints.artist
        )
        let service = studyService
        wordSaveTask = Task { [weak self] in
            do {
                _ = try await service.saveWord(entry: entry, occurrence: occurrence)
                guard !Task.isCancelled, let self, !self.isInvalidated,
                      self.wordSaveSequence == expectedSequence else { return }
                self.onVocabularyChanged?()
                if self.selectionBar == selection {
                    self.quickSaveMessage = "已收录「\(selection.surface)」"
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isInvalidated,
                      self.wordSaveSequence == expectedSequence else { return }
                self.quickSaveMessage = "收录失败：\(Self.describeError(error))"
            }
        }
    }

    // 领域保存入口需同时接收词表核心字段与语境注解参数。
    // swiftlint:disable:next function_parameter_count
    func saveWordToVocabulary(
        surface: String,
        lemma: String?,
        reading: String?,
        partOfSpeech: String?,
        language: String?,
        generalMeaning: String,
        contextualMeaning: String,
        examples: [VocabularyExample],
        userNote: String?
    ) {
        guard !isInvalidated, var popover = wordPopover else { return }
        wordSaveTask?.cancel()
        wordSaveSequence += 1
        let expectedSequence = wordSaveSequence
        let targetPopoverId = popover.id
        let hints = trackHintProvider()

        let cleanSurface = Self.nonEmpty(surface) ?? popover.surface
        let cleanLemma = Self.nonEmpty(lemma) ?? cleanSurface
        let entry = VocabularyEntry(
            surface: cleanSurface,
            lemma: cleanLemma,
            reading: Self.nonEmpty(reading),
            language: Self.nonEmpty(language),
            partOfSpeech: Self.nonEmpty(partOfSpeech),
            generalMeaning: generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            examples: examples,
            userNote: Self.nonEmpty(userNote)
        )
        let occurrence = VocabularyOccurrence(
            entryId: entry.id,
            lyricDocumentId: popover.documentId,
            lineId: popover.lineId,
            utf16Location: popover.utf16Location,
            utf16Length: popover.utf16Length,
            surfaceInLine: popover.surface,
            contextualMeaning: contextualMeaning.trimmingCharacters(in: .whitespacesAndNewlines),
            lineTextSnapshot: popover.lineText,
            lineTranslationSnapshot: popover.lineTranslation,
            startMsSnapshot: popover.startMs,
            trackKeyHint: hints.trackKey,
            trackTitleHint: hints.title,
            artistHint: hints.artist
        )

        let wasAlreadySaved = popover.savedEntryId != nil
        popover.isSaving = true
        popover.saveErrorMessage = nil
        popover.saveSuccessMessage = nil
        wordPopover = popover

        let service = studyService
        wordSaveTask = Task { [weak self] in
            do {
                let saved = try await service.saveWord(entry: entry, occurrence: occurrence)
                guard !Task.isCancelled, let self, !self.isInvalidated,
                      self.wordSaveSequence == expectedSequence else { return }
                self.onVocabularyChanged?()
                guard var current = self.wordPopover, current.id == targetPopoverId else { return }
                current.isSaving = false
                current.savedEntryId = saved.id
                current.saveSuccessMessage = wasAlreadySaved
                    ? "已更新生词记录与本句出处"
                    : "已加入生词本并关联本句出处"
                current.saveErrorMessage = nil
                self.wordPopover = current
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isInvalidated,
                      self.wordSaveSequence == expectedSequence,
                      var current = self.wordPopover, current.id == targetPopoverId else { return }
                current.isSaving = false
                current.saveErrorMessage = Self.describeError(error)
                self.wordPopover = current
            }
        }
    }
}
