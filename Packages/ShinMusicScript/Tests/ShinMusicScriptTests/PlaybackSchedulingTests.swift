import Foundation
import Testing
@testable import ShinMusicScript

@Suite(.serialized)
struct PlaybackSchedulingTests {
    @Test("后台脚本释放后，两个已入队播放命令先于后续后台读取，嵌套脚本不死锁")
    func playbackReservationsHavePriority() {
        let gate = MusicScriptExecutionGate()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let events = SchedulingEvents()
        DispatchQueue.global().async {
            gate.withLock {
                held.signal()
                release.wait()
            }
        }
        #expect(held.wait(timeout: .now() + 5) == .success)
        defer { release.signal() }
        let queue = MusicPlaybackCommandQueue(gate: gate)
        for name in ["play A", "play B"] {
            queue.async(cancellation: MusicLibraryCancellation()) {
                do {
                    try gate.withCancellableLock {
                        gate.withLock { events.append(name) }
                    }
                } catch { Issue.record("有效播放预留不应取消") }
                done.signal()
            }
        }
        DispatchQueue.global().async {
            gate.withLock { events.append("background") }
            done.signal()
        }
        release.signal()
        for _ in 0..<3 { #expect(done.wait(timeout: .now() + 5) == .success) }
        #expect(events.values == ["play A", "play B", "background"])
    }

    @Test("等待OSA期间取消，旧命令不发送；重复取消和迟登记回调仍安全")
    func cancellationBeforeGateSkipsCommand() {
        let gate = MusicScriptExecutionGate()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let events = SchedulingEvents()
        DispatchQueue.global().async {
            gate.withLock { held.signal(); release.wait() }
        }
        #expect(held.wait(timeout: .now() + 5) == .success)
        defer { release.signal() }
        let queue = MusicPlaybackCommandQueue(gate: gate)
        let cancellation = MusicLibraryCancellation()
        queue.async(cancellation: cancellation) {
            started.signal()
            do {
                try gate.withCancellableLock { events.append("sent") }
                Issue.record("取消的命令不应发送")
            } catch is CancellationError {
                events.append("cancelled")
            } catch { Issue.record("应报告取消") }
            done.signal()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        cancellation.cancel()
        cancellation.cancel()
        cancellation.onCancel { events.append("late callback") }
        release.signal()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(events.values == ["late callback", "cancelled"])
    }

    @Test("dispose及其后迟到的普通请求不保留优先权，专用退出清理仍可入队")
    func disposalReleasesPendingAndLateReservations() {
        let gate = MusicScriptExecutionGate()
        let queue = MusicPlaybackCommandQueue(gate: gate)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let backgroundDone = DispatchSemaphore(value: 0)
        let queueDone = DispatchSemaphore(value: 0)
        let events = SchedulingEvents()
        queue.async(cancellation: MusicLibraryCancellation()) { held.signal(); release.wait() }
        #expect(held.wait(timeout: .now() + 5) == .success)
        defer { release.signal() }
        queue.async(cancellation: MusicLibraryCancellation()) {
            do {
                try gate.withCancellableLock { events.append("old sent") }
            } catch { events.append("old cancelled") }
        }
        queue.cancelAll()
        queue.cancelAll()
        let lateCancellation = MusicLibraryCancellation()
        queue.async(cancellation: lateCancellation) {
            do {
                try lateCancellation.check()
                try gate.withCancellableLock { events.append("late sent") }
            } catch { events.append("late cancelled") }
        }
        DispatchQueue.global().async {
            gate.withLock { events.append("background") }
            backgroundDone.signal()
        }
        // 在首个队列任务仍挂起时，后台已能继续，证明没有迟到预留泄漏。
        #expect(backgroundDone.wait(timeout: .now() + 5) == .success)
        release.signal()
        queue.async(cancellation: MusicLibraryCancellation(), allowsAfterDisposal: true) {
            do {
                try gate.withCancellableLock { events.append("cleanup") }
            } catch { Issue.record("退出清理的专用预留应有效") }
            queueDone.signal()
        }
        #expect(queueDone.wait(timeout: .now() + 5) == .success)
        #expect(events.values == ["background", "old cancelled", "late cancelled", "cleanup"])
    }

    @Test("长上下文仅预留而没有脚本等待时允许采样，库读取继续让路")
    func samplingContinuesBetweenPlaybackScripts() {
        let gate = MusicScriptExecutionGate()
        let reservation = gate.reservePlayback()
        defer { reservation.release() }
        let events = SchedulingEvents()
        gate.withLock(priority: .sampling) { events.append("sample") }
        let backgroundDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.withLock { events.append("background") }
            backgroundDone.signal()
        }
        gate.withPlaybackPriority(reservation) {
            gate.withLock { events.append("play") }
        }
        reservation.release()
        #expect(backgroundDone.wait(timeout: .now() + 5) == .success)
        #expect(events.values == ["sample", "play", "background"])
    }
}

private final class SchedulingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
