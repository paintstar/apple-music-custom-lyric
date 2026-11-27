import Foundation
import ShinAppleKit

extension MusicScriptPlaybackController {
    public func playVocabularyExample(
        trackKey: String, positionMs: Int64?
    ) async throws -> VocabularyPlaybackResult {
        try await performVocabularyExample(trackKey: trackKey, positionMs: positionMs, expected: nil)
    }

    public func playVocabularyExample(
        trackKey: String, positionMs: Int64?, replacingQueueFor expected: PlaybackSnapshot
    ) async throws -> VocabularyPlaybackResult {
        try await performVocabularyExample(trackKey: trackKey, positionMs: positionMs, expected: expected)
    }
}

extension MusicScriptExecutor {
    func playVocabularyExample(
        persistentID: String, positionMs: Int64?, expected: PlaybackSnapshot?, current: PlaybackSnapshot,
        checkCancellation: () throws -> Void
    ) throws -> MusicVocabularyCommandResult {
        guard let expected else {
            return try playVocabularyExample(persistentID: persistentID, positionMs: positionMs, checkCancellation: checkCancellation)
        }
        guard let originalID = confirmedVocabularyTrackID(expected, current: current) else { return .queueProtected }
        return try playVocabularyExample(
            persistentID: persistentID, positionMs: positionMs, replacingPersistentID: originalID,
            checkCancellation: checkCancellation
        )
    }

    private func confirmedVocabularyTrackID(_ expected: PlaybackSnapshot, current: PlaybackSnapshot) -> String? {
        guard current.sessionEpoch == expected.sessionEpoch, current.trackEpoch == expected.trackEpoch,
              current.trackRef == expected.trackRef, current.status != .error, expected.status != .error else { return nil }
        if let trackRef = current.trackRef { return MusicScriptMapping.persistentID(fromTrackRef: trackRef) }
        return current.status == .noTrack && expected.status == .noTrack ? "" : nil
    }
}

/// 原声例句借用 Music 的公开播放命令。切曲后只在目标曲目已接管播放器时设置位置。
enum MusicVocabularyPlayback {
    private static let readinessBudget: Duration = .milliseconds(600)
    private static let readinessPollInterval: TimeInterval = 0.05
    private static let readbackEventTimeoutSeconds = 1

    private enum Step {
        case played
        case protected
        case positionRequested(Int64)
        case starting
        case pending
        case interrupted
    }

    static func perform(
        persistentID: String, positionMs: Int64?, replacingPersistentID: String? = nil,
        execute: (String) throws -> NSAppleEventDescriptor?, checkCancellation: () throws -> Void
    ) throws -> MusicVocabularyCommandResult {
        let start = try startScript(
            persistentID: persistentID, positionMs: positionMs, replacingPersistentID: replacingPersistentID
        )
        try checkCancellation()
        switch try step(execute(start)) {
        case .played:
            return .played
        case .protected:
            return .queueProtected
        case .positionRequested(let targetMs):
            return .positionRequested(targetMs)
        case .starting:
            let finish = finishScript(
                persistentID: persistentID, positionMs: positionMs, replacingPersistentID: replacingPersistentID
            )
            return try waitForTarget(finish, execute: execute, checkCancellation: checkCancellation)
        case .pending, .interrupted:
            return .targetNotReady
        }
    }

    private static func waitForTarget(
        _ source: String, execute: (String) throws -> NSAppleEventDescriptor?, checkCancellation: () throws -> Void
    ) throws -> MusicVocabularyCommandResult {
        let deadline = ContinuousClock.now.advanced(by: readinessBudget)
        repeat {
            try checkCancellation()
            switch try step(execute(source)) {
            case .played:
                return .played
            case .positionRequested(let targetMs):
                return .positionRequested(targetMs)
            case .pending:
                break
            default:
                return .targetNotReady
            }
            guard ContinuousClock.now < deadline else { break }
            Thread.sleep(forTimeInterval: readinessPollInterval)
        } while ContinuousClock.now < deadline
        return .targetNotReady
    }

    static func startScript(
        persistentID: String, positionMs: Int64?, replacingPersistentID: String? = nil
    ) throws -> String {
        guard SongBinding.isValidPersistentID(persistentID) else { throw MusicScriptFailure.trackNotFound }
        let sameTrack = sameTrackCommands(persistentID: persistentID, positionMs: positionMs)
        let playbackCheck: String
        if let replacingPersistentID {
            guard replacingPersistentID.isEmpty || SongBinding.isValidPersistentID(replacingPersistentID) else {
                throw MusicScriptFailure.trackNotFound
            }
            let stoppedCheck = replacingPersistentID.isEmpty ? " or player state is not stopped" : ""
            playbackCheck = """
            if activeID is not "\(replacingPersistentID)"\(stoppedCheck) then return {"protected"}
            \(sameTrack)
            """
        } else {
            playbackCheck = """
            \(sameTrack)
            if activeID is not "" or player state is not stopped or (exists current playlist) then
                return {"protected"}
            end if
            """
        }
        return wrap("""
        \(readCurrentID)
        \(playbackCheck)
        try
            set targetTrack to first track of library playlist 1 whose persistent ID is "\(persistentID)"
        on error number commandError
            if commandError is -1728 then return {"missing"}
            error number commandError
        end try
        \(readCurrentID)
        \(playbackCheck)
        try
            play targetTrack without once
        on error number commandError
            if commandError is -1728 then return {"missing"}
            error number commandError
        end try
        return {"starting"}
        """)
    }

    static func finishScript(
        persistentID: String, positionMs: Int64?, replacingPersistentID: String? = nil
    ) -> String {
        let waitingForSwitch = replacingPersistentID.flatMap { id in
            SongBinding.isValidPersistentID(id) ? #" or activeID is "\#(id)""# : nil
        } ?? ""
        return wrap("""
        \(readCurrentID)
        if activeID is "\(persistentID)" then
            \(positionCommands(persistentID: persistentID, positionMs: positionMs, unready: "pending"))
        end if
        if activeID is ""\(waitingForSwitch) then return {"pending"}
        return {"interrupted"}
        """, timeoutSeconds: readbackEventTimeoutSeconds)
    }

    private static func sameTrackCommands(persistentID: String, positionMs: Int64?) -> String {
        """
        if activeID is "\(persistentID)" then
            set activeState to player state
            if activeState is paused or activeState is stopped then
                \(readCurrentID)
                if activeID is not "\(persistentID)" then return {"interrupted"}
                play
            end if
            \(positionCommands(persistentID: persistentID, positionMs: positionMs, unready: "interrupted"))
        end if
        """
    }

    private static func positionCommands(persistentID: String, positionMs: Int64?, unready: String) -> String {
        guard let positionMs else { return #"return {"played"}"# }
        let seconds = Double(max(positionMs, 0)) / 1_000
        let position = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        return """
        try
            set targetPosition to \(position)
            set trackDuration to duration of current track
            if trackDuration is not missing value and trackDuration > 0 and targetPosition > trackDuration then
                set targetPosition to trackDuration
            end if
            \(readCurrentID)
            if activeID is not "\(persistentID)" then return {"interrupted"}
            set player position to targetPosition
            return {"position-requested", targetPosition as real}
        on error number seekError
            if seekError is -1728 then return {"\(unready)"}
            error number seekError
        end try
        """
    }

    private static let readCurrentID = """
    set activeID to ""
    try
        if exists current track then set activeID to persistent ID of current track
    on error number readError
        if readError is not -1728 then error number readError
    end try
    """

    private static func wrap(_ body: String, timeoutSeconds: Int = MusicLibraryScriptSources.eventTimeoutSeconds) -> String {
        """
        if application id "com.apple.Music" is not running then error number -600
        with timeout of \(timeoutSeconds) seconds
            tell application id "com.apple.Music"
                \(body)
            end tell
        end timeout
        """
    }

    private static func step(_ result: NSAppleEventDescriptor?) throws -> Step {
        guard let result, let marker = result.atIndex(1)?.stringValue else {
            throw MusicScriptFailure.unknown("vocabulary:readback")
        }
        switch marker {
        case "played": return .played
        case "protected": return .protected
        case "position-requested":
            guard let seconds = AppleScriptExecutor.numberValue(result.atIndex(2)),
                  let positionMs = MusicScriptMapping.secondsToMs(seconds) else {
                throw MusicScriptFailure.unknown("vocabulary:invalidTargetPosition")
            }
            return .positionRequested(positionMs)
        case "starting": return .starting
        case "pending": return .pending
        case "interrupted": return .interrupted
        case "missing": throw MusicScriptFailure.trackNotFound
        default: throw MusicScriptFailure.unknown("vocabulary:readback")
        }
    }
}
