import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct SelectedShuffleCancellationTests {
    @Test("真实队列取消lease后仅补偿恢复原随机，旧命令仍拒绝且下次nil点播保持true", arguments: [false, true])
    func cancellationRestoresBeforeNextRequest(managed: Bool) async throws {
        let observed = try await MusicScriptTestExecution.run {
            let fixture = SelectedShuffleFixture()
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            let ownership = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: [Fixtures.pidA])
            let queue = MusicPlaybackCommandQueue()
            let cancellation = MusicLibraryCancellation()
            let done = DispatchSemaphore(value: 0)
            let result = SelectedShuffleObservation()
            fixture.onStart = { cancellation.cancel() }
            queue.async(cancellation: cancellation) {
                do {
                    if managed {
                        try executor.start(ownership, at: Fixtures.pidA, shuffleEnabled: nil) { try cancellation.check() }
                    } else {
                        _ = try executor.playSource([Fixtures.pidA], at: Fixtures.pidA, in: .playlist(id: Fixtures.pidB),
                                                    shuffleEnabled: nil) { try cancellation.check() }
                    }
                } catch is CancellationError { result.cancelled = true } catch { }
                result.restoredBeforeNext = fixture.shuffleEnabled && fixture.confirmations == 0
                do {
                    try MusicAppleScriptExecution.withCancellableLock { result.oldCommandSent = true }
                } catch is CancellationError { result.oldCommandBlocked = true } catch { }
                done.signal()
            }
            guard done.wait(timeout: .now() + 5) == .success else { throw MusicScriptTestExecution.Failure.execute(nil) }
            fixture.onStart = nil
            queue.async(cancellation: MusicLibraryCancellation()) {
                do {
                    if managed {
                        try executor.start(ownership, at: Fixtures.pidA, shuffleEnabled: nil) {}
                        result.secondSucceeded = true
                    } else {
                        result.secondSucceeded = try executor.playSource([Fixtures.pidA], at: Fixtures.pidA,
                            in: .playlist(id: Fixtures.pidB), shuffleEnabled: nil) {}
                    }
                } catch { }
                done.signal()
            }
            guard done.wait(timeout: .now() + 5) == .success else { throw MusicScriptTestExecution.Failure.execute(nil) }
            return (result.cancelled, result.restoredBeforeNext, result.oldCommandBlocked && !result.oldCommandSent,
                    result.secondSucceeded, fixture.shuffleEnabled, fixture.confirmations)
        }
        #expect(observed.0 && observed.1 && observed.2 && observed.3 && observed.4 && observed.5 == 2)
    }
}

private final class SelectedShuffleObservation: @unchecked Sendable {
    var cancelled = false
    var restoredBeforeNext = false
    var oldCommandSent = false
    var oldCommandBlocked = false
    var secondSucceeded = false
}

private final class SelectedShuffleFixture: @unchecked Sendable {
    var shuffleEnabled = true
    var hasStarted = false
    var confirmations = 0
    var onStart: (@Sendable () -> Void)?

    func execute(_ source: String, cancellation: () throws -> Void) throws -> NSAppleEventDescriptor {
        try MusicAppleScriptExecution.withCancellableLock { try executeInGate(source, cancellation: cancellation) }
    }

    private func executeInGate(_ source: String, cancellation: () throws -> Void) throws -> NSAppleEventDescriptor {
        try cancellation()
        if source.contains("set previousShuffle to \"unknown\"") {
            let previous = shuffleEnabled
            shuffleEnabled = false
            hasStarted = true
            onStart?()
            let fields: [NSAppleEventDescriptor] = [.init(string: "ok"), .init(string: previous ? "true" : "false")]
                + (source.contains("return {\"ok\", previousShuffle, playbackPlaylistID}") ? [.init(string: Fixtures.pidB)] : [])
            let list = NSAppleEventDescriptor(listDescriptor: ())
            for (index, field) in fields.enumerated() { list.insert(field, at: index + 1) }
            return list
        }
        if source.contains("return \"pending-playback\"") {
            confirmations += 1
        } else if source.contains("set shuffle enabled to true") {
            shuffleEnabled = true
        } else if source.contains("set shuffle enabled to false") {
            shuffleEnabled = false
        }
        return .init(string: "ok")
    }
}
