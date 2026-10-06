import CoreServices
import Foundation
import OSLog
import ShinAppleKit

struct AppleScriptPlaybackOptionsExecutor: PlaybackOptionsScriptExecuting {
    func execute(_ command: PlaybackOptionsCommand, checkCancellation: () throws -> Void) throws -> PlaybackOptionsSnapshot {
        try MusicAppleScriptExecution.withLock {
            // 各服务共用生命周期锁，避免正式 App 并发首读出现 errOSAInvalidID。
            try checkCancellation()
            guard let script = NSAppleScript(source: try Self.source(for: command)) else {
                throw MusicScriptFailure.unknown("播放选项脚本无法创建")
            }
            var errorInfo: NSDictionary?
            guard script.compileAndReturnError(&errorInfo) else {
                throw Self.failure(errorInfo, stage: "compile")
            }
            try checkCancellation()
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                throw Self.failure(errorInfo, stage: "execute")
            }
            return try Self.parse(descriptor)
        }
    }

    private static func failure(_ errorInfo: NSDictionary?, stage: String) -> MusicScriptFailure {
        let code = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        #if DEBUG
        // 仅输出固定阶段与数字代码，不输出脚本或 Music 返回的原始文字。
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "ShinMusicScript", category: "PlaybackOptions")
            .error("stage=\(stage, privacy: .public) code=\(code, privacy: .public)")
        #endif
        return MusicScriptErrorMapper.failure(appleEventCode: code, detail: "播放选项读写失败")
    }

    static func source(for command: PlaybackOptionsCommand) throws -> String {
        let mutation: String
        switch command {
        case .read: mutation = ""
        case let .volume(volume):
            guard (0...100).contains(volume) else { throw PlaybackOptionsError.invalidVolume }
            mutation = "set sound volume to \(volume)"
        case let .shuffle(enabled): mutation = "set shuffle enabled to \(enabled ? "true" : "false")"
        case let .repeatMode(mode): mutation = "set song repeat to \(mode.rawValue)"
        }
        // 仅插入验证过的整数、布尔与封闭枚举；目标与其余语句均固定。
        // 词典依据：com.apple.Music.sdef application sound volume/shuffle enabled/song repeat、eRpt。
        return """
        with timeout of 5 seconds
            if application id "com.apple.Music" is not running then return "not-running"
            tell application id "com.apple.Music"
                \(mutation)
                set optionVolume to missing value
                set optionShuffle to missing value
                set optionRepeat to missing value
                try
                    set optionVolume to sound volume
                on error number optionError
                    if optionError is not -1728 then error number optionError
                end try
                try
                    set optionShuffle to shuffle enabled
                on error number optionError
                    if optionError is not -1728 then error number optionError
                end try
                try
                    set repeatValue to song repeat
                    if repeatValue is off then set optionRepeat to "off"
                    if repeatValue is all then set optionRepeat to "all"
                    if repeatValue is one then set optionRepeat to "one"
                on error number optionError
                    if optionError is not -1728 then error number optionError
                end try
                return {"ok", optionVolume, optionShuffle, optionRepeat}
            end tell
        end timeout
        """
    }

    static func parse(_ descriptor: NSAppleEventDescriptor) throws -> PlaybackOptionsSnapshot {
        if descriptor.stringValue == "not-running" { throw MusicScriptFailure.musicNotRunning }
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems == 4,
              descriptor.atIndex(1)?.stringValue == "ok" else {
            throw MusicScriptFailure.fieldUnavailable("playbackOptions")
        }
        let volume: Int? = descriptor.atIndex(2).flatMap {
            guard $0.descriptorType == typeSInt32 else { return nil }
            let value = Int($0.int32Value)
            return (0...100).contains(value) ? value : nil
        }
        let shuffle: Bool? = descriptor.atIndex(3).flatMap {
            switch $0.descriptorType {
            case typeBoolean, typeTrue, typeFalse: return $0.booleanValue
            default: return nil
            }
        }
        let repeatMode = descriptor.atIndex(4)?.stringValue.flatMap(PlaybackRepeatMode.init(rawValue:))
        return PlaybackOptionsSnapshot(volume: volume, shuffleEnabled: shuffle, repeatMode: repeatMode)
    }
}
