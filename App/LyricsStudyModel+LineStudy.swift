import CoreGraphics
import Foundation
import ShinAIProvider
import ShinAppleKit
import ShinAppServices

// MARK: - 整句深度解析与学习笔记保存

@MainActor
extension LyricsStudyModel {

    func openLineStudy(document: LyricDocument, lineId: UUID, anchorRect: CGRect) {
        guard !isInvalidated,
              let line = document.lines.first(where: { $0.id == lineId }),
              !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        dismissWordPopover(clearSelection: false)
        dismissLineQuickEdit(clearSelection: false)
        cancelLineRequests()
        selectionBar = nil
        quickSaveMessage = nil
        activeLineSourceDocument = document

        let note = line.studyNote
        let translation = line.translations[LyricsSyncConstants.translationLanguage]?.text
        linePopover = LinePopoverState(
            id: UUID(),
            documentId: document.id,
            documentRevision: document.revision,
            lineId: line.id,
            lineText: line.text,
            lineTranslation: translation,
            startMs: line.startMs,
            anchorRectInScrollViewport: anchorRect,
            existingNote: note,
            draftGrammarSummary: note?.grammarSummary ?? "",
            draftSingingTips: note?.singingTips ?? "",
            draftCulturalNote: note?.culturalNote ?? ""
        )

        if note == nil, missingKeyWarning == nil {
            requestAILineExplanation()
        }
    }

    func dismissLinePopover(clearSelection: Bool = true) {
        let hadPopover = linePopover != nil
        cancelLineRequests()
        activeLineSourceDocument = nil
        linePopover = nil
        if clearSelection && hadPopover {
            clearSelectionForDismissedPopover()
        }
    }

    func requestAILineExplanation() {
        guard !isInvalidated,
              var popover = linePopover,
              let document = activeLineSourceDocument,
              document.id == popover.documentId else { return }

        lineAITask?.cancel()
        lineRequestSequence += 1
        let expectedSequence = lineRequestSequence
        let targetPopoverId = popover.id
        let targetDocumentId = popover.documentId
        let targetLineId = popover.lineId
        let hints = trackHintProvider()

        popover.isLoadingAI = true
        popover.aiErrorMessage = nil
        linePopover = popover

        let service = studyService
        lineAITask = Task { [weak self] in
            do {
                let explanation = try await service.explainLineWithAI(
                    document: document,
                    lineId: targetLineId,
                    songTitle: hints.title,
                    artist: hints.artist
                )
                guard !Task.isCancelled, let self, !self.isInvalidated,
                      self.lineRequestSequence == expectedSequence,
                      var current = self.linePopover,
                      current.id == targetPopoverId,
                      current.documentId == targetDocumentId,
                      current.lineId == targetLineId else { return }
                current.isLoadingAI = false
                current.aiExplanation = explanation
                current.aiErrorMessage = nil
                current.draftGrammarSummary = Self.composedGrammarSummary(from: explanation)
                current.draftSingingTips = explanation.singingTips ?? ""
                current.draftCulturalNote = explanation.culturalNote ?? ""
                current.usedAIForDraft = true
                current.hasEditedAfterAI = false
                self.linePopover = current
            } catch is CancellationError {
                self?.finishCancelledLineAI(expectedSequence: expectedSequence, popoverId: targetPopoverId)
            } catch let error as AIStudyWorkflowError where error == .cancelled {
                self?.finishCancelledLineAI(expectedSequence: expectedSequence, popoverId: targetPopoverId)
            } catch {
                guard let self, !self.isInvalidated,
                      self.lineRequestSequence == expectedSequence,
                      var current = self.linePopover,
                      current.id == targetPopoverId else { return }
                current.isLoadingAI = false
                current.aiErrorMessage = Self.describeError(error)
                self.linePopover = current
            }
        }
    }

    func saveLineStudyNote() {
        guard !isInvalidated, var popover = linePopover, !popover.isSavingNote else { return }
        guard let cleanGrammar = Self.nonEmpty(popover.draftGrammarSummary) else {
            popover.saveErrorMessage = "语法拆解摘要不能为空。"
            linePopover = popover
            return
        }

        lineSaveTask?.cancel()
        lineSaveSequence += 1
        let expectedSequence = lineSaveSequence
        let targetPopoverId = popover.id
        let source: StudyAnnotationSource = (popover.usedAIForDraft && !popover.hasEditedAfterAI)
            ? .ai(model: activeModelName())
            : .manual()

        let note = LineStudyNote(
            grammarSummary: cleanGrammar,
            singingTips: Self.nonEmpty(popover.draftSingingTips),
            culturalNote: Self.nonEmpty(popover.draftCulturalNote),
            source: source,
            needsReview: false
        )

        popover.isSavingNote = true
        popover.saveErrorMessage = nil
        popover.saveSuccessMessage = nil
        linePopover = popover

        let service = studyService
        lineSaveTask = Task { [weak self] in
            do {
                let updatedDoc = try await service.saveLineStudyNote(
                    documentId: popover.documentId,
                    expectedRevision: popover.documentRevision,
                    lineId: popover.lineId,
                    note: note
                )
                guard !Task.isCancelled, let self, !self.isInvalidated,
                      self.lineSaveSequence == expectedSequence else { return }
                if self.activeLineSourceDocument?.id == updatedDoc.id {
                    self.activeLineSourceDocument = updatedDoc
                }
                self.onDocumentNoteSaved?()
                guard var current = self.linePopover, current.id == targetPopoverId else { return }
                current.documentRevision = updatedDoc.revision
                current.existingNote = updatedDoc.lines.first(where: { $0.id == current.lineId })?.studyNote
                current.isSavingNote = false
                current.saveSuccessMessage = "已保存到本句笔记"
                current.saveErrorMessage = nil
                self.linePopover = current
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isInvalidated,
                      self.lineSaveSequence == expectedSequence,
                      var current = self.linePopover, current.id == targetPopoverId else { return }
                current.isSavingNote = false
                current.saveErrorMessage = Self.describeError(error)
                self.linePopover = current
            }
        }
    }

    func cancelLineRequests() {
        lineRequestSequence += 1
        lineAITask?.cancel()
        lineAITask = nil
    }

    private func finishCancelledLineAI(expectedSequence: Int, popoverId: UUID) {
        guard !isInvalidated,
              lineRequestSequence == expectedSequence,
              var current = linePopover,
              current.id == popoverId else { return }
        current.isLoadingAI = false
        linePopover = current
    }

    private func activeModelName() -> String? {
        if isMock { return "mock-study" }
        return Self.nonEmpty(settingsStore.load().modelName)
    }

    static func prefillMeaning(from result: LocalDictionaryLookupResult) -> String {
        prefillMeaning(from: result, formatted: LocalDictionaryFormatter.format(result))
    }

    static func prefillMeaning(
        from result: LocalDictionaryLookupResult,
        formatted: FormattedDictionaryEntry?
    ) -> String {
        if let concise = nonEmpty(formatted?.conciseMeaning) {
            return concise
        }
        guard let definition = nonEmpty(result.systemDefinition) else { return "" }
        let compact = definition
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if compact.count <= 85 { return compact }
        return String(compact.prefix(84)) + "…"
    }

    static func composedGrammarSummary(from explanation: AILineExplanation) -> String {
        let base = explanation.grammarSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let expressions = explanation.keyExpressions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !expressions.isEmpty else { return base }
        return "\(base)\n\n重点表达：\(expressions.joined(separator: " · "))"
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func describeError(_ error: Error) -> String {
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError.message
        }
        return ErrorText.describe(error)
    }
}
