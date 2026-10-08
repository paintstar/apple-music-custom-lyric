import Foundation
import AppKit
import ScriptingBridge
import ShinAppleKit
import ShinMSObjC

// MARK: - SB 协议（选择器按 com.apple.Music.sdef 属性/命令名推导；
// 属性声明为非 Optional：optional 成员访问在 Swift 侧自带一层 Optional，
// 实际读取失败时得到 nil，与「未知值 nil」语义一致）

@objc protocol SBMusicTrackProtocol: NSObjectProtocol {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Double { get }
    @objc optional var persistentID: String { get }
    /// 曲目封面元素集合（sdef class artwork）。无封面时 SB 返回空集合或抛
    /// -1728（经 ObjC 异常捕获归一为读取失败 → nil）。
    @objc optional var artworks: NSArray { get }
}

/// 封面元素（sdef：`data` 类型 picture），通过 NSImage 读取。
/// `raw data` 返回 SBObject 包装，不能直接按 NSData 使用；本执行器
/// 只读取 data，不依赖 raw data 或 format。
@objc protocol SBMusicArtworkProtocol: NSObjectProtocol {
    @objc optional var data: NSImage { get }
}

@objc protocol SBMusicApplicationProtocol: NSObjectProtocol {
    @objc optional var playerState: Int { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func setPlayerPosition(_ seconds: Double)
    @objc optional var currentTrack: NSObject { get }
    // 注意：不声明裸 play 选择器——Music 词典的 play 命令带可选直接参数，
    // SB 使用 playOnce: 选择器，裸 play 不受支持，声明后会
    // 在 optional 链上静默空操作。play 改走 AppleScript
    // 兜底执行器，见下方 play() 注释。
    @objc optional func pause()
    @objc optional func playpause()
}

// MARK: - ScriptingBridge 执行器（主路径）

/// ScriptingBridge（SBApplication）执行器：进程内发送 Music Apple Events，
/// 无需为每次请求启动子进程。
///
/// 线程模型：SBApplication 非线程安全，调用方必须串行化访问
/// （控制器用专用执行锁约束）；本类型自身不再加锁。
/// 每个 SB 属性/命令调用经 ObjC 异常捕获包裹（Swift 无法捕获 ObjC 异常，
/// SB 事件失败可能以 NSException 抛出）。
public final class ScriptingBridgeExecutor: MusicScriptExecutor, MusicArtworkProviding, @unchecked Sendable {

    /// Music.app 的 bundle identifier（程序白名单：只允许此目标）。
    public static let musicBundleIdentifier = "com.apple.Music"

    /// SBApplication 非 Sendable，靠「调用方串行化」约定满足 @unchecked Sendable。
    private let application: SBApplication?

    /// SB 初始化失败时为 false：readSnapshot 返回 failed(unknown)，控制命令抛错。
    public var isAvailable: Bool { application != nil }

    /// 播放和切歌命令经公开 AppleScript 执行，避免 optional SB 调用静默跳过。
    /// 实例由本执行器独占，调用已由控制器的执行锁串行化；可注入验证命令分发。
    private let commandExecutor: MusicScriptExecutor

    /// - Parameter bundleIdentifier: 目标程序（默认 Music.app；测试可覆盖观察行为）。
    public init(
        bundleIdentifier: String = ScriptingBridgeExecutor.musicBundleIdentifier,
        commandExecutor: MusicScriptExecutor? = nil
    ) {
        // SBApplication(bundleIdentifier:) 只创建对象，不拉起目标应用。
        self.application = SBApplication(bundleIdentifier: bundleIdentifier)
        self.commandExecutor = commandExecutor ?? AppleScriptExecutor()
    }

    // MARK: MusicScriptExecutor

    public func readSnapshot() -> MusicSnapshotOutcome {
        guard let rawApp = application else {
            return .failed(.unknown("ScriptingBridge 初始化失败"))
        }

        // 1) 运行探测（isRunning 不发 Apple Event、不拉起 Music）。
        let running = guarded("isRunning") { rawApp.isRunning as NSObject? }
        switch running {
        case .failure(let failure):
            return .failed(failure)
        case .success(let value):
            guard (value as? Bool) == true else { return .musicNotRunning }
        }

        let app: SBMusicApplicationProtocol = reinterpreted(rawApp)

        // 2) 当前曲目（nil = 无曲目，属正常状态而非错误）。
        let trackObject = guarded("currentTrack") { app.currentTrack }
        switch trackObject {
        case .failure(let failure):
            return .failed(failure)
        case .success(nil):
            switch readStateCode(app) {
            case .failure(let failure):
                return .failed(failure)
            case .success(let stateCode):
                return .noCurrentTrack(stateCode: stateCode)
            }
        case .success(let object?):
            return readTrackSnapshot(app: app, trackObject: object)
        }
    }

    /// 运行前置检查（isRunning 不发 Apple Event、不拉起 Music）。
    private func ensureRunning() throws {
        guard let rawApp = application else {
            throw MusicScriptFailure.unknown("ScriptingBridge 初始化失败")
        }
        let running = guarded("isRunning") { rawApp.isRunning as NSObject? }
        switch running {
        case .failure(let failure):
            throw failure
        case .success(let value):
            guard (value as? Bool) == true else {
                throw MusicScriptFailure.musicNotRunning
            }
        }
    }

    public func play() throws {
        // SB 无裸 play 选择器（见协议处注释）：走 NSAppleScript 兜底执行器。
        try ensureRunning()
        do {
            try commandExecutor.play()
        } catch let failure as MusicScriptFailure {
            throw failure
        } catch {
            throw MusicScriptFailure.unknown("play 兜底执行失败: \(String(describing: error))")
        }
    }

    public func pause() throws {
        try sendCommand { app in
            app.pause?()
        }
    }

    public func nextTrack() throws {
        // 词典命令本身正确，但 optional 消息不提供执行确认；固定 AppleScript
        // 模板会检查运行状态，并把权限、超时等失败传回调用方。
        try commandExecutor.nextTrack()
    }

    public func previousTrack() throws {
        try commandExecutor.previousTrack()
    }

    public func seek(toSeconds seconds: Double) throws {
        try sendCommand { app in
            app.setPlayerPosition?(seconds)
        }
    }

    /// SB 侧不做 whose 查询（需要生成头文件，收益低）：点播统一走
    /// AppleScript 执行器（见 MusicScriptPlaybackController.playTrackRef）。
    public func playPersistentID(_ persistentID: String) throws {
        throw MusicScriptFailure.commandUnsupported("playPersistentID")
    }

    // MARK: - 封面（MusicArtworkProviding）

    /// 同批读取「persistent ID + 封面」：身份与图像之间任何一步失败或
    /// persistent ID 前后不一致（读取期间切歌）都返回 nil，不发布错配封面。
    /// 无封面（-1728）与无曲目属正常缺失，返回 nil 而非抛错。
    public func readCurrentTrackArtwork() -> MusicArtworkResult? {
        guard let rawApp = application else { return nil }
        // 运行前置检查（isRunning 不发 Apple Event、不拉起 Music）。
        let running = guarded("isRunning") { rawApp.isRunning as NSObject? }
        guard case .success(let runningValue) = running, (runningValue as? Bool) == true else {
            return nil
        }
        let app: SBMusicApplicationProtocol = reinterpreted(rawApp)
        let trackObject = guarded("currentTrack") { app.currentTrack }
        guard case .success(let trackValue?) = trackObject else { return nil }
        let track: SBMusicTrackProtocol = reinterpreted(trackValue)

        let firstID = guarded("persistentID") { track.persistentID as NSObject? }
        guard case .success(let firstIDValue) = firstID, let persistentID = firstIDValue as? String else {
            return nil
        }

        let artworks = guarded("artworks") { track.artworks }
        guard case .success(let artworksValue) = artworks,
              let artworkArray = artworksValue as? [NSObject], !artworkArray.isEmpty else {
            return nil
        }
        let artwork: SBMusicArtworkProtocol = reinterpreted(artworkArray[0])
        let imageOutcome = guarded("artworkData") { artwork.data }
        guard case .success(let imageValue) = imageOutcome, let image = imageValue as? NSImage else {
            return nil
        }

        // 同批身份校验（与快照同规则）：读图期间切歌 → 整批丢弃。
        let secondID = guarded("persistentID") { track.persistentID as NSObject? }
        guard case .success(let secondIDValue) = secondID, secondIDValue as? String == persistentID else {
            return nil
        }
        return MusicArtworkResult(persistentID: persistentID, image: image)
    }

    // MARK: - 私有

    /// 读取曲目字段并做同批身份一致性校验（persistent ID 前后各读一次）。
    private func readTrackSnapshot(
        app: SBMusicApplicationProtocol,
        trackObject: NSObject
    ) -> MusicSnapshotOutcome {
        let track: SBMusicTrackProtocol = reinterpreted(trackObject)

        let firstID = guarded("persistentID") { track.persistentID as NSObject? }
        if case .failure(let failure) = firstID { return .failed(failure) }
        guard let pid = firstID.value as? String else {
            return .failed(.fieldUnavailable("persistentID"))
        }

        let stateCode: Int?
        switch readStateCode(app) {
        case .failure(let failure):
            return .failed(failure)
        case .success(let code):
            stateCode = code
        }

        let position = guarded("playerPosition") { app.playerPosition as NSObject? }
        if case .failure(let failure) = position { return .failed(failure) }

        let fields = readTrackFields(track)

        // 同批身份校验：两次读取期间切歌 → 整批丢弃（不发布混合快照）。
        let secondID = guarded("persistentID") { track.persistentID as NSObject? }
        if case .failure(let failure) = secondID { return .failed(failure) }
        guard secondID.value as? String == pid else {
            return .identityChangedDuringRead
        }

        switch fields {
        case .failure(let failure):
            return .failed(failure)
        case .success(let value):
            return .snapshot(
                MusicScriptRawSnapshot(
                    playerStateCode: stateCode,
                    positionSeconds: position.value as? Double,
                    persistentID: pid,
                    title: value.title,
                    artist: value.artist,
                    album: value.album,
                    durationSeconds: value.duration
                )
            )
        }
    }

    /// 曲目静态字段批量读取（name/artist/album/duration；首个失败即返回）。
    private func readTrackFields(
        _ track: SBMusicTrackProtocol
    ) -> Result<TrackFields, MusicScriptFailure> {
        let title = guarded("name") { track.name as NSObject? }
        if case .failure(let failure) = title { return .failure(failure) }
        let artist = guarded("artist") { track.artist as NSObject? }
        if case .failure(let failure) = artist { return .failure(failure) }
        let album = guarded("album") { track.album as NSObject? }
        if case .failure(let failure) = album { return .failure(failure) }
        let duration = guarded("duration") { track.duration as NSObject? }
        if case .failure(let failure) = duration { return .failure(failure) }
        return .success(
            TrackFields(
                title: title.value as? String,
                artist: artist.value as? String,
                album: album.value as? String,
                duration: duration.value as? Double
            )
        )
    }

    private func readStateCode(
        _ app: SBMusicApplicationProtocol
    ) -> Result<Int?, MusicScriptFailure> {
        guarded("playerState") { app.playerState as NSObject? }.map { $0 as? Int }
    }

    /// 播放控制命令：先确认运行（不拉起 Music），再发送；异常经 guarded 分类。
    private func sendCommand(
        _ body: @escaping (SBMusicApplicationProtocol) -> Void
    ) throws {
        guard let rawApp = application else {
            throw MusicScriptFailure.unknown("ScriptingBridge 初始化失败")
        }
        let running = guarded("isRunning") { rawApp.isRunning as NSObject? }
        switch running {
        case .failure(let failure):
            throw failure
        case .success(let value):
            guard (value as? Bool) == true else {
                throw MusicScriptFailure.musicNotRunning
            }
        }
        let app: SBMusicApplicationProtocol = reinterpreted(rawApp)
        let outcome = guarded("command") {
            body(app)
            return nil
        }
        if case .failure(let failure) = outcome {
            throw failure
        }
    }

    /// Swift 动态转换到 @objc 协议会失败（SBApplication 未声明遵循）；消息派发
    /// 只需要对象指针，optional 成员在运行时经 respondsToSelector 解析，
    /// 按对象指针布局重解释为协议引用，实际调用仍由可选选择器检查保护。
    private func reinterpreted<T>(_ object: NSObject) -> T {
        unsafeBitCast(object, to: T.self)
    }

    /// ObjC 异常包裹：异常 → MusicScriptFailure；block 返回 nil（ObjC 侧
    /// 约定为 NSNull）属正常读取结果（如无当前曲目）。
    private func guarded(
        _ field: String,
        _ body: () -> NSObject?
    ) -> Result<NSObject?, MusicScriptFailure> {
        var objcError: NSError?
        let raw = ShinMSExceptionCatcher.catchException(body, error: &objcError)
        if let objcError {
            return .failure(MusicScriptErrorMapper.failure(from: objcError))
        }
        let value: NSObject? = (raw is NSNull) ? nil : (raw as? NSObject)
        if value == nil, field == "isRunning" {
            // isRunning 不应返回 nil；防御性归类为未知。
            return .failure(.unknown("isRunning 返回 nil"))
        }
        return .success(value)
    }
}

private extension Result {
    var value: Success? {
        switch self {
        case .success(let value): return value
        case .failure: return nil
        }
    }
}

/// 曲目静态字段（name/artist/album/duration）的读取结果载体。
private struct TrackFields {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
}
