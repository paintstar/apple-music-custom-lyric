import Foundation

/// 入队即通知脚本门让后台读操作让路；取消及 dispose 不依赖队列先执行到该任务。
final class MusicPlaybackCommandQueue: @unchecked Sendable {
    private let gate: MusicScriptExecutionGate
    private let queue = DispatchQueue(label: "ShinMusicScript.playback-commands", qos: .userInitiated)
    private let lock = NSLock()
    private var reservations: [UUID: PlaybackReservation] = [:]
    private var acceptsPlayback = true

    init(gate: MusicScriptExecutionGate = MusicAppleScriptExecution.gate) { self.gate = gate }

    func async(cancellation: MusicLibraryCancellation, allowsAfterDisposal: Bool = false,
               execute: @escaping @Sendable () -> Void) {
        let reservation: PlaybackReservation? = lock.withLock {
            guard acceptsPlayback || allowsAfterDisposal else { return nil }
            let reservation = gate.reservePlayback()
            reservations[reservation.id] = reservation
            return reservation
        }
        if let reservation {
            cancellation.onCancel { [weak self] in self?.finish(reservation) }
        } else {
            cancellation.cancel()
        }
        queue.async { [self] in
            if let reservation {
                defer { finish(reservation) }
                gate.withPlaybackPriority(reservation, execute)
            } else {
                execute()
            }
        }
    }

    func cancelAll() {
        let pending = lock.withLock {
            acceptsPlayback = false
            let values = Array(reservations.values)
            reservations.removeAll()
            return values
        }
        pending.forEach { $0.release() }
    }

    private func finish(_ reservation: PlaybackReservation) {
        _ = lock.withLock { reservations.removeValue(forKey: reservation.id) }
        reservation.release()
    }
}
