import Foundation
@testable import ShinMusicScript

/// 只导出原创内存夹具；不启动解释器，不读取或控制 Music。
@main
private enum MusicPlaybackScriptFixtures {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure.invalid }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let ids = (1...187).map { String(format: "%016X", $0) }
        let rotated = Array(ids[92...]) + ids[..<92]
        try write(copy(source: ids, indexed: ids, selected: rotated, expected: rotated, operations: 2),
                  named: "rotation", to: directory)
        let small = Array(ids.prefix(30)), reversed = Array(ids.prefix(30).reversed())
        for unavailable in [false, true] {
            try write(copy(source: small, indexed: reversed, selected: reversed,
                           expected: Array(reversed.prefix(24)), operations: 24, unavailable: unavailable),
                      named: unavailable ? "range-missing" : "range-mismatch", to: directory)
        }
        let empty = MusicPlaybackContextOwnership(playlistID: ids[0], token: UUID(), trackIDs: [], usesUniqueName: true)
        let append = try MusicPlaybackContextScripts.append([ids[1]], to: empty, from: .library)
        guard let checkStart = append.range(of: "set contextStage to \"readback\""),
              let checkEnd = append.range(of: "set sourceIDs to") else { throw CheckFailure.invalid }
        let emptyCheck = String(append[checkStart.lowerBound..<checkEnd.lowerBound])
        try write(emptyMemberRead(emptyCheck, count: 0, accepted: true), named: "empty-first-append", to: directory)
        try write(emptyMemberRead(emptyCheck, count: 1, accepted: false), named: "changed-first-append", to: directory)
        let emptyRead = try MusicPlaybackContextScripts.orderedMembersCheck([], mismatch: "error number -1728")
        let cleanup = try MusicPlaybackContextScripts.remove(empty)
        guard cleanup.contains(try MusicPlaybackContextScripts.orderedMembersCheck([], mismatch: "return \"released\"")) else {
            throw CheckFailure.invalid
        }
        try write(emptyMemberRead(emptyRead, count: 0, accepted: true), named: "empty-cleanup", to: directory)
        let nonempty = MusicPlaybackContextOwnership(playlistID: ids[0], token: UUID(), trackIDs: [ids[1]], usesUniqueName: true)
        let emptyReuseCheck = try MusicPlaybackContextScripts.orderedMembersCheck(nonempty.trackIDs, mismatch: "return \"different\"")
        for (name, template) in try [
            ("emptied-reuse", MusicPlaybackContextScripts.start(nonempty, at: ids[1], shuffleEnabled: nil, reuse: true)),
            ("emptied-shuffle", MusicPlaybackContextScripts.shuffleManaged(nonempty))
        ] {
            guard template.contains(emptyReuseCheck) else { throw CheckFailure.invalid }
            try write(emptyMemberRead(emptyReuseCheck.replacingOccurrences(of: "return \"different\"", with: "return false"),
                                      count: 0, accepted: false), named: name, to: directory)
        }
        for outcome in ["match", "different", "missing", "play-error"] {
            try write(preflight(outcome, first: ids[0], other: ids[1]), named: "shuffle-" + outcome, to: directory)
        }
    }

    private static func emptyMemberRead(_ body: String, count: Int, accepted: Bool) -> String {
        let check = body
            .replacingOccurrences(of: "(count of tracks of targetPlaylist)", with: "fixtureCount")
            .replacingOccurrences(of: "count of tracks of targetPlaylist", with: "fixtureCount")
            .replacingOccurrences(of: "get persistent ID of every track of targetPlaylist", with: "my forbiddenEmptyRead()")
        return """
        property readAttempts : 0
        on forbiddenEmptyRead()
            set readAttempts to readAttempts + 1
            error number -1728
        end forbiddenEmptyRead
        on checkFixture()
            set fixtureCount to \(count)
            try
                \(check)
                return true
            on error number eventCode
                if eventCode is not -1728 then error number eventCode
                return false
            end try
        end checkFixture
        if (my checkFixture()) is not \(accepted ? "true" : "false") then error number -2700
        if readAttempts is not 0 then error number -2700
        return "ok"
        """
    }

    private static func copy(source: [String], indexed: [String], selected: [String], expected: [String],
                             operations: Int, unavailable: Bool = false) -> String {
        let body = MusicPlaybackContextScripts.copySelectedReferences
            .replacingOccurrences(of: "set candidateIDs to get persistent ID of tracks sourceStart through sourceEnd of sourcePlaylist",
                                  with: unavailable ? "error number -1728" : "set candidateIDs to items sourceStart through sourceEnd of fixtureIndexedIDs")
            .replacingOccurrences(of: "duplicate (tracks sourceStart through sourceEnd of sourcePlaylist) to targetPlaylist",
                                  with: "set copiedIDs to copiedIDs & candidateIDs")
            .replacingOccurrences(of: "set matchedTracks to (tracks of sourcePlaylist whose persistent ID is selectedID)",
                                  with: "set matchedTracks to {selectedID}")
            .replacingOccurrences(of: "duplicate (item 1 of matchedTracks) to targetPlaylist",
                                  with: "set copiedIDs to copiedIDs & {item 1 of matchedTracks}")
        return """
        set sourceIDs to \(literal(source))
        set fixtureIndexedIDs to \(literal(indexed))
        set selectedIDs to \(literal(selected))
        set copiedIDs to {}
        \(body)
        if copiedIDs is not \(literal(expected)) then error number -2700
        if copyOperations is not \(operations) then error number -2700
        if selectedOffset is not \(expected.count + 1) then error number -2700
        return "ok"
        """
    }

    private static func preflight(_ outcome: String, first: String, other: String) -> String {
        let matching = outcome == "match" || outcome == "play-error"
        var body = MusicPlaybackContextScripts.prepareSelectedPlayback(at: first,
            mismatch: "return {\"different\", fixtureShuffle, sentPlay}")
            .replacingOccurrences(of: "shuffle enabled", with: "fixtureShuffle")
            .replacingOccurrences(of: "(persistent ID of track 1 of targetPlaylist)", with: "my firstID()")
            .replacingOccurrences(of: "play targetPlaylist without once",
                                  with: outcome == "play-error" ? "set sentPlay to true\nerror number -1728" : "set sentPlay to true")
        body += "\nreturn {\"ok\", fixtureShuffle, sentPlay}"
        let read = outcome == "missing" ? "error number -1728" : "return \"\(matching ? first : other)\""
        let result = outcome == "match" ? "ok" : (outcome == "missing" || outcome == "play-error") ? "error" : "different"
        return """
        property fixtureShuffle : true
        on firstID()
            if fixtureShuffle then return "\(other)"
            \(read)
        end firstID
        on checkFixture()
            set fixtureShuffle to true
            set sentPlay to false
            try
                \(body)
            on error
                return {"error", fixtureShuffle, sentPlay}
            end try
        end checkFixture
        set observed to my checkFixture()
        if item 1 of observed is not "\(result)" then error number -2700
        if item 2 of observed is not \(outcome == "match" ? "false" : "true") then error number -2700
        if item 3 of observed is not \(matching ? "true" : "false") then error number -2700
        return "ok"
        """
    }

    private static func literal(_ values: [String]) -> String {
        "{" + values.map { "\"" + $0 + "\"" }.joined(separator: ",") + "}"
    }

    private static func write(_ source: String, named name: String, to directory: URL) throws {
        guard !source.contains("application "), !source.contains("duplicate "), !source.contains("play targetPlaylist") else {
            throw CheckFailure.invalid
        }
        try source.write(to: directory.appendingPathComponent(name + ".applescript"), atomically: true, encoding: .utf8)
    }

    private enum CheckFailure: Error { case invalid }
}
