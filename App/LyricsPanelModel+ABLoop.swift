import Foundation
import ShinAppleKit
import ShinAppServices
import ShinLyricsEngine

/// 歌词面板的单句循环 / AB 选段复读状态机驱动扩展。
@MainActor
extension LyricsPanelModel {

    func isSingleLineLooping(lineId: UUID) -> Bool {
        guard let active = activeABLoop else { return false }
        return active.startLineId == lineId && active.endLineId == lineId
    }

    func canToggleSingleLineLoop(lineId: UUID) -> Bool {
        if isSingleLineLooping(lineId: lineId) { return true }
        guard case let .ready(document) = state,
              !isAutoScrollSuspended,
              let line = document.lines.first(where: { $0.id == lineId }),
              line.startMs != nil else {
            return false
        }
        return coordinator?.playbackSegment(fromLineId: lineId, toLineId: lineId) != nil
    }

    func canSetABLoopAnchor(lineId: UUID) -> Bool {
        guard case let .ready(document) = state, !isAutoScrollSuspended else { return false }
        return document.lines.contains { $0.id == lineId && $0.startMs != nil }
    }

    func canCompleteABLoop(endLineId: UUID) -> Bool {
        orderedABLines(endLineId: endLineId).flatMap { pair in
            coordinator?.playbackSegment(fromLineId: pair.start.id, toLineId: pair.end.id)
        } != nil
    }

    func lineLoopMenuState(for lineId: UUID) -> LyricsLineLoopMenuState? {
        let canSingle = canToggleSingleLineLoop(lineId: lineId)
        let isSingle = isSingleLineLooping(lineId: lineId)
        let hasAnchor = pendingLoopAnchorLineId != nil
        let canAnchor = canSetABLoopAnchor(lineId: lineId)
        let canComplete = hasAnchor && canCompleteABLoop(endLineId: lineId)
        guard canSingle || isSingle || canAnchor || canComplete else { return nil }
        return LyricsLineLoopMenuState(
            canSingleLineLoop: canSingle,
            isCurrentSingleLineLoop: isSingle,
            hasPendingAnchor: hasAnchor,
            canSetAnchor: canAnchor,
            canCompleteABLoop: canComplete
        )
    }

    func toggleSingleLineLoop(lineId: UUID, trackKey: String?, trackEpoch: Int) {
        if isSingleLineLooping(lineId: lineId) {
            clearABLoop()
            return
        }
        guard case let .ready(document) = state,
              !isAutoScrollSuspended,
              let trackKey,
              displayedTrackKey == trackKey,
              displayedTrackEpoch == trackEpoch,
              let line = document.lines.first(where: { $0.id == lineId }),
              line.startMs != nil,
              let segment = coordinator?.playbackSegment(fromLineId: lineId, toLineId: lineId) else {
            return
        }
        let target = LyricsABLoopTarget(
            documentId: document.id,
            trackKey: trackKey,
            trackEpoch: trackEpoch,
            startLineId: lineId,
            endLineId: lineId,
            startLineText: line.text,
            endLineText: line.text
        )
        abLoopEvaluator.activate(target)
        syncABLoopPublishedState()
        onABLoopActivated?(segment)
    }

    func setABLoopAnchor(lineId: UUID) {
        guard canSetABLoopAnchor(lineId: lineId) else { return }
        abLoopEvaluator.setPendingAnchor(lineId)
        syncABLoopPublishedState()
    }

    func completeABLoop(endLineId: UUID, trackKey: String?, trackEpoch: Int) {
        guard case let .ready(document) = state,
              !isAutoScrollSuspended,
              let trackKey,
              displayedTrackKey == trackKey,
              displayedTrackEpoch == trackEpoch,
              let pair = orderedABLines(endLineId: endLineId),
              let segment = coordinator?.playbackSegment(
                  fromLineId: pair.start.id,
                  toLineId: pair.end.id
              ) else {
            return
        }
        let target = LyricsABLoopTarget(
            documentId: document.id,
            trackKey: trackKey,
            trackEpoch: trackEpoch,
            startLineId: pair.start.id,
            endLineId: pair.end.id,
            startLineText: pair.start.text,
            endLineText: pair.end.text
        )
        abLoopEvaluator.activate(target)
        syncABLoopPublishedState()
        onABLoopActivated?(segment)
    }

    func clearABLoop() {
        abLoopEvaluator.clear()
        syncABLoopPublishedState()
    }

    func evaluateABLoop(
        snapshot: PlaybackSnapshot,
        nowMonotonicMs: Int64
    ) -> LyricsABLoopEvaluator.Action {
        guard abLoopEvaluator.activeTarget != nil else { return .none }
        let action = abLoopEvaluator.evaluate(
            snapshot: snapshot,
            currentDocumentId: currentDocumentId,
            segmentProvider: { [weak coordinator] startId, endId in
                coordinator?.playbackSegment(fromLineId: startId, toLineId: endId)
            },
            nowMonotonicMs: nowMonotonicMs
        )
        if action == .clear {
            syncABLoopPublishedState()
        }
        return action
    }

    func reconcileABLoopWithCurrentDocument(previousDocumentId: UUID?) {
        guard case let .ready(document) = state else {
            clearABLoop()
            return
        }
        if let active = activeABLoop {
            let matchesDocument = active.documentId == document.id
                && (previousDocumentId == nil || previousDocumentId == document.id)
            let matchesTrack = active.trackKey == displayedTrackKey
                && active.trackEpoch == displayedTrackEpoch
            let hasValidSegment = coordinator?.playbackSegment(
                fromLineId: active.startLineId,
                toLineId: active.endLineId
            ) != nil
            if !matchesDocument || !matchesTrack || !hasValidSegment {
                clearABLoop()
                return
            }
        }
        if let anchorId = pendingLoopAnchorLineId {
            let anchorValid = document.lines.contains { $0.id == anchorId && $0.startMs != nil }
            let sameDoc = previousDocumentId == nil || previousDocumentId == document.id
            if !anchorValid || !sameDoc {
                abLoopEvaluator.setPendingAnchor(nil)
                syncABLoopPublishedState()
            }
        }
    }

    private func orderedABLines(endLineId: UUID) -> (start: LyricLine, end: LyricLine)? {
        guard case let .ready(document) = state,
              !isAutoScrollSuspended,
              let anchorId = abLoopEvaluator.pendingAnchorLineId,
              let anchorIndex = document.lines.firstIndex(where: { $0.id == anchorId }),
              let endIndex = document.lines.firstIndex(where: { $0.id == endLineId }) else {
            return nil
        }
        let anchorLine = document.lines[anchorIndex]
        let endLine = document.lines[endIndex]
        guard let anchorMs = anchorLine.startMs, let endMs = endLine.startMs else {
            return nil
        }
        if anchorMs != endMs {
            return anchorMs <= endMs ? (anchorLine, endLine) : (endLine, anchorLine)
        }
        return anchorIndex <= endIndex ? (anchorLine, endLine) : (endLine, anchorLine)
    }
}
