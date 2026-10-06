import CoreServices
import Foundation
import ShinAppleKit

// MARK: - NSAppleScript 兜底执行器

/// NSAppleScript 执行器（兜底路径，ScriptingBridge 不可用时使用）。
///
/// - 快照脚本使用固定模板；结果用 Apple Event 列表描述符逐项解析
///   （不用分隔符拼接文本，规避歌名含任意字符的解析错位）。
/// - 带参数命令（seek / 按 persistent ID 点播）用固定模板 + 数值/白名单
///   参数插值后编译执行：seek 参数经 "%.3f" 格式化（只含数字/点/负号）；
///   persistent ID 经十六进制白名单校验（SongBinding.isValidPersistentID）。
/// - 线程模型：与资料库/播放选项共用 OSA 生命周期锁；脚本实例在同一同步
///   闭包内构造、执行与释放，不跨调用缓存可能被并发 OSA 工作影响的实例。
public final class AppleScriptExecutor: MusicScriptExecutor, @unchecked Sendable {

    /// 快照脚本返回的标记（列表首项）。
    private enum Marker {
        static let ok = "ok"
        static let noTrack = "no-track"
        static let notRunning = "not-running"
        static let notFound = "not-found"
    }

    public init() {}

    // MARK: MusicScriptExecutor

    public func readSnapshot() -> MusicSnapshotOutcome {
        MusicAppleScriptExecution.withLock {
            guard let script = NSAppleScript(source: Self.snapshotSource) else {
                return .failed(.unknown("快照脚本编译失败"))
            }
            do {
                return Self.parseSnapshotList(try execute(script))
            } catch let failure as MusicScriptFailure {
                return .failed(failure)
            } catch {
                return .failed(.unknown("快照脚本执行失败"))
            }
        }
    }

    public func play() throws {
        try runSource(Self.commandSource("play"), name: "play")
    }

    public func pause() throws {
        try runSource(Self.commandSource("pause"), name: "pause")
    }

    public func nextTrack() throws {
        try runSource(Self.commandSource("next track"), name: "nextTrack")
    }

    public func previousTrack() throws {
        try runSource(Self.commandSource("previous track"), name: "previousTrack")
    }

    public func seek(toSeconds seconds: Double) throws {
        // "%.3f" 只产生数字/点/负号：数值插值无注入面。
        let source = Self.commandSource("set player position \(String(format: "%.3f", seconds))")
        try runSource(source, name: "seek")
    }

    public func playPersistentID(_ persistentID: String) throws {
        guard SongBinding.isValidPersistentID(persistentID) else {
            throw MusicScriptFailure.trackNotFound
        }
        let source = """
        if application "Music" is not running then return "\(Marker.notRunning)"
        tell application "Music"
            set matches to (tracks of library playlist 1 whose persistent ID is "\(persistentID)")
            if (count of matches) is 0 then return "\(Marker.notFound)"
            play (item 1 of matches)
            return "\(Marker.ok)"
        end tell
        """
        try MusicAppleScriptExecution.withLock {
            guard let script = NSAppleScript(source: source) else {
                throw MusicScriptFailure.unknown("点播脚本编译失败")
            }
            let result = try execute(script)
            switch result?.stringValue {
            case Marker.notRunning:
                throw MusicScriptFailure.musicNotRunning
            case Marker.notFound:
                throw MusicScriptFailure.trackNotFound
            case Marker.ok:
                return
            default:
                throw MusicScriptFailure.unknown("点播脚本返回意外结果")
            }
        }
    }

    // MARK: - 快照列表解析（static 纯函数，供单元测试）

    /// 解析快照脚本返回的列表描述符。
    /// 预期形式：{"ok", state 文本, persistentID, name, artist, album, duration, position}
    /// 或 {"no-track", state 文本} 或文本 "not-running"。
    static func parseSnapshotList(_ descriptor: NSAppleEventDescriptor?) -> MusicSnapshotOutcome {
        guard let descriptor else {
            return .failed(.unknown("快照脚本无结果"))
        }
        // 顶层文本：not-running。
        if let text = descriptor.stringValue {
            if text == Marker.notRunning {
                return .musicNotRunning
            }
            return .failed(.unknown("快照脚本返回意外文本：\(text)"))
        }
        guard descriptor.descriptorType == typeAEList else {
            return .failed(.unknown("快照脚本返回类型意外：\(descriptor.descriptorType)"))
        }
        let count = descriptor.numberOfItems
        guard count >= 1 else {
            return .failed(.unknown("快照脚本返回空列表"))
        }
        guard let marker = descriptor.atIndex(1)?.stringValue else {
            return .failed(.unknown("快照脚本首项非文本"))
        }
        switch marker {
        case Marker.notRunning:
            return .musicNotRunning
        case Marker.noTrack:
            return .noCurrentTrack(stateCode: stateCode(fromText: descriptor.atIndex(2)?.stringValue))
        case Marker.ok:
            return parseOkList(descriptor, itemCount: count)
        default:
            return .failed(.unknown("快照脚本标记未知：\(marker)"))
        }
    }

    private static func parseOkList(
        _ descriptor: NSAppleEventDescriptor,
        itemCount: Int
    ) -> MusicSnapshotOutcome {
        guard itemCount == 8 else {
            return .failed(.fieldUnavailable("snapshot:\(itemCount)项"))
        }
        let stateText = descriptor.atIndex(2)?.stringValue
        guard let stateCode = stateCode(fromText: stateText) else {
            return .failed(.fieldUnavailable("playerState"))
        }
        guard let pid = descriptor.atIndex(3)?.stringValue else {
            return .failed(.fieldUnavailable("persistentID"))
        }
        // 歌名等文本字段：脚本返回 missing value 时为 nil（未知值不是空串）。
        let title = descriptor.atIndex(4)?.stringValue
        let artist = descriptor.atIndex(5)?.stringValue
        let album = descriptor.atIndex(6)?.stringValue
        let duration = numberValue(descriptor.atIndex(7))
        let position = numberValue(descriptor.atIndex(8))
        return .snapshot(
            MusicScriptRawSnapshot(
                playerStateCode: stateCode,
                positionSeconds: position,
                persistentID: pid,
                title: title,
                artist: artist,
                album: album,
                durationSeconds: duration
            )
        )
    }

    /// 状态文本 → FourCharCode；未知文本记为字段不可用（不猜测）。
    private static func stateCode(fromText text: String?) -> Int? {
        guard let text else { return nil }
        return MusicScriptPlayerState.fromAppleScriptText(text)
    }

    /// 描述符 → Double。先查 descriptorType 再取值（NSAppleEventDescriptor
    /// 的数值访问器对类型不符会抛 ObjC 异常，不能盲取）；
    /// 缺项/意外类型 nil（未知值不是 0）。
    private static func numberValue(_ descriptor: NSAppleEventDescriptor?) -> Double? {
        guard let descriptor else { return nil }
        // Apple Event 数值类型（AEDataModel FourCharCode；Swift 未直接暴露）。
        let typeFloatCode: OSType = 0x646F_7562 // 'doub'
        let typeLongCode: OSType = 0x6C6F_6E67 // 'long'
        switch descriptor.descriptorType {
        case typeFloatCode:
            let value = descriptor.doubleValue
            return value.isFinite ? value : nil
        case typeLongCode:
            return Double(descriptor.int32Value)
        default:
            return nil
        }
    }

    // MARK: - 脚本模板

    /// 快照脚本：单次 Apple Event 返回全部字段（列表）。
    /// 变量名避开 Music 词典与 AppleScript 保留字，防止脚本编译冲突。
    private static let snapshotSource = """
    if application "Music" is not running then return "not-running"
    tell application "Music"
        if (exists current track) then
            set trk to current track
            return {"ok", (player state as text), (persistent ID of trk), (name of trk), ¬
            (artist of trk), (album of trk), (duration of trk), (player position)}
        end if
        return {"no-track", (player state as text)}
    end tell
    """

    /// 固定命令模板（程序与命令白名单；不含任何用户文本）。
    private static func commandSource(_ command: String) -> String {
        """
        if application "Music" is not running then return "not-running"
        tell application "Music"
            \(command)
        end tell
        return "ok"
        """
    }

    // MARK: - 执行

    private func runSource(_ source: String, name: String) throws {
        try MusicAppleScriptExecution.withLock {
            guard let script = NSAppleScript(source: source) else {
                throw MusicScriptFailure.unknown("\(name) 脚本编译失败")
            }
            let result = try execute(script)
            switch result?.stringValue {
            case Marker.notRunning:
                throw MusicScriptFailure.musicNotRunning
            case Marker.ok:
                return
            default:
                throw MusicScriptFailure.unknown("\(name) 脚本返回意外结果")
            }
        }
    }

    /// 调用方已持 OSA 生命周期锁；执行脚本并映射为执行器层失败。
    private func execute(_ script: NSAppleScript) throws -> NSAppleEventDescriptor? {
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = (errorInfo[NSAppleScript.errorBriefMessage] as? String) ?? ""
            throw MusicScriptErrorMapper.failure(appleEventCode: code, detail: message)
        }
        return result
    }
}
