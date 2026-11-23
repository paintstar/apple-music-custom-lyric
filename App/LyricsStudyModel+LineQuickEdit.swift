import CoreGraphics
import Foundation
import ShinAppleData
import ShinAppleKit
import ShinAppServices

// MARK: - 单句歌词 / 注音 / 译文快捷编辑

@MainActor
extension LyricsStudyModel {

    private enum LineQuickEditCommitResult: Sendable {
        case saved
        case revisionConflict
    }

    func openLineQuickEdit(document: LyricDocument, lineId: UUID, anchorRect: CGRect) {
        guard !isInvalidated,
              let line = document.lines.first(where: { $0.id == lineId }) else { return }

        dismissWordPopover(clearSelection: false)
        dismissLinePopover(clearSelection: false)
        selectionBar = nil
        quickSaveMessage = nil
        lineEditSaveSequence += 1
        lineEditSaveTask?.cancel()
        lineEditSaveTask = nil

        let existingPronunciation = line.pronunciation
        let initialPronunciation = existingPronunciation?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hadInitialPronunciation = existingPronunciation != nil && !initialPronunciation.isEmpty
        let initialPronunciationStyle = existingPronunciation?.style
            ?? settingsStore.load().preferredPronunciationStyle
        let existingTranslation = line.translations[LyricsSyncConstants.translationLanguage]
        let initialTranslation = existingTranslation?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        lineEditPopover = LineQuickEditState(
            id: UUID(),
            documentId: document.id,
            documentRevision: document.revision,
            lineId: line.id,
            startMs: line.startMs,
            originalText: line.text,
            initialPronunciation: initialPronunciation,
            initialPronunciationStyle: initialPronunciationStyle,
            hadInitialPronunciation: hadInitialPronunciation,
            initialTranslation: initialTranslation,
            pronunciationNeedsReview: existingPronunciation?.needsReview ?? false,
            translationNeedsReview: existingTranslation?.needsReview ?? false,
            anchorRectInScrollViewport: anchorRect,
            draftText: line.text,
            draftPronunciation: initialPronunciation,
            draftPronunciationStyle: initialPronunciationStyle,
            draftTranslation: initialTranslation
        )
    }

    func dismissLineQuickEdit(clearSelection: Bool = true) {
        let hadPopover = lineEditPopover != nil
        lineEditSaveSequence += 1
        lineEditSaveTask?.cancel()
        lineEditSaveTask = nil
        lineEditPopover = nil
        if clearSelection && hadPopover {
            clearSelectionForDismissedPopover()
        }
    }

    func saveLineQuickEdit() {
        guard !isInvalidated, var state = lineEditPopover, !state.isSaving else { return }
        guard state.hasChanges else {
            dismissLineQuickEdit(clearSelection: true)
            return
        }

        lineEditSaveTask?.cancel()
        lineEditSaveSequence += 1
        let expectedSequence = lineEditSaveSequence
        let targetPopoverId = state.id

        state.isSaving = true
        state.errorMessage = nil
        lineEditPopover = state
        let snapshot = state
        let store = self.store

        lineEditSaveTask = Task { [weak self] in
            do {
                let result = try await Self.commitQuickEdit(snapshot, store: store)
                guard !Task.isCancelled, let self, !self.isInvalidated,
                      self.lineEditSaveSequence == expectedSequence else { return }
                switch result {
                case .revisionConflict:
                    guard var current = self.lineEditPopover, current.id == targetPopoverId else { return }
                    current.isSaving = false
                    current.errorMessage = "当前歌词已被其他编辑更新，请关闭后重新打开编辑。"
                    self.lineEditPopover = current
                case .saved:
                    self.onDocumentNoteSaved?()
                    if self.lineEditPopover?.id == targetPopoverId {
                        self.dismissLineQuickEdit(clearSelection: true)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isInvalidated,
                      self.lineEditSaveSequence == expectedSequence,
                      var current = self.lineEditPopover,
                      current.id == targetPopoverId else { return }
                current.isSaving = false
                current.errorMessage = Self.describeError(error)
                self.lineEditPopover = current
            }
        }
    }

    private static func commitQuickEdit(
        _ snapshot: LineQuickEditState,
        store: GRDBLyricsStore
    ) async throws -> LineQuickEditCommitResult {
        let editor = LyricsEditingService(store: store)
        do {
            let opened = try await editor.openEditor(documentId: snapshot.documentId)
            guard opened.baseRevision == snapshot.documentRevision else {
                await editor.closeEditor()
                return .revisionConflict
            }
            if snapshot.textChanged {
                try await editor.setLineText(lineId: snapshot.lineId, text: snapshot.draftText)
            }
            if snapshot.pronunciationChanged {
                try await editor.setPronunciation(
                    lineId: snapshot.lineId,
                    style: snapshot.draftPronunciationStyle,
                    text: snapshot.draftPronunciation
                )
            }
            if snapshot.translationChanged {
                try await editor.setTranslation(
                    lineId: snapshot.lineId,
                    language: LyricsSyncConstants.translationLanguage,
                    text: snapshot.trimmedTranslation
                )
            }
            try await editor.commitChanges()
            await editor.closeEditor()
            return .saved
        } catch {
            await editor.closeEditor()
            throw error
        }
    }
}
