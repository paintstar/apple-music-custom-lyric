import Foundation
import ShinAppleKit

/// 所有可插入文本限于验证过的十六进制 ID、程序生成 UUID 和布尔值。
/// duplicate 只把资料库曲目引用加入 user playlist；没有音频文件操作。
enum MusicPlaybackContextScripts {
    static let playlistName = "ShinApple · 当前播放"
    static func playlistName(for token: UUID) -> String { playlistName + " · " + token.uuidString }
    static func expectedName(for ownership: MusicPlaybackContextOwnership) -> String {
        ownership.usesUniqueName == true ? playlistName(for: ownership.token) : playlistName
    }

    static func create(token: UUID) -> String {
        wrap("""
        set targetPlaylist to make new user playlist with properties {name:"\(playlistName(for: token))", description:"\(marker(token))"}
        return persistent ID of targetPlaylist
        """, stage: .create)
    }

    static func append(_ ids: [String], to ownership: MusicPlaybackContextOwnership, from source: MusicLibrarySource) throws -> String {
        let selectedIDs = try list(ids)
        let sourceSelection: String
        switch source {
        case .library: sourceSelection = "set sourcePlaylist to library playlist 1"
        case let .playlist(id):
            try validate(id)
            sourceSelection = """
            set sourceMatches to (user playlists whose persistent ID is "\(id)")
            if (count of sourceMatches) is 0 then error number -1728
            set sourcePlaylist to item 1 of sourceMatches
            """
        }
        return try wrap("""
        \(selection(ownership))
        \(sourceSelection)
        set contextStage to "readback"
        \(orderedMembersCheck(ownership.trackIDs, mismatch: "error number -1728"))
        set sourceIDs to get persistent ID of every track of sourcePlaylist
        set selectedIDs to \(selectedIDs)
        \(copySelectedReferences)
        set contextStage to "readback"
        return get persistent ID of every track of targetPlaylist
        """, stage: .select)
    }

    static func start(_ ownership: MusicPlaybackContextOwnership, at id: String, shuffleEnabled: Bool?,
                      reuse: Bool = false) throws -> String {
        try validate(id)
        guard ownership.trackIDs.first == id else { throw MusicLibraryError.invalidRequest }
        let mismatch = reuse ? "return \"different\"" : "error number -1728"
        return try wrap("""
        \(selection(ownership, mismatch: mismatch))
        set contextStage to "readback"
        \(orderedMembersCheck(ownership.trackIDs, mismatch: mismatch))
        \(prepareSelectedPlayback(at: id, mismatch: mismatch))
        return {"ok", previousShuffle}
        """, stage: .select)
    }

    static func playSource(_ source: MusicLibrarySource, expectedIDs: [String], at id: String) throws -> String {
        try validate(id)
        guard expectedIDs.first == id else { throw MusicLibraryError.invalidRequest }
        let target: String
        switch source {
        case .library: target = "set targetPlaylist to library playlist 1"
        case let .playlist(id): target = try playlistSelection(id)
        }
        return try wrap("""
        \(target)
        if (special kind of targetPlaylist) is folder then return "different"
        set contextStage to "readback"
        \(orderedMembersCheck(expectedIDs, mismatch: "return \"different\""))
        set playbackPlaylistID to persistent ID of targetPlaylist
        \(prepareSelectedPlayback(at: id, mismatch: "return \"different\""))
        return {"ok", previousShuffle, playbackPlaylistID}
        """, stage: .select)
    }

    static func prepareSelectedPlayback(at id: String, mismatch: String) -> String {
        """
        set contextStage to "shuffle"
        set previousShuffle to "unknown"
        try
            if shuffle enabled then
                set previousShuffle to "true"
            else
                set previousShuffle to "false"
            end if
        on error number preparationError
            if preparationError is not -1728 then error number preparationError
        end try
        try
            try
                set shuffle enabled to false
            on error number preparationError
                if preparationError is not -1728 then error number preparationError
            end try
            set contextStage to "select"
            if (persistent ID of track 1 of targetPlaylist) is not "\(id)" then
                \(restorePreviousShuffle)
                \(mismatch)
            end if
        on error number preparationError
            try
                \(restorePreviousShuffle)
            end try
            error number preparationError
        end try
        set contextStage to "start"
        try
            play targetPlaylist without once
        on error number startError
            try
                \(restorePreviousShuffle)
            end try
            error number startError
        end try
        """
    }

    private static var restorePreviousShuffle: String {
        """
        if previousShuffle is "true" then set shuffle enabled to true
        if previousShuffle is "false" then set shuffle enabled to false
        """
    }

    /// 确认失败或取消后仍在同一命令队列恢复此前已知偏好，不等待新上下文可读。
    static func restoreShuffle(_ enabled: Bool) -> String {
        wrap("set shuffle enabled to \(enabled ? "true" : "false")\nreturn \"ok\"", stage: .shuffle)
    }

    static func shuffleSource(_ source: MusicLibrarySource, expectedIDs: [String]) throws -> String {
        let target: String
        switch source {
        case .library: target = "set targetPlaylist to library playlist 1"
        case let .playlist(id): target = try playlistSelection(id)
        }
        return try wrap("""
        \(target)
        if (special kind of targetPlaylist) is folder then return "different"
        set contextStage to "readback"
        \(membersCheck(expectedIDs, mismatch: "return \"different\""))
        \(prepareRandomPlayback)
        return {"ok", preparedShuffle, playbackPlaylistID}
        """, stage: .select)
    }

    static func shuffleManaged(_ ownership: MusicPlaybackContextOwnership) throws -> String {
        try wrap("""
        \(selection(ownership))
        set contextStage to "readback"
        \(orderedMembersCheck(ownership.trackIDs, mismatch: "return \"different\""))
        \(prepareRandomPlayback)
        return {"ok", preparedShuffle, playbackPlaylistID}
        """, stage: .select)
    }

    private static var prepareRandomPlayback: String {
        """
        set playbackPlaylistID to persistent ID of targetPlaylist
        set contextStage to "shuffle"
        set preparedShuffle to false
        try
            set shuffle mode to songs
            set shuffle enabled to true
            set preparedShuffle to true
        on error number preparationError
            if preparationError is not -1728 then error number preparationError
        end try
        set contextStage to "start"
        play targetPlaylist without once
        """
    }

    static func setSourceShuffle(_ id: String, expectedIDs: [String], enabled: Bool = true,
                                 orderedMembers: Bool = false) throws -> String {
        try validate(id)
        return try wrap("""
        set contextStage to "currentPlaylist"
        if not (exists current playlist) then error number -1728
        if (persistent ID of current playlist) is not "\(id)" then error number -1728
        set targetPlaylist to current playlist
        set contextStage to "readback"
        \(orderedMembers
          ? orderedMembersCheck(expectedIDs, mismatch: "error number -1728")
          : membersCheck(expectedIDs, mismatch: "error number -1728"))
        set contextStage to "shuffle"
        \(enabled ? "set shuffle mode to songs" : "")
        set shuffle enabled to \(enabled ? "true" : "false")
        return "ok"
        """, stage: .shuffle)
    }

    /// 冷启动只能在真实来源/完整成员及随机状态已确认后重播同一歌单一次，让 Music 选择首曲。
    static func replayShuffle(_ id: String, expectedIDs: [String], ownership: MusicPlaybackContextOwnership?) throws -> String {
        try validate(id)
        return try wrap("""
        \(ownership.map { try selection($0) } ?? "set targetPlaylist to current playlist")
        set contextStage to "currentPlaylist"
        if not (exists current playlist) then error number -1728
        if (persistent ID of current playlist) is not "\(id)" then error number -1728
        set contextStage to "readback"
        \(membersCheck(expectedIDs, mismatch: "error number -1728"))
        set contextStage to "shuffle"
        set shuffle mode to songs
        set shuffle enabled to true
        set contextStage to "start"
        play targetPlaylist without once
        return "ok"
        """, stage: .start)
    }

    static func setShuffle(_ ownership: MusicPlaybackContextOwnership, enabled: Bool) throws -> String {
        try wrap("""
        \(selection(ownership))
        set contextStage to "currentPlaylist"
        if not (exists current playlist) then error number -1728
        if (persistent ID of current playlist) is not "\(ownership.playlistID)" then error number -1728
        set contextStage to "shuffle"
        \(enabled ? "set shuffle mode to songs" : "")
        set shuffle enabled to \(enabled ? "true" : "false")
        return "ok"
        """, stage: .shuffle)
    }

    static func confirm(_ ownership: MusicPlaybackContextOwnership, selectedID: String?, shuffleEnabled: Bool?,
                        orderedMembers: Bool = false) throws -> String {
        try wrap("""
        \(selection(ownership))
        \(confirmationBody(playlistID: ownership.playlistID, expectedIDs: ownership.trackIDs,
                           selectedID: selectedID, shuffleEnabled: shuffleEnabled, orderedMembers: orderedMembers))
        """, stage: .currentPlaylist)
    }

    static func confirm(playlistID: String, expectedIDs: [String], selectedID: String?, shuffleEnabled: Bool?,
                        orderedMembers: Bool = false) throws -> String {
        try wrap(confirmationBody(playlistID: playlistID, expectedIDs: expectedIDs, selectedID: selectedID,
                                  shuffleEnabled: shuffleEnabled, orderedMembers: orderedMembers), stage: .currentPlaylist)
    }

    static func confirmationBody(playlistID: String, expectedIDs: [String],
                                 selectedID: String?, shuffleEnabled: Bool?, orderedMembers: Bool) throws -> String {
        try validate(playlistID)
        let trackCheck: String
        if let selectedID {
            try validate(selectedID)
            trackCheck = "if (persistent ID of current track) is not \"\(selectedID)\" then return \"pending-track\""
        } else { trackCheck = "" }
        let shuffleCheck = shuffleEnabled.map {
            "if (shuffle enabled) is not \($0 ? "true" : "false") then return \"pending-shuffle\""
        } ?? ""
        // 完整列表比较已包含长度；本机 AppleScript 在相邻 count 比较后会误接受同长度重排。
        let memberCheck = orderedMembers ? "if actualIDs is not expectedIDs then return \"mismatch\"" : """
        if (count of actualIDs) is not (count of expectedIDs) then return "mismatch"
        repeat with expectedID in expectedIDs
            if actualIDs does not contain (contents of expectedID) then return "mismatch"
        end repeat
        """
        return try """
        set contextStage to "currentPlaylist"
        if not (exists current playlist) then return "pending"
        if not (exists current track) then return "pending"
        if (persistent ID of current playlist) is not "\(playlistID)" then return "pending"
        set contextStage to "readback"
        set actualIDs to get persistent ID of every track of current playlist
        set expectedIDs to \(list(expectedIDs))
        \(memberCheck)
        if expectedIDs does not contain (persistent ID of current track) then return "pending-track"
        \(trackCheck)
        \(shuffleCheck)
        if player state is not playing then return "pending-playback"
        return "ok"
        """
    }

    static func remove(_ ownership: MusicPlaybackContextOwnership, allowStoppedCurrent: Bool = false) throws -> String {
        try validate(ownership.playlistID)
        return try wrap("""
        set matches to (user playlists whose persistent ID is "\(ownership.playlistID)")
        if (count of matches) is 0 then return "released"
        if (count of matches) is not 1 then error number -1728
        set targetPlaylist to item 1 of matches
        considering case
            if (name of targetPlaylist) is not "\(expectedName(for: ownership))" then return "released"
            if (description of targetPlaylist) is not "\(marker(ownership.token))" then return "released"
        end considering
        if (smart of targetPlaylist) then return "released"
        if (special kind of targetPlaylist) is folder then return "released"
        \(deletionPlaybackCheck(ownership, allowStoppedCurrent: allowStoppedCurrent))
        \(orderedMembersCheck(ownership.trackIDs, mismatch: "return \"released\""))
        \(deletionPlaybackCheck(ownership, allowStoppedCurrent: allowStoppedCurrent))
        delete targetPlaylist
        return "removed"
        """, stage: .cleanup)
    }

    private static func deletionPlaybackCheck(_ ownership: MusicPlaybackContextOwnership, allowStoppedCurrent: Bool) -> String {
        let stoppedCheck = allowStoppedCurrent
            ? "\(cleanupStoppedState)\nif not cleanupStopped then return \"playing\"" : ""
        return """
        \(stoppedCheck)
        if (exists current playlist) then
            if (persistent ID of current playlist) is "\(ownership.playlistID)" then
                \(allowStoppedCurrent ? stoppedCheck : "return \"playing\"")
            end if
        end if
        \(stoppedCheck)
        """
    }

    private static func selection(_ ownership: MusicPlaybackContextOwnership,
                                  mismatch: String = "error number -1728") throws -> String {
        try validate(ownership.playlistID)
        return """
        set contextStage to "select"
        set matches to (user playlists whose persistent ID is "\(ownership.playlistID)")
        if (count of matches) is not 1 then \(mismatch)
        set targetPlaylist to item 1 of matches
        considering case
            if (name of targetPlaylist) is not "\(expectedName(for: ownership))" then \(mismatch)
            if (description of targetPlaylist) is not "\(marker(ownership.token))" then \(mismatch)
        end considering
        if (smart of targetPlaylist) then \(mismatch)
        if (special kind of targetPlaylist) is folder then \(mismatch)
        """
    }

    private static func playlistSelection(_ id: String) throws -> String {
        try validate(id)
        return """
        set contextStage to "select"
        set matches to (user playlists whose persistent ID is "\(id)")
        if (count of matches) is 0 then error number -1728
        set targetPlaylist to item 1 of matches
        """
    }

    /// 比较完整集合；mismatch 仅由本文件的固定语句提供，不接受用户文本。
    private static func membersCheck(_ ids: [String], mismatch: String) throws -> String {
        try """
        set actualIDs to get persistent ID of every track of targetPlaylist
        set expectedIDs to \(list(ids))
        if (count of actualIDs) is not (count of expectedIDs) then \(mismatch)
        repeat with expectedID in expectedIDs
            if actualIDs does not contain (contents of expectedID) then \(mismatch)
        end repeat
        """
    }

    static func list(_ ids: [String]) throws -> String {
        try ids.forEach(validate)
        return "{" + ids.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
    }

    private static func validate(_ id: String) throws {
        guard SongBinding.isValidPersistentID(id) else { throw MusicLibraryError.invalidRequest }
    }

    private static func marker(_ token: UUID) -> String { "ShinApple playback context \(token.uuidString)" }

    static func wrap(_ body: String, stage: MusicPlaybackContextError.Stage) -> String {
        """
        set contextStage to "\(stage.rawValue)"
        with timeout of \(MusicLibraryScriptSources.eventTimeoutSeconds) seconds
            try
                if application id "com.apple.Music" is not running then error number -600
                tell application id "com.apple.Music"
                    \(body)
                end tell
            on error number contextError
                return {"context-error", contextStage, contextError}
            end try
        end timeout
        """
    }
}
