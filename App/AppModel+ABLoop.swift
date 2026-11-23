import Foundation
import ShinAppleKit
import ShinAppServices
import ShinLyricsEngine

/// `AppModel` 的单句 / AB 循环实时回跳与触发入口扩展。
@MainActor
extension AppModel {

    func evaluateABLoopIfNeeded(for snapshot: PlaybackSnapshot) {
        guard !isTerminating,
              pendingSeek == nil,
              !isChangingTrack,
              Self.canSeek(snapshot, isMock: isMock),
              let panel = lyricsPanel else {
            return
        }
        let action = panel.evaluateABLoop(
            snapshot: snapshot,
            nowMonotonicMs: Self.monotonicNowMs()
        )
        if case let .seekTo(ms, expected) = action {
            seek(toMs: ms, expectedSnapshot: expected)
        }
    }

    func seekToABLoopStartIfNeeded(_ segment: LyricsPlaybackSegment) {
        guard !isTerminating, !isChangingTrack else { return }
        let current = controller.snapshot()
        guard Self.canSeek(current, isMock: isMock) else { return }
        let isInsidePlayingSegment = current.status == .playing
            && current.positionMs.map { $0 >= segment.startMs && $0 < segment.endMs } == true
        if !isInsidePlayingSegment {
            seek(toMs: segment.startMs, expectedSnapshot: current)
        }
    }

    func toggleSingleLineLoop(lineId: UUID) {
        lyricsPanel?.toggleSingleLineLoop(
            lineId: lineId,
            trackKey: currentTrackKey,
            trackEpoch: snapshot.trackEpoch
        )
    }

    func toggleCurrentLineLoop() {
        guard let lineId = lyricsPanel?.syncDisplay.currentLineIds?.first else { return }
        toggleSingleLineLoop(lineId: lineId)
    }

    func setABLoopAnchor(lineId: UUID) {
        lyricsPanel?.setABLoopAnchor(lineId: lineId)
    }

    func completeABLoop(endLineId: UUID) {
        lyricsPanel?.completeABLoop(
            endLineId: endLineId,
            trackKey: currentTrackKey,
            trackEpoch: snapshot.trackEpoch
        )
    }

    func clearABLoop() {
        lyricsPanel?.clearABLoop()
    }
}
