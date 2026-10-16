import Carbon
import CoreServices
import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct PlaylistPlaybackScopeTests {
    @Test("原生和管理点播只使用整单 without once，不以单曲引用切断范围")
    func everySelectedStartUsesWholePlaylist() async throws {
        let ownership = MusicPlaybackContextOwnership(playlistID: Fixtures.pidB, token: UUID(), trackIDs: [Fixtures.pidA])
        let sources = try [
            MusicPlaybackContextScripts.start(ownership, at: Fixtures.pidA, shuffleEnabled: nil),
            MusicPlaybackContextScripts.start(ownership, at: Fixtures.pidA, shuffleEnabled: false, reuse: true),
            MusicPlaybackContextScripts.playSource(.playlist(id: Fixtures.pidB), expectedIDs: [Fixtures.pidA], at: Fixtures.pidA),
            MusicPlaybackContextScripts.playSource(.library, expectedIDs: [Fixtures.pidA], at: Fixtures.pidA)
        ]
        for source in sources {
            #expect(source.contains("play targetPlaylist without once"))
            #expect(!source.contains("play (first track") && !source.contains("play targetTrack"))
            try await MusicScriptTestExecution.compile(source)
        }
    }

    @Test("生产确认逻辑拒绝 187 首变 455 首、来源切为资料库及仅目标曲成功")
    func confirmationRejectsExpandedScope() async throws {
        let libraryIDs = (1...455).map { String(format: "%016X", $0) }
        let playlistIDs = Array(libraryIDs.prefix(187))
        let selectedID = playlistIDs[93]
        #expect(try await confirm(expected: playlistIDs, actual: playlistIDs, selectedID: selectedID, sourceID: Fixtures.pidB) == "ok")
        #expect(try await confirm(expected: playlistIDs, actual: libraryIDs, selectedID: selectedID, sourceID: Fixtures.pidA) == "pending")
        #expect(try await confirm(expected: playlistIDs, actual: libraryIDs,
                                  selectedID: selectedID, sourceID: Fixtures.pidB) == "mismatch")
        #expect(try await confirm(expected: playlistIDs, actual: [selectedID],
                                  selectedID: selectedID, sourceID: Fixtures.pidB) == "mismatch")
        let reversedResult = try await confirm(expected: playlistIDs, actual: Array(playlistIDs.reversed()),
                                         selectedID: selectedID, sourceID: Fixtures.pidB)
        #expect(reversedResult == "mismatch")
        #expect(try await confirm(expected: playlistIDs, actual: playlistIDs,
                                  selectedID: selectedID, sourceID: Fixtures.pidB, isPlaying: false) == "pending-playback")
    }

    private func confirm(expected: [String], actual: [String], selectedID: String, sourceID: String,
                         isPlaying: Bool = true) async throws -> String? {
        // 只将系统读表达式替换成原创内存值，原样执行生产条件分支；不向 Music 发事件。
        let body = try MusicPlaybackContextScripts.confirmationBody(
            playlistID: Fixtures.pidB, expectedIDs: expected, selectedID: selectedID, shuffleEnabled: false, orderedMembers: true
        )
            .replacingOccurrences(of: "(exists current playlist)", with: "true")
            .replacingOccurrences(of: "(exists current track)", with: "true")
            .replacingOccurrences(of: "(persistent ID of current playlist)", with: "\"\(sourceID)\"")
            .replacingOccurrences(of: "get persistent ID of every track of current playlist", with: "fixtureIDs")
            .replacingOccurrences(of: "(persistent ID of current track)", with: "\"\(selectedID)\"")
            .replacingOccurrences(of: "(shuffle enabled)", with: "false")
            .replacingOccurrences(of: "player state is not playing", with: isPlaying ? "false" : "true")
        return try await MusicScriptTestExecution.run {
            // actualIDs 来自 Music 返回的列表描述符；只将 expectedIDs 保留为生产模板中的固定列表。
            guard let script = NSAppleScript(source: "on checkContext(fixtureIDs)\n\(body)\nend checkContext") else {
                throw MusicScriptTestExecution.Failure.construction
            }
            let event = NSAppleEventDescriptor.appleEvent(
                withEventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(.init(string: "checkContext"), forKeyword: AEKeyword(keyASSubroutineName))
            let ids = NSAppleEventDescriptor(listDescriptor: ())
            for (index, id) in actual.enumerated() { ids.insert(.init(string: id), at: index + 1) }
            let arguments = NSAppleEventDescriptor(listDescriptor: ())
            arguments.insert(ids, at: 1)
            event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
            var error: NSDictionary?
            let result = script.executeAppleEvent(event, error: &error)
            guard error == nil else {
                throw MusicScriptTestExecution.Failure.execute((error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue)
            }
            return result.stringValue
        }
    }
}
