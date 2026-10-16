import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct CleanupStopConfirmationTests {
    @Test("停止返回pending后只读重验直到stopped，stop只发送一次")
    func pendingThenStopped() async throws {
        let observed = try await MusicScriptTestExecution.run {
            let fixture = StopFixture(readbacks: ["pending", "stopped"])
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            return (try executor.stopForCleanup {}, fixture.stopCount, fixture.readCount)
        }
        #expect(observed.0 && observed.1 == 1 && observed.2 == 2)
        #expect(!MusicPlaybackContextScripts.confirmStoppedForCleanup.components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "stop" })
    }

    @Test("生产停止判断只兼容paused且无歌曲无清单，所有普通暂停和活动状态仍拒绝")
    func stoppedStateCompatibility() async throws {
        let body = MusicPlaybackContextScripts.cleanupStoppedState
            .replacingOccurrences(of: "player state", with: "fixtureState")
            .replacingOccurrences(of: "is stopped", with: "is \"stopped\"")
            .replacingOccurrences(of: "is paused", with: "is \"paused\"")
            .replacingOccurrences(of: "(exists current track)", with: "fixtureHasTrack")
            .replacingOccurrences(of: "(exists current playlist)", with: "fixtureHasPlaylist")
        let cases: [StoppedStateCase] = [
            .init(state: "stopped", hasTrack: true, hasPlaylist: true, expected: true),
            .init(state: "paused", hasTrack: false, hasPlaylist: false, expected: true),
            .init(state: "paused", hasTrack: true, hasPlaylist: false, expected: false),
            .init(state: "paused", hasTrack: false, hasPlaylist: true, expected: false),
            .init(state: "playing", hasTrack: false, hasPlaylist: false, expected: false),
            .init(state: "fast forwarding", hasTrack: false, hasPlaylist: false, expected: false),
            .init(state: "rewinding", hasTrack: false, hasPlaylist: false, expected: false),
            .init(state: "unknown", hasTrack: false, hasPlaylist: false, expected: false)
        ]
        for item in cases {
            let result = try await MusicScriptTestExecution.string("""
                set fixtureState to "\(item.state)"
                set fixtureHasTrack to \(item.hasTrack ? "true" : "false")
                set fixtureHasPlaylist to \(item.hasPlaylist ? "true" : "false")
                \(body)
                if cleanupStopped then return "accepted"
                return "refused"
                """)
            #expect(result == (item.expected ? "accepted" : "refused"))
        }
        #expect(MusicPlaybackContextScripts.confirmStoppedForCleanup.contains(MusicPlaybackContextScripts.cleanupStoppedState))
        let own = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: [Fixtures.pidA])
        #expect(try MusicPlaybackContextScripts.remove(own, allowStoppedCurrent: true)
            .components(separatedBy: MusicPlaybackContextScripts.cleanupStoppedState).count >= 3)
    }

    @Test("持续pending在短预算内失败，不重复stop或把未停播放当成已停")
    func pendingTimesOut() async throws {
        let observed = try await MusicScriptTestExecution.run {
            let fixture = StopFixture(readbacks: [])
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            let began = DispatchTime.now().uptimeNanoseconds
            let confirmed = try executor.stopForCleanup {}
            return (confirmed, fixture.stopCount, fixture.readCount,
                    DispatchTime.now().uptimeNanoseconds - began)
        }
        #expect(!observed.0 && observed.1 == 1 && observed.2 > 0)
        #expect(observed.3 < 3_000_000_000)
    }

    @Test("停止等待取消后不再读或发stop；未知状态和权限错误立即失败")
    func cancellationAndInvalidReadback() async throws {
        let cancelled = try await MusicScriptTestExecution.run {
            let fixture = StopFixture(readbacks: [])
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            do {
                _ = try executor.stopForCleanup { if fixture.stopCount > 0 { throw CancellationError() } }
                return false
            } catch is CancellationError { return fixture.stopCount == 1 && fixture.readCount == 0 }
        }
        #expect(cancelled)
        for status in ["unknown", "denied"] {
            let failed = try await MusicScriptTestExecution.run {
                let fixture = StopFixture(readbacks: [status])
                let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
                do {
                    _ = try executor.stopForCleanup {}
                    return false
                } catch let error as MusicPlaybackContextError {
                    return error.stage == .cleanup && fixture.stopCount == 1 && fixture.readCount == 1
                        && (status != "denied" || error.appleEventCode == -1743)
                }
            }
            #expect(failed)
        }
    }
}

private struct StoppedStateCase {
    let state: String
    let hasTrack: Bool
    let hasPlaylist: Bool
    let expected: Bool
}

private final class StopFixture: @unchecked Sendable {
    var stopCount = 0
    var readCount = 0
    private var readbacks: [String]
    init(readbacks: [String]) { self.readbacks = readbacks }
    func execute(_ source: String, cancellation: () throws -> Void) throws -> NSAppleEventDescriptor {
        try cancellation()
        if source == MusicPlaybackContextScripts.stopForCleanup {
            stopCount += 1
            return .init(string: "pending")
        }
        guard source == MusicPlaybackContextScripts.confirmStoppedForCleanup else { throw MusicLibraryError.invalidRequest }
        readCount += 1
        let value = readbacks.isEmpty ? "pending" : readbacks.removeFirst()
        if value == "denied" {
            let result = NSAppleEventDescriptor(listDescriptor: ())
            let fields = [NSAppleEventDescriptor(string: "context-error"), .init(string: "cleanup"), .init(int32: -1743)]
            for (index, value) in fields.enumerated() {
                result.insert(value, at: index + 1)
            }
            return result
        }
        return .init(string: value)
    }
}
