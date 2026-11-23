import AppKit
import ShinAppleKit

/// `LyricsScrollView` 的学习标记同步、划词坐标转换与右键菜单目标解析扩展。
@MainActor
extension LyricsScrollView {
    struct StudyMarksKey: Equatable {
        let documentId: UUID
        let documentRevision: Int
        let occurrences: [VocabularyOccurrence]
        let isClozeMode: Bool
    }

    func installStudyCallbacks() {
        textLayout.textView.drawStudyIndicators = { [weak self] dirtyRect in
            self?.textLayout.drawStudyNoteIndicators(in: dirtyRect)
            self?.textLayout.drawClozeMasks(in: dirtyRect)
        }
        textLayout.textView.onSelectionChanged = { [weak self] range in
            self?.handleSelectionRangeChanged(range)
        }
        textLayout.textView.resolveContextMenuWord = { [weak self] in
            self?.currentWordSelection()
        }
        textLayout.textView.resolveContextMenuLine = { [weak self] point in
            self?.contextLineTarget(at: point)
        }
        textLayout.textView.resolveLineLoopMenuState = { [weak self] lineId in
            self?.configuration?.resolveLineLoopMenuState?(lineId)
        }
        textLayout.textView.onRequestWordStudy = { [weak self] selection in
            self?.configuration?.onRequestWordStudy?(selection)
        }
        textLayout.textView.onRequestLineStudy = { [weak self] lineId, rect in
            self?.configuration?.onRequestLineStudy?(lineId, rect)
        }
        textLayout.textView.onRequestLineEdit = { [weak self] lineId, rect in
            self?.configuration?.onRequestLineEdit?(lineId, rect)
        }
        textLayout.textView.onToggleSingleLineLoop = { [weak self] lineId in
            self?.configuration?.onToggleSingleLineLoop?(lineId)
        }
        textLayout.textView.onSetABLoopAnchor = { [weak self] lineId in
            self?.configuration?.onSetABLoopAnchor?(lineId)
        }
        textLayout.textView.onCompleteABLoop = { [weak self] lineId in
            self?.configuration?.onCompleteABLoop?(lineId)
        }
    }

    func clearStudyCallbacks() {
        textLayout.textView.drawStudyIndicators = nil
        textLayout.textView.onSelectionChanged = nil
        textLayout.textView.resolveContextMenuWord = nil
        textLayout.textView.resolveContextMenuLine = nil
        textLayout.textView.resolveLineLoopMenuState = nil
        textLayout.textView.onRequestWordStudy = nil
        textLayout.textView.onRequestLineStudy = nil
        textLayout.textView.onRequestLineEdit = nil
        textLayout.textView.onToggleSingleLineLoop = nil
        textLayout.textView.onSetABLoopAnchor = nil
        textLayout.textView.onCompleteABLoop = nil
        textLayout.textView.pendingMenuWordSelection = nil
        textLayout.textView.pendingMenuLineTarget = nil
        hasActiveWordSelection = false
        appliedStudyMarksKey = nil
    }

    func syncStudyMarksIfNeeded(
        document: LyricDocument,
        occurrences: [VocabularyOccurrence],
        isClozeMode: Bool,
        didRebuild: Bool
    ) {
        let key = StudyMarksKey(
            documentId: document.id,
            documentRevision: document.revision,
            occurrences: occurrences,
            isClozeMode: isClozeMode
        )
        guard didRebuild || appliedStudyMarksKey != key else { return }
        appliedStudyMarksKey = key
        textLayout.applyStudyMarks(
            document: document,
            occurrences: occurrences,
            clozeEnabled: isClozeMode
        )
        textLayout.textView.needsDisplay = true
    }

    func handleSelectionRangeChanged(_ selectedRange: NSRange) {
        guard selectedRange.length > 0, let selection = currentWordSelection() else {
            if hasActiveWordSelection {
                hasActiveWordSelection = false
                configuration?.onWordSelection?(nil)
            }
            return
        }
        hasActiveWordSelection = true
        configuration?.onWordSelection?(selection)
    }

    func clearActiveSelectionOnRebuild() {
        textLayout.textView.setSelectedRange(NSRange(location: 0, length: 0))
        guard hasActiveWordSelection else { return }
        hasActiveWordSelection = false
        // `configure` 运行在 SwiftUI updateNSView 周期内，异步回调以避免视图更新期发布 @Published。
        Task { @MainActor [weak self] in
            guard let self, !self.hasActiveWordSelection else { return }
            self.configuration?.onWordSelection?(nil)
        }
    }

    func refreshSelectionBarIfActive() {
        guard hasActiveWordSelection else { return }
        Task { @MainActor [weak self] in
            guard let self, self.hasActiveWordSelection else { return }
            let viewportBounds = CGRect(origin: .zero, size: self.contentView.bounds.size)
            guard let selection = self.currentWordSelection(),
                  selection.anchorRectInScrollViewport.intersects(viewportBounds) else {
                self.hasActiveWordSelection = false
                self.configuration?.onWordSelection?(nil)
                return
            }
            self.configuration?.onWordSelection?(selection)
        }
    }

    func currentWordSelection() -> LyricsWordSelection? {
        guard !needsTextLayout, let document = configuration?.document else { return nil }
        let selected = textLayout.textView.selectedRange()
        guard selected.length > 0 else { return nil }
        return textLayout.wordSelection(for: selected, document: document) { [weak self] rectInTextView in
            self?.viewportRect(fromTextViewRect: rectInTextView) ?? .zero
        }
    }

    func contextLineTarget(at point: NSPoint) -> (lineId: UUID, anchorRect: CGRect)? {
        guard !needsTextLayout, let row = textLayout.nonBlankRow(at: point),
              let rect = textLayout.lineAnchorRect(for: row.id, viewportRectConverter: { [weak self] rectInTextView in
                  self?.viewportRect(fromTextViewRect: rectInTextView) ?? .zero
              }) else { return nil }
        return (row.id, rect)
    }

    func viewportRect(fromTextViewRect rectInTextView: NSRect) -> CGRect {
        let converted = contentView.convert(rectInTextView, from: textLayout.textView)
        let visibleBounds = contentView.bounds
        let topDownY = contentView.isFlipped
            ? (converted.minY - visibleBounds.minY)
            : (visibleBounds.maxY - converted.maxY)
        return CGRect(
            x: converted.minX - visibleBounds.minX,
            y: topDownY,
            width: converted.width,
            height: converted.height
        )
    }
}
