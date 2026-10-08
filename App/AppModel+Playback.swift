import Foundation
import ShinAppleKit

extension AppModel {
    func playNext() { changeTrack(forward: true) }
    func playPrevious() { changeTrack(forward: false) }

    private func changeTrack(forward: Bool) {
        guard !isChangingTrack else { return }
        transportSequence += 1
        let sequence = transportSequence
        let expected = controller.snapshot()
        isChangingTrack = true
        playbackMessage = nil
        waitingForTransportChange = nil
        transportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishTransportRequest(sequence) }
            guard !Task.isCancelled, self.isCurrentTrack(expected) else { return }
            do {
                try await self.sendTransportCommand(forward: forward)
                guard !Task.isCancelled, sequence == self.transportSequence else { return }
                self.confirmTransportChange(expected: expected)
            } catch {
                self.handleTransportError(error, sequence: sequence, expected: expected)
            }
        }
    }

    private func sendTransportCommand(forward: Bool) async throws {
        if forward {
            try await controller.next()
        } else {
            try await controller.previous()
        }
    }

    private func confirmTransportChange(expected: PlaybackSnapshot) {
        let confirmed = controller.snapshot()
        applySnapshot(confirmed)
        if !Self.didConfirmTransportChange(from: expected, to: confirmed) {
            waitingForTransportChange = expected
            playbackMessage = Self.pendingTrackChangeMessage
        }
    }

    private func finishTransportRequest(_ sequence: Int) {
        guard sequence == transportSequence else { return }
        isChangingTrack = false
        transportTask = nil
    }

    private func handleTransportError(_ error: Error, sequence: Int, expected: PlaybackSnapshot) {
        guard !(error is CancellationError), sequence == transportSequence, isCurrentTrack(expected) else { return }
        if let playbackError = error as? PlaybackError {
            handlePlaybackError(playbackError)
        } else {
            playbackMessage = "切歌失败：\(String(describing: error))"
        }
    }

    static func didConfirmTransportChange(from expected: PlaybackSnapshot, to confirmed: PlaybackSnapshot) -> Bool {
        if confirmed.sessionEpoch != expected.sessionEpoch || confirmed.trackEpoch != expected.trackEpoch
            || confirmed.trackRef != expected.trackRef { return true }
        guard let oldPosition = expected.positionMs, let newPosition = confirmed.positionMs else { return false }
        // 原曲重新开始也可能是合法的上一曲/单曲循环结果；正常向前推进不能当作切歌成功。
        return newPosition < oldPosition
    }
}
