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
        activeLineProviderConfiguration = settingsStore.load()

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

        if note == nil {
            requestAILineExplanation(useCache: true)
        }
    }

    func dismissLinePopover(clearSelection: Bool = true) {
        let hadPopover = linePopover != nil
        cancelLineRequests()
        activeLineSourceDocument = nil
        activeLineProviderConfiguration = nil
        linePopover = nil
        if clearSelection && hadPopover {
            clearSelectionForDismissedPopover()
        }
    }

    func requestAILineExplanation(useCache: Bool = false) {
        reconcileLineStudyConfiguration()
        guard !isInvalidated,
              var popover = linePopover,
              let document = activeLineSourceDocument,
              let configuration = activeLineProviderConfiguration,
              document.id == popover.documentId else { return }

        cancelLineRequests()
        let expectedSequence = lineRequestSequence
        let targetPopoverId = popover.id
        let targetLineId = popover.lineId

        popover.isLoadingAI = true
        popover.aiErrorMessage = nil
        popover.isAskingFollowUp = false
        popover.followUps = []
        popover.followUpErrorMessage = nil
        linePopover = popover

        let service = studyService
        lineAITask = Task { [weak self] in
            do {
                let explanation = try await service.explainLineWithAI(
                    document: document,
                    lineId: targetLineId,
                    useCache: useCache,
                    configuration: configuration
                )
                guard let self,
                      var current = self.currentLineRequest(sequence: expectedSequence, popoverId: targetPopoverId)
                else { return }
                current.isLoadingAI = false
                current.aiExplanation = explanation
                current.aiErrorMessage = nil
                if current.existingNote == nil, !current.hasEditedAfterAI,
                   current.usedAIForDraft || [
                       current.draftGrammarSummary, current.draftSingingTips, current.draftCulturalNote
                   ].allSatisfy({ Self.nonEmpty($0) == nil }) {
                    current.draftGrammarSummary = Self.composedGrammarSummary(from: explanation)
                    current.draftSingingTips = explanation.singingTips ?? ""
                    current.draftCulturalNote = explanation.culturalNote ?? ""
                    current.usedAIForDraft = true
                    current.aiDraftModel = self.isMock ? "mock-study" : Self.nonEmpty(configuration.modelName)
                }
                self.linePopover = current
            } catch {
                guard let self,
                      var current = self.currentLineRequest(sequence: expectedSequence, popoverId: targetPopoverId)
                else { return }
                current.isLoadingAI = false
                if (error as? AIStudyWorkflowError) != .cancelled {
                    current.aiErrorMessage = Self.describeError(error)
                }
                self.linePopover = current
            }
        }
    }

    func submitLineFollowUp() {
        reconcileLineStudyConfiguration()
        guard !isInvalidated,
              var popover = linePopover,
              !popover.isLoadingAI, !popover.isAskingFollowUp,
              let question = Self.nonEmpty(popover.questionDraft),
              let document = activeLineSourceDocument,
              let configuration = activeLineProviderConfiguration,
              document.id == popover.documentId else { return }

        lineRequestSequence += 1
        let expectedSequence = lineRequestSequence
        let targetPopoverId = popover.id
        let lineId = popover.lineId
        let analysis = popover.aiExplanation
        let history = popover.followUps.suffix(3).map(\.turn)
        let service = studyService
        popover.isAskingFollowUp = true
        popover.followUpErrorMessage = nil
        linePopover = popover

        lineFollowUpTask = Task { [weak self] in
            do {
                let answer = try await service.followUpLineWithAI(
                    document: document,
                    lineId: lineId,
                    analysis: analysis,
                    history: history,
                    question: question,
                    configuration: configuration
                )
                guard let self,
                      var current = self.currentLineRequest(sequence: expectedSequence, popoverId: targetPopoverId)
                else { return }
                current.isAskingFollowUp = false
                current.questionDraft = ""
                current.followUps.append(LineFollowUpItem(turn: AILineFollowUpTurn(
                    question: question, answer: answer
                )))
                self.linePopover = current
            } catch {
                guard let self,
                      var current = self.currentLineRequest(sequence: expectedSequence, popoverId: targetPopoverId)
                else { return }
                current.isAskingFollowUp = false
                if (error as? AIStudyWorkflowError) != .cancelled {
                    current.followUpErrorMessage = Self.describeError(error)
                }
                self.linePopover = current
            }
        }
    }

    func addFollowUpToLineNote(id: UUID) {
        reconcileLineStudyConfiguration()
        guard var popover = linePopover, !popover.isSavingNote,
              let index = popover.followUps.firstIndex(where: { $0.id == id }),
              !popover.followUps[index].isInNoteDraft else { return }
        let turn = popover.followUps[index].turn
        let block = "追问：\(turn.question)\n回答：\(turn.answer)"
        let summary = popover.draftGrammarSummary
        if let marker = summary.range(of: LineDisplayContent.keyExpressionsMarker, options: .backwards) {
            let leading = Self.nonEmpty(String(summary[..<marker.lowerBound]))
            popover.draftGrammarSummary = [leading, block].compactMap { $0 }.joined(separator: "\n\n")
                + summary[marker.lowerBound...]
        } else {
            popover.draftGrammarSummary = [Self.nonEmpty(summary), block].compactMap { $0 }.joined(separator: "\n\n")
        }
        popover.followUps[index].isInNoteDraft = true
        popover.hasEditedAfterAI = true
        popover.saveErrorMessage = nil
        popover.saveSuccessMessage = nil
        linePopover = popover
    }

    func reconcileLineStudyDocument(_ document: LyricDocument) {
        guard let popover = linePopover, let source = activeLineSourceDocument,
              document.id == source.id else { return }
        let currentInput = LyricsStudyService.lineInput(document: document, lineId: popover.lineId)
        let openedInput = LyricsStudyService.lineInput(document: source, lineId: popover.lineId)
        if currentInput != openedInput {
            dismissLinePopover()
        }
    }

    @discardableResult
    func reconcileLineStudyConfiguration() -> Bool {
        guard let previous = activeLineProviderConfiguration, var popover = linePopover else { return false }
        let configuration = settingsStore.load()
        guard configuration.preset != previous.preset
                || configuration.baseURLString != previous.baseURLString
                || configuration.modelName != previous.modelName
                || configuration.preferredTargetLanguage != previous.preferredTargetLanguage
        else { return false }

        cancelLineRequests()
        activeLineProviderConfiguration = configuration
        // 旧解析仍可在草稿中阅读。新请求只用新服务对应的解析和历史。
        popover.aiExplanation = nil
        popover.aiErrorMessage = nil
        popover.isLoadingAI = false
        popover.followUps = []
        popover.isAskingFollowUp = false
        popover.followUpErrorMessage = nil
        linePopover = popover
        return true
    }

    private func currentLineRequest(sequence: Int, popoverId: UUID) -> LinePopoverState? {
        guard !Task.isCancelled, !isInvalidated, lineRequestSequence == sequence,
              let current = linePopover, current.id == popoverId,
              !reconcileLineStudyConfiguration() else { return nil }
        return current
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
            ? .ai(model: popover.aiDraftModel)
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
        lineFollowUpTask?.cancel()
        lineFollowUpTask = nil
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
        return "\(base)\(LineDisplayContent.keyExpressionsMarker)\(expressions.joined(separator: " · "))"
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
