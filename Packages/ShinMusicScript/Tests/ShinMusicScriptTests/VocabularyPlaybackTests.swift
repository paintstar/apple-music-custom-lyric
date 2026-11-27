import Foundation
import ShinAppleKit
import Testing
@testable import ShinMusicScript

struct VocabularyPlaybackTests {
    @Test("原声例句脚本均能按 Music 词典编译")
    func compilesVocabularyScripts() async throws {
        try await MusicScriptTestExecution.compile(
            MusicVocabularyPlayback.startScript(persistentID: Fixtures.pidA, positionMs: 7_000)
        )
        try await MusicScriptTestExecution.compile(
            MusicVocabularyPlayback.finishScript(persistentID: Fixtures.pidA, positionMs: nil)
        )
        try await MusicScriptTestExecution.compile(
            MusicVocabularyPlayback.finishScript(persistentID: Fixtures.pidA, positionMs: 7_000)
        )
        try await MusicScriptTestExecution.compile(
            MusicVocabularyPlayback.startScript(
                persistentID: Fixtures.pidA, positionMs: 7_000, replacingPersistentID: Fixtures.pidB
            )
        )
        try await MusicScriptTestExecution.compile(
            MusicVocabularyPlayback.finishScript(
                persistentID: Fixtures.pidA, positionMs: 7_000, replacingPersistentID: Fixtures.pidB
            )
        )
    }

    @Test("确认只允许替换当时的曲目，查询期间切歌后作废")
    func replacesOnlyConfirmedTrack() async throws {
        let source = try MusicVocabularyPlayback.startScript(
            persistentID: Fixtures.pidA, positionMs: 7_000, replacingPersistentID: Fixtures.pidB
        )
        #expect(try await runFixture(source, id: Fixtures.pidB, state: "paused") == "starting|0|1|1|-1")
        #expect(try await runFixture(source, id: Fixtures.pidA, state: "playing") == "protected|0|0|0|-1")
        #expect(try await runFixture(
            source, id: Fixtures.pidB, state: "playing", switchAtLookup: true
        ) == "protected|0|1|0|-1")
        let noTrack = try MusicVocabularyPlayback.startScript(
            persistentID: Fixtures.pidA, positionMs: 7_000, replacingPersistentID: ""
        )
        #expect(try await runFixture(noTrack, id: "", state: "stopped") == "starting|0|1|1|-1")
        #expect(try await runFixture(noTrack, id: "", state: "playing") == "protected|0|0|0|-1")
    }

    @Test("在原曲定位，暂停才恢复播放；跨曲保护已有队列，空闲才查目标歌曲")
    func vocabularyScriptsPreserveQueue() async throws {
        let source = try MusicVocabularyPlayback.startScript(
            persistentID: Fixtures.pidA, positionMs: 19_000
        )
        #expect(try await runFixture(source, id: Fixtures.pidA, state: "playing") == "position-requested|0|0|0|10")
        #expect(try await runFixture(source, id: Fixtures.pidA, state: "paused") == "position-requested|1|0|0|10")
        #expect(try await runFixture(source, id: Fixtures.pidB, state: "playing") == "protected|0|0|0|-1")
        #expect(try await runFixture(source, id: "", state: "stopped") == "protected|0|0|0|-1")
        #expect(try await runFixture(source, id: "", state: "stopped", hasQueue: false) == "starting|0|1|1|-1")

        #expect(try await runFixture(source, id: "", state: "paused", hasQueue: false) == "protected|0|0|0|-1")
        #expect(try await runFixture(
            source, id: "", state: "stopped", hasQueue: false, switchAtLookup: true
        ) == "protected|0|1|0|-1")
    }

    @Test("目标曲尚未接管播放器时，回读不设置旧曲的位置")
    func vocabularySeekWaitsForTargetIdentity() async throws {
        let finish = MusicVocabularyPlayback.finishScript(persistentID: Fixtures.pidA, positionMs: 7_000)
        #expect(try await runFixture(finish, id: "", state: "playing") == "pending|0|0|0|-1")
        #expect(try await runFixture(finish, id: "123456789ABCDEF0", state: "playing") == "interrupted|0|0|0|-1")
        #expect(try await runFixture(finish, id: Fixtures.pidA, state: "playing") == "position-requested|0|0|0|7")
        let confirmed = MusicVocabularyPlayback.finishScript(
            persistentID: Fixtures.pidA, positionMs: 7_000, replacingPersistentID: Fixtures.pidB
        )
        #expect(try await runFixture(confirmed, id: Fixtures.pidB, state: "playing") == "pending|0|0|0|-1")
        #expect(try await runFixture(confirmed, id: "123456789ABCDEF0", state: "playing") == "interrupted|0|0|0|-1")
    }

    @Test("确认后替换 Mock 队列并定位，旧会话与旧曲目确认均无效")
    func mockConfirmedVocabularyPlayback() async throws {
        let controller = MockPlaybackController()
        let tracks = MockMusicLibrary.tracks
        let source = MusicLibrarySource.playlist(id: "B000000000000002")
        try await controller.playTrack(tracks[0].trackRef, in: source)
        let old = controller.snapshot()
        var otherSession = old
        otherSession.sessionEpoch += 1
        #expect(try await controller.playVocabularyExample(
            trackKey: tracks[2].trackRef, positionMs: 8_000, replacingQueueFor: otherSession
        ) == .queueProtected)
        #expect(controller.snapshot() == old)
        try await controller.next()
        let current = controller.snapshot()
        #expect(try await controller.playVocabularyExample(
            trackKey: tracks[2].trackRef, positionMs: 8_000, replacingQueueFor: old
        ) == .queueProtected)
        #expect(controller.snapshot() == current)
        #expect(try await controller.playVocabularyExample(
            trackKey: tracks[2].trackRef, positionMs: 8_000, replacingQueueFor: current
        ) == .played)
        #expect(controller.snapshot().trackKey == tracks[2].trackRef)
        #expect(controller.snapshot().positionMs == 8_000)
        #expect(try await controller.currentPlaybackSource() == .library)
    }

    @Test("切曲读回可短时等待，取消后不发送下一次请求")
    func vocabularyReadbackCancellation() throws {
        var commands = 0
        #expect(throws: CancellationError.self) {
            _ = try MusicVocabularyPlayback.perform(
                persistentID: Fixtures.pidA, positionMs: 7_000,
                execute: { _ in
                    commands += 1
                    return Self.reply(commands == 1 ? ["starting"] : ["pending"])
                },
                checkCancellation: {
                    if commands >= 2 { throw CancellationError() }
                }
            )
        }
        #expect(commands == 2)
    }

    @Test("Mock 例句同曲保留上下文，跨曲保护正在播放或暂停的队列")
    func mockVocabularyPlayback() async throws {
        let controller = MockPlaybackController()
        let tracks = MockMusicLibrary.tracks
        let source = MusicLibrarySource.playlist(id: "B000000000000002")
        try await controller.playTrack(tracks[0].trackRef, in: source)
        let originalEpoch = controller.snapshot().trackEpoch
        #expect(try await controller.playVocabularyExample(trackKey: tracks[0].trackRef, positionMs: 7_000) == .played)
        #expect(controller.snapshot().trackEpoch == originalEpoch)
        #expect(controller.snapshot().positionMs == 7_000)
        #expect(try await controller.currentPlaybackSource() == source)
        let playing = controller.snapshot()
        #expect(try await controller.playVocabularyExample(trackKey: tracks[2].trackRef, positionMs: 8_000) == .queueProtected)
        #expect(controller.snapshot() == playing)
        try await controller.pause()
        let paused = controller.snapshot()
        #expect(try await controller.playVocabularyExample(trackKey: tracks[2].trackRef, positionMs: 8_000) == .queueProtected)
        #expect(controller.snapshot() == paused)
        try await controller.next()
        #expect(controller.snapshot().trackKey == tracks[1].trackRef)

        let idle = MockPlaybackController()
        #expect(try await idle.playVocabularyExample(trackKey: tracks[2].trackRef, positionMs: 8_000) == .played)
        #expect(idle.snapshot().trackKey == tracks[2].trackRef)
        #expect(idle.snapshot().positionMs == 8_000)
    }

    @Test("执行器回报实际裁剪后的位置，控制器可以等待同一目标")
    func commandReturnsClampedTarget() throws {
        let result = try MusicVocabularyPlayback.perform(
            persistentID: Fixtures.pidA, positionMs: 700_000,
            execute: { _ in
                let descriptor = Self.reply(["position-requested"])
                descriptor.insert(NSAppleEventDescriptor(double: 10.5), at: 2)
                return descriptor
            },
            checkCancellation: {}
        )
        #expect(result == .positionRequested(10_500))
    }

    private static func reply(_ values: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor(listDescriptor: ())
        for (index, value) in values.enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        return list
    }

    /// 执行生产脚本的分支，仅将 Music 属性和命令替换为进程内的原创夹具。
    private func runFixture(
        _ source: String, id: String, state: String, hasQueue: Bool = true, switchAtLookup: Bool = false
    ) async throws -> String? {
        let body = source.components(separatedBy: "\n").dropFirst(3).dropLast(2).joined(separator: "\n")
            .replacingOccurrences(of: "if exists current track then set activeID to persistent ID of current track",
                                  with: "set activeID to fixtureID")
            .replacingOccurrences(of: "player state", with: "fixtureState")
            .replacingOccurrences(of: " is paused", with: #" is "paused""#)
            .replacingOccurrences(of: " is stopped", with: #" is "stopped""#)
            .replacingOccurrences(of: " is not stopped", with: #" is not "stopped""#)
            .replacingOccurrences(of: "exists current playlist", with: "fixtureHasQueue")
            .replacingOccurrences(of: #"first track of library playlist 1 whose persistent ID is "[0-9A-Fa-f]+""#,
                                  with: "my lookupTrack()", options: .regularExpression)
            .replacingOccurrences(of: "play targetTrack without once", with: "set replaceCount to replaceCount + 1")
            .replacingOccurrences(of: "\n        play\n", with: "\n        set resumeCount to resumeCount + 1\n")
            .replacingOccurrences(of: "duration of current track", with: "10")
            .replacingOccurrences(of: "set player position to", with: "set seekSeconds to")
        guard !body.contains("application "), !body.contains("current track"), !body.contains("library playlist"),
              !body.contains("\n        play\n") else { throw MusicScriptTestExecution.Failure.construction }
        return try await MusicScriptTestExecution.string("""
        property fixtureID : "\(id)"
        property fixtureState : "\(state)"
        property fixtureHasQueue : \(hasQueue)
        property resumeCount : 0
        property lookupCount : 0
        property replaceCount : 0
        property seekSeconds : -1
        on lookupTrack()
            set lookupCount to lookupCount + 1
            if \(switchAtLookup) then set fixtureID to "123456789ABCDEF0"
            return "fixture"
        end lookupTrack
        on runFixture()
            \(body)
        end runFixture
        set observed to my runFixture()
        return (item 1 of observed) & "|" & resumeCount & "|" & lookupCount & "|" & replaceCount & "|" & (seekSeconds as integer)
        """)
    }
}
