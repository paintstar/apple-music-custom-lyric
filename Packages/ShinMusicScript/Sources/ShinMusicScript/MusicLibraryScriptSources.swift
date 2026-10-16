import Foundation
import ShinAppleKit

/// 本机 com.apple.Music.sdef 已核查的公开字段；脚本只插入枚举字段与十六进制 ID。
enum MusicLibraryScriptSources {
    /// 每次 Apple Event 最多等待 4 秒；列间由宿主检查取消，不长时间占用播放采样锁。
    static let eventTimeoutSeconds = 4

    enum TrackColumn: String, CaseIterable {
        case persistentID = "persistent ID"
        case title = "name"
        case artist
        case albumArtist = "album artist"
        case album
        case duration
        case favorite = "favorited"
        case dateAdded = "date added"
    }

    /// Music.sdef 的公开 eSpK 枚举值。没有公开的“喜爱歌曲”类型，不按名称或私有值猜测。
    enum PlaylistKind: UInt32 {
        case folder = 0x6B53_7046 // kSpF
        case library = 0x6B53_704C // kSpL
        case music = 0x6B53_705A // kSpZ
    }

    enum PlaylistColumn: String {
        case persistentID = "persistent ID"
        case name
        case kind = "special kind"
        case smart
    }

    static func trackColumn(_ column: TrackColumn, in source: MusicLibrarySource) throws -> String {
        try wrap("\(selection(source))\nreturn get \(column.rawValue) of every track of targetPlaylist")
    }

    static func playlistColumn(_ column: PlaylistColumn) -> String {
        wrap("return get \(column.rawValue) of every user playlist")
    }

    /// 只识别公开词典中可分页读取的 library/user playlist，不猜测其它播放来源。
    static let currentPlaybackSource = wrap("""
    if not (exists current track) then return missing value
    if not (exists current playlist) then return missing value
    set playbackPlaylist to current playlist
    if (class of playbackPlaylist) is library playlist then return {"library"}
    if (class of playbackPlaylist) is user playlist then
        return {"playlist", (persistent ID of playbackPlaylist)}
    end if
    return missing value
    """)

    static func playlistParent(_ id: String) throws -> String {
        try wrap("""
        \(selection(.playlist(id: id)))
        try
            return get persistent ID of parent of targetPlaylist
        on error number errorNumber
            if errorNumber is -1728 then return missing value
            error number errorNumber
        end try
        """)
    }

    static func artwork(persistentID: String, in source: MusicLibrarySource = .library) throws -> String {
        guard SongBinding.isValidPersistentID(persistentID) else { throw MusicLibraryError.invalidRequest }
        let playlist: String
        switch source {
        case .library: playlist = "library playlist 1"
        case let .playlist(id):
            guard SongBinding.isValidPersistentID(id) else { throw MusicLibraryError.invalidRequest }
            playlist = "(first user playlist whose persistent ID is \"\(id)\")"
        }
        // 完整限定的引用只发一次 raw data 查询，不先 get 曲目或计数，减少在途阻塞。
        return wrap("""
        try
            return raw data of artwork 1 of (first track of \(playlist) whose persistent ID is "\(persistentID)")
        on error number errorNumber
            if errorNumber is -1728 then return missing value
            error number errorNumber
        end try
        """)
    }

    static func favorite(persistentID: String, value: Bool, in source: MusicLibrarySource = .library) throws -> String {
        try wrap("""
        \(trackSelection(persistentID, in: source))
        set targetDatabaseID to database ID of targetTrack
        set stableTracks to (tracks whose database ID is targetDatabaseID)
        if (count of stableTracks) is 0 then error number -1728
        set targetTrack to item 1 of stableTracks
        if (persistent ID of targetTrack) is not "\(persistentID)" then error number -1728
        set favorited of targetTrack to \(value ? "true" : "false")
        -- 取消喜爱可能使原歌单成员立即消失；重新从 application 的公开 track 集合定位。
        set stableTracks to (tracks whose database ID is targetDatabaseID)
        if (count of stableTracks) is 0 then error number -1728
        set confirmedTrack to item 1 of stableTracks
        if (persistent ID of confirmedTrack) is not "\(persistentID)" then error number -1728
        return favorited of confirmedTrack
        """)
    }

    private static func trackSelection(_ id: String, in source: MusicLibrarySource = .library) throws -> String {
        guard SongBinding.isValidPersistentID(id) else { throw MusicLibraryError.invalidRequest }
        return """
        \(try selection(source))
        set matchedTracks to (tracks of targetPlaylist whose persistent ID is "\(id)")
        if (count of matchedTracks) is 0 then error number -1728
        set targetTrack to item 1 of matchedTracks
        """
    }

    private static func selection(_ source: MusicLibrarySource) throws -> String {
        switch source {
        case .library:
            return "set targetPlaylist to library playlist 1"
        case .playlist(let id):
            guard SongBinding.isValidPersistentID(id) else { throw MusicLibraryError.invalidRequest }
            return """
            set matchedPlaylists to (user playlists whose persistent ID is "\(id)")
            if (count of matchedPlaylists) is 0 then error number -1728
            set targetPlaylist to item 1 of matchedPlaylists
            """
        }
    }

    private static func wrap(_ body: String) -> String {
        """
        if application id "com.apple.Music" is not running then error number -600
        with timeout of \(eventTimeoutSeconds) seconds
            tell application id "com.apple.Music"
                \(body)
            end tell
        end timeout
        """
    }
}

/// 库读取和按歌单上下文点播共用的错误映射；不把系统错误中的用户曲目信息带入日志。
enum MusicLibraryScriptExecution {
    static func execute(_ source: String, cancellation: MusicLibraryCancellation? = nil,
                        checkCancellation: () throws -> Void = {}) throws -> NSAppleEventDescriptor {
        try MusicAppleScriptExecution.withCancellableLock {
            // 请求可能在等其它服务释放 OSA 时取消；获锁后必须重新检查才可发出事件。
            try cancellation?.check()
            try checkCancellation()
            guard let script = NSAppleScript(source: source) else {
                throw MusicScriptFailure.unknown("library:scriptConstruction")
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                if code == -1728 { throw MusicLibraryError.sourceUnavailable }
                throw MusicScriptErrorMapper.failure(appleEventCode: code, detail: "library")
            }
            return result
        }
    }
}
