import Foundation
import ShinAppleKit

// MARK: - 词典值 → domain 的纯映射（单元测试的直接对象）

enum MusicScriptMapping {

    /// 秒 → 整数毫秒（唯一换算边界）。规则：
    /// - 非有限（NaN/∞）→ nil（未知不是 0）；
    /// - 负值 → 0（曲目起点的浮点噪声，如 -0.001，真实位置即起点）；
    /// - 其余四舍五入（词典 real 为 float32 精度，≈毫秒级）。
    static func secondsToMs(_ seconds: Double) -> Int64? {
        guard seconds.isFinite else { return nil }
        if seconds <= 0 { return 0 }
        let milliseconds = (seconds * 1_000).rounded()
        guard milliseconds.isFinite, milliseconds < Double(Int64.max) else { return nil }
        return Int64(milliseconds)
    }

    /// player state FourCharCode → domain PlayerStatus。
    /// 不认识的枚举值返回 nil（调用方按未知状态呈现，绝不冒充 playing/idle）。
    static func status(forStateCode code: Int?) -> PlayerStatus? {
        switch code {
        case MusicScriptPlayerState.playing: return .playing
        case MusicScriptPlayerState.paused: return .paused
        case MusicScriptPlayerState.stopped: return .idle
        case MusicScriptPlayerState.fastForwarding, MusicScriptPlayerState.rewinding: return .seeking
        default: return nil
        }
    }

    /// 未知状态码的稳定 errorCode。
    static func unknownStateCode(_ code: Int?) -> String {
        guard let code else { return "music:fieldUnavailable:playerState" }
        return "music:unknownState:\(MusicScriptPlayerState.describe(code))"
    }

    /// 执行器失败 → domain PlaybackError（命令路径）。
    static func playbackError(for failure: MusicScriptFailure) -> PlaybackError {
        switch failure {
        case .permissionDenied:
            return .unauthorized
        case .musicNotRunning:
            return .musicNotRunning
        case .timeout:
            return .unknown("music:timeout")
        case .fieldUnavailable(let field):
            return .unknown("music:fieldUnavailable:\(field)")
        case .commandUnsupported(let command):
            return .unknown("music:commandUnsupported:\(command)")
        case .trackNotFound:
            return .trackUnavailable
        case .unknown(let detail):
            return .unknown("music:unknown:\(detail)")
        }
    }

    /// trackRef（`music-script:persistent:<persistentID>`）→ persistentID。
    /// 命名空间或字符白名单不符返回 nil（调用方拒绝，不猜测）。
    static func persistentID(fromTrackRef trackRef: String) -> String? {
        guard trackRef.hasPrefix(SongBinding.scriptTrackKeyPrefix) else { return nil }
        let persistentID = String(trackRef.dropFirst(SongBinding.scriptTrackKeyPrefix.count))
        guard SongBinding.isValidPersistentID(persistentID) else { return nil }
        return persistentID
    }
}
