import CoreServices
import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct ColdShuffleTests {
    @Test("冷启动先确认完整来源，再重设随机并重播一次；短暂无对象不误报失败", arguments: [false, true])
    func coldStartRecoversTransientReads(managed: Bool) async throws {
        let result = try await MusicScriptTestExecution.run {
            let fixture = RandomScriptFixture([
                (.start, .started(false)), (.confirm, .error(.currentPlaylist, -1728)), (.confirm, .value("pending")),
                (.confirm, .value("pending-shuffle")), (.shuffle, .error(.shuffle, -1728)),
                (.confirm, .value("pending-shuffle")), (.shuffle, .value("ok")), (.confirm, .value("ok")),
                (.replay, .value("ok")), (.confirm, .value("pending-playback")), (.confirm, .value("ok"))
            ])
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            let success = try managed ? executor.shuffleManaged(Self.ownership) {} : executor.shuffleSource(
                Self.ids, in: .playlist(id: Fixtures.pidB), checkCancellation: {}
            )
            return (success, fixture.isComplete, fixture.kinds)
        }
        #expect(result.0 && result.1)
        #expect(result.2 == [.start, .confirm, .confirm, .confirm, .shuffle, .confirm, .shuffle,
                            .confirm, .replay, .confirm, .confirm])
    }

    @Test("已有可用随机状态不重播，AppleScript true描述符被严格识别")
    func warmStartDoesNotReplay() async throws {
        let result = try await MusicScriptTestExecution.run {
            let fixture = RandomScriptFixture([(.start, .started(true)), (.confirm, .value("ok"))])
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            let success = try executor.shuffleSource(Self.ids, in: .playlist(id: Fixtures.pidB)) {}
            return success && fixture.isComplete
        }
        #expect(result)
    }

    @Test("未知准备状态、错误来源和真正的play错误都不可用旧播放状态冒充成功")
    func rejectsUnconfirmedStart() async throws {
        let cases: [(RandomScriptFixture.Response, MusicPlaybackContextError)] = [
            (.invalidPrepared, .init(stage: .start)), (.wrongPlaylist, .init(stage: .start)),
            (.error(.start, -1728), .init(stage: .start, appleEventCode: -1728))
        ]
        for (response, expected) in cases {
            let failure = try await MusicScriptTestExecution.run {
                let fixture = RandomScriptFixture([(.start, response)])
                let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
                do {
                    _ = try executor.shuffleManaged(Self.ownership) {}
                    return nil as MusicPlaybackContextError?
                } catch let error as MusicPlaybackContextError { return error }
            }
            #expect(failure == expected)
        }
    }

    @Test("来源成员不符或权限错误立即失败，不重播也不放宽为仅某首歌已播放")
    func refusesScopeMismatchAndPermissionFailure() async throws {
        let cases: [(RandomScriptFixture.Response, MusicPlaybackContextError)] = [
            (.value("mismatch"), .init(stage: .readback)),
            (.error(.currentPlaylist, -1743), .init(stage: .currentPlaylist, appleEventCode: -1743))
        ]
        for (response, expected) in cases {
            let failure = try await MusicScriptTestExecution.run {
                let fixture = RandomScriptFixture([(.start, .started(false)), (.confirm, response)])
                let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
                do {
                    _ = try executor.shuffleSource(Self.ids, in: .playlist(id: Fixtures.pidB)) {}
                    return nil as MusicPlaybackContextError?
                } catch let error as MusicPlaybackContextError { return error }
            }
            #expect(failure == expected)
        }
    }

    @Test("上下文暂缺期间取消，不再读取、重设随机或重播")
    func cancellationStopsRecovery() async throws {
        let cancelled = try await MusicScriptTestExecution.run {
            let fixture = RandomScriptFixture([(.start, .started(false)), (.confirm, .error(.readback, -1728))])
            let executor = AppleScriptMusicPlaybackContextExecutor(scriptExecution: fixture.execute)
            do {
                _ = try executor.shuffleSource(Self.ids, in: .playlist(id: Fixtures.pidB)) {
                    if fixture.isComplete { throw CancellationError() }
                }
                return false
            } catch is CancellationError { return fixture.isComplete }
        }
        #expect(cancelled)
    }

    @Test("普通和随机启动都在play前读取身份，play后仅返回本地值；公开模板可编译")
    func startTemplatesDoNotQueryAfterPlay() async throws {
        for source in try [MusicPlaybackContextScripts.shuffleSource(.playlist(id: Fixtures.pidB), expectedIDs: Self.ids),
                           MusicPlaybackContextScripts.shuffleManaged(Self.ownership),
                           MusicPlaybackContextScripts.playSource(.playlist(id: Fixtures.pidB), expectedIDs: Self.ids, at: Self.ids[0]),
                           MusicPlaybackContextScripts.playSource(.library, expectedIDs: Self.ids, at: Self.ids[0])] {
            let capture = try #require(source.range(of: "set playbackPlaylistID to persistent ID of targetPlaylist"))
            let lines = source.components(separatedBy: "\n")
            let play = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("play ") })
            #expect(source[..<capture.upperBound].components(separatedBy: "\n").count <= play)
            let suffix = lines.dropFirst(play + 1).joined(separator: "\n")
            #expect(!suffix.contains("persistent ID") && !suffix.contains("targetPlaylist"))
            #expect(suffix.contains(", playbackPlaylistID}"))
            try await MusicScriptTestExecution.compile(source)
        }
    }

    private static let ids = (1...187).map { String(format: "%016X", $0) }
    private static var ownership: MusicPlaybackContextOwnership {
        MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: ids)
    }
}

private final class RandomScriptFixture: @unchecked Sendable {
    enum Kind: Sendable, Equatable { case start, confirm, shuffle, replay }
    enum Response: Sendable {
        case started(Bool), invalidPrepared, wrongPlaylist, value(String), error(MusicPlaybackContextError.Stage, Int)
    }
    private let lock = NSLock()
    private var steps: [(Kind, Response)]
    private var recorded: [Kind] = []
    var isComplete: Bool { lock.withLock { steps.isEmpty } }
    var kinds: [Kind] { lock.withLock { recorded } }

    init(_ steps: [(Kind, Response)]) { self.steps = steps }

    func execute(_ source: String, cancellation: () throws -> Void) throws -> NSAppleEventDescriptor {
        try cancellation()
        let kind: Kind
        if source.contains("set preparedShuffle to false") {
            kind = .start
        } else if source.contains("return \"pending-playback\"") {
            kind = .confirm
        } else if source.contains("play targetPlaylist") {
            kind = .replay
        } else {
            kind = .shuffle
        }
        let response = try lock.withLock {
            guard let next = steps.first, next.0 == kind else { throw MusicLibraryError.invalidRequest }
            steps.removeFirst()
            recorded.append(kind)
            return next.1
        }
        switch response {
        case let .value(value): return NSAppleEventDescriptor(string: value)
        case let .error(stage, code):
            return Self.list([.init(string: "context-error"), .init(string: stage.rawValue), .init(int32: Int32(code))])
        case let .started(prepared):
            guard let value = NSAppleEventDescriptor(descriptorType: prepared ? typeTrue : typeFalse, data: Data()) else {
                throw MusicLibraryError.invalidRequest
            }
            return Self.list([.init(string: "ok"), value, .init(string: Fixtures.pidB)])
        case .invalidPrepared:
            return Self.list([.init(string: "ok"), .init(string: "false"), .init(string: Fixtures.pidB)])
        case .wrongPlaylist:
            return Self.list([.init(string: "ok"), .init(boolean: false), .init(string: Fixtures.pidA)])
        }
    }

    private static func list(_ fields: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor(listDescriptor: ())
        for (index, field) in fields.enumerated() { list.insert(field, at: index + 1) }
        return list
    }
}
