import Foundation
import ShinAppleKit

/// 读序与时间戳在执行锁内取得，和命令返回后回读使用同一顺序。
struct MusicScriptSample: Sendable {
    let order: Int
    let outcome: MusicSnapshotOutcome
    let sampledAtMs: Int64
    let requestDurationMs: Int64

    func snapshot(after previous: PlaybackSnapshot) -> PlaybackSnapshot? {
        var snapshot = PlaybackSnapshot(
            trackEpoch: previous.trackEpoch, seq: previous.seq + 1,
            sessionEpoch: previous.sessionEpoch, sampledAtMonotonicMs: sampledAtMs,
            requestDurationMs: requestDurationMs, capabilities: previous.capabilities
        )
        switch outcome {
        case .identityChangedDuringRead:
            return nil
        case .musicNotRunning:
            snapshot.status = .notRunning
        case .noCurrentTrack(let stateCode):
            snapshot.status = .noTrack
            if let stateCode, MusicScriptMapping.status(forStateCode: stateCode) == nil {
                snapshot.errorCode = MusicScriptMapping.unknownStateCode(stateCode)
            }
        case .snapshot(let raw):
            apply(raw, to: &snapshot)
        case .failed(let failure):
            snapshot.trackRef = previous.trackRef
            snapshot.status = .error
            snapshot.errorCode = failure.errorCode
        }
        if snapshot.trackRef != previous.trackRef {
            snapshot.trackEpoch += 1
        }
        return snapshot
    }

    private func apply(_ raw: MusicScriptRawSnapshot, to snapshot: inout PlaybackSnapshot) {
        snapshot.trackRef = raw.persistentID.map(SongBinding.trackKey(persistentID:))
        snapshot.title = raw.title
        snapshot.artist = raw.artist
        snapshot.positionMs = raw.positionSeconds.flatMap(MusicScriptMapping.secondsToMs)
        snapshot.durationMs = raw.durationSeconds.flatMap(MusicScriptMapping.secondsToMs)
        if let status = MusicScriptMapping.status(forStateCode: raw.playerStateCode) {
            snapshot.status = status
        } else {
            snapshot.status = .error
            snapshot.errorCode = MusicScriptMapping.unknownStateCode(raw.playerStateCode)
        }
    }
}

/// Music 可能先读到例句位置，随后短暂读到初始化位置或跳转前的位置。
/// 连续命中才确认跳转，并在确认后的短窗口内保留已读取的有效样本。
struct MusicVocabularyReadback: Sendable {
    static let confirmationBudget: Duration = .milliseconds(600)
    static let pollInterval: TimeInterval = 0.05
    private static let protectionMs: Int64 = 1_200
    private static let positionToleranceMs: Int64 = 400

    let trackRef: String
    let targetMs: Int64
    let previousPositionMs: Int64?
    var confirmedAtMs: Int64?

    func confirms(_ sample: MusicScriptSample, following firstMatchAtMs: Int64?) -> Bool {
        guard case .snapshot(let raw) = sample.outcome,
              raw.persistentID.map(SongBinding.trackKey(persistentID:)) == trackRef,
              raw.playerStateCode == MusicScriptPlayerState.playing,
              let position = raw.positionSeconds.flatMap(MusicScriptMapping.secondsToMs) else { return false }
        let elapsedMs = firstMatchAtMs.map { max(sample.sampledAtMs - $0, 0) } ?? 0
        let offset = position - targetMs
        return offset >= -Self.positionToleranceMs && offset <= elapsedMs + Self.positionToleranceMs
    }

    func shouldContinueWaiting(for sample: MusicScriptSample) -> Bool {
        switch sample.outcome {
        case .snapshot(let raw):
            return raw.persistentID == nil || raw.persistentID.map(SongBinding.trackKey(persistentID:)) == trackRef
        case .identityChangedDuringRead, .noCurrentTrack:
            return true
        case .musicNotRunning, .failed:
            return false
        }
    }

    mutating func confirm(at sampledAtMs: Int64) {
        confirmedAtMs = sampledAtMs
    }

    func isActive(for snapshot: PlaybackSnapshot) -> Bool {
        snapshot.trackRef == trackRef && snapshot.status == .playing
            && protectionElapsed(at: snapshot.sampledAtMonotonicMs) != nil
    }

    func shouldHold(_ snapshot: PlaybackSnapshot, after previous: PlaybackSnapshot) -> Bool {
        guard previous.trackRef == trackRef, previous.status == .playing,
              let elapsedMs = protectionElapsed(at: snapshot.sampledAtMonotonicMs) else { return false }
        switch snapshot.status {
        case .noTrack:
            return snapshot.errorCode == nil
        case .playing, .paused, .idle:
            return snapshot.trackRef == nil ||
                (snapshot.trackRef == trackRef && isTransientPosition(snapshot, after: previous, elapsedMs: elapsedMs))
        default: return false
        }
    }

    private func isTransientPosition(_ snapshot: PlaybackSnapshot, after previous: PlaybackSnapshot, elapsedMs: Int64) -> Bool {
        guard let positionMs = snapshot.positionMs else { return true }
        let tolerance = Self.positionToleranceMs
        let lastPosition = previous.positionMs ?? targetMs
        let movement = positionMs - lastPosition
        // 初始化后的起点也可能已经播放了几百毫秒，不能只认精确的零。
        if movement < -tolerance, positionMs <= elapsedMs + tolerance { return true }
        guard let previousPositionMs, abs(previousPositionMs - targetMs) > 2 * tolerance,
              abs(positionMs - previousPositionMs) <= tolerance else { return false }
        let sincePrevious = max(snapshot.sampledAtMonotonicMs - previous.sampledAtMonotonicMs, 0)
        return movement < -tolerance || movement > sincePrevious + tolerance
    }

    private func protectionElapsed(at sampledAtMs: Int64) -> Int64? {
        guard let confirmedAtMs, sampledAtMs >= confirmedAtMs else { return nil }
        let elapsed = sampledAtMs - confirmedAtMs
        return elapsed < Self.protectionMs ? elapsed : nil
    }
}
