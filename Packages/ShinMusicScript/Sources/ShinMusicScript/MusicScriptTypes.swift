import Foundation

// MARK: - 执行器层数据类型（Music 脚本词典口径；秒为 Double，毫秒换算只发生在控制器边界）

/// Music 播放器状态（词典 ePlS 枚举的 FourCharCode）。
/// SB 直接返回该整数；NSAppleScript 文本形式经 fromAppleScriptText 映射到同一编码。
public enum MusicScriptPlayerState {
    public static let stopped = 0x6B50_5353 // 'kPSS'
    public static let playing = 0x6B50_5350 // 'kPSP'
    public static let paused = 0x6B50_5370 // 'kPSp'
    public static let fastForwarding = 0x6B50_5346 // 'kPSF'
    public static let rewinding = 0x6B50_5352 // 'kPSR'

    /// AppleScript 文本（`player state as text`）→ FourCharCode；未知文本 nil。
    public static func fromAppleScriptText(_ text: String) -> Int? {
        switch text {
        case "stopped": return stopped
        case "playing": return playing
        case "paused": return paused
        case "fast forwarding": return fastForwarding
        case "rewinding": return rewinding
        default: return nil
        }
    }

    /// 调试/日志用的稳定文本。
    public static func describe(_ code: Int) -> String {
        switch code {
        case stopped: return "stopped"
        case playing: return "playing"
        case paused: return "paused"
        case fastForwarding: return "fast forwarding"
        case rewinding: return "rewinding"
        default: return "unknown(\(code))"
        }
    }
}

/// 一次快照读取的原始字段（词典口径）。未知值一律 nil，绝不冒充 0。
public struct MusicScriptRawSnapshot: Equatable, Sendable {
    /// ePlS FourCharCode；读取失败为 nil。
    public var playerStateCode: Int?
    /// 播放位置（秒，词典 real）；读取失败为 nil。非有限/负值由控制器换算规则处理。
    public var positionSeconds: Double?
    /// 曲目 persistent ID（词典：hexadecimal string）；无曲目时为 nil。
    public var persistentID: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    /// 曲目时长（秒，词典 real）；读取失败为 nil。
    public var durationSeconds: Double?

    public init(
        playerStateCode: Int? = nil,
        positionSeconds: Double? = nil,
        persistentID: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.playerStateCode = playerStateCode
        self.positionSeconds = positionSeconds
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
    }
}

/// 一次快照读取的产出（执行器层错误已分类）。
public enum MusicSnapshotOutcome: Equatable, Sendable {
    /// Music 未运行（未发送任何会拉起它的查询）。
    case musicNotRunning
    /// Music 运行但无当前曲目；附带可读到的 player state（可能为 nil）。
    case noCurrentTrack(stateCode: Int?)
    /// 完整快照（执行器已保证同批身份一致：persistent ID 前后两次读取相同）。
    case snapshot(MusicScriptRawSnapshot)
    /// 同批读取期间曲目发生变化：整批丢弃，不组装 A 歌名 + B 进度的混合快照。
    case identityChangedDuringRead
    case failed(MusicScriptFailure)
}

/// 执行器层的类型化失败，供上层按原因分类处理。
public enum MusicScriptFailure: Error, Equatable, Sendable {
    /// Apple Event 权限被拒（-1743 errAEEventNotPermitted，TCC 自动化未授权）。
    case permissionDenied
    /// Music 未运行（命令无处投递）。
    case musicNotRunning
    /// Apple Event 超时（-1712 errAETimeout）。
    case timeout
    /// 单个字段不可用（读取失败/对象缺失），附字段名。
    case fieldUnavailable(String)
    /// 命令不受当前执行器支持，附命令名。
    case commandUnsupported(String)
    /// 按 persistent ID 定位不到音乐库曲目。
    case trackNotFound
    /// 未能归类的错误，附稳定细节文本。
    case unknown(String)

    /// 快照 errorCode 用稳定字符串（可展示、可判别）。
    public var errorCode: String {
        switch self {
        case .permissionDenied: return "music:permissionDenied"
        case .musicNotRunning: return "music:notRunning"
        case .timeout: return "music:timeout"
        case .fieldUnavailable(let field): return "music:fieldUnavailable:\(field)"
        case .commandUnsupported(let command): return "music:commandUnsupported:\(command)"
        case .trackNotFound: return "music:trackNotFound"
        case .unknown(let detail): return "music:unknown:\(detail)"
        }
    }
}

/// Music 脚本执行器契约（本包内抽象，注入假实现做单元测试；
/// 实现必须保证调用线程安全由调用方串行化约束满足）。
public protocol MusicScriptExecutor: AnyObject, Sendable {
    /// 读取一次播放快照。实现必须：
    /// - Music 未运行时返回 .musicNotRunning，且不发送会拉起 Music 的查询；
    /// - 对同批读取做 persistent ID 前后一致性校验（不一致 → .identityChangedDuringRead）。
    func readSnapshot() -> MusicSnapshotOutcome

    func play() throws
    func pause() throws
    func nextTrack() throws
    func previousTrack() throws

    /// seek 到指定秒数（控制器已完成裁剪；越界不会传入）。
    func seek(toSeconds seconds: Double) throws

    /// 按 persistent ID 在音乐库定位曲目并播放（v2 点播预留）。
    func playPersistentID(_ persistentID: String) throws
}

/// Apple Event / 脚本错误码 → 执行器层失败的统一映射。
enum MusicScriptErrorMapper {
    /// errAEEventNotPermitted：TCC 自动化权限被拒。
    static let errAEEventNotPermitted = -1743
    /// errAETimeout：Apple Event 等待超时。
    static let errAETimeout = -1712
    /// procNotFound：目标应用未运行。
    static let procNotFound = -600
    /// errAENoSuchObject：对象不存在（如当前曲目缺失）。
    static let errAENoSuchObject = -1728

    /// 按 Apple Event / AppleScript 错误码分类。
    static func failure(appleEventCode code: Int, detail: String) -> MusicScriptFailure {
        switch code {
        case errAEEventNotPermitted:
            return .permissionDenied
        case errAETimeout:
            return .timeout
        case procNotFound:
            return .musicNotRunning
        case errAENoSuchObject:
            return .fieldUnavailable(detail)
        default:
            return .unknown("\(code):\(detail)")
        }
    }

    /// NSError（含 ShinMSObjC 捕获的异常包装）→ 执行器层失败。
    static func failure(from error: NSError) -> MusicScriptFailure {
        if error.domain == "ShinMSObjCExceptionDomain" {
            // SB 以 NSException 表达的失败没有稳定错误码，按细节文本归类。
            let detail = error.localizedDescription
            if detail.contains("not running") || detail.contains(" couldn’t be contacted") {
                return .musicNotRunning
            }
            return .unknown("exception:\(detail)")
        }
        return failure(appleEventCode: error.code, detail: String(error.code))
    }
}
