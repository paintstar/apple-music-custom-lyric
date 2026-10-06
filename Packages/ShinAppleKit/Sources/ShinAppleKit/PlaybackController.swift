// domain/music：播放控制器契约。
// 项目契约，非 SDK 方法清单。实现方（MockPlaybackController、
// ShinMusicScript 的 MusicScriptPlaybackController）负责把各自的
// 官方能力映射到这些方法；接口形态与任何 SDK 的同名方法无关。

/// 订阅句柄：必须可取消；取消后不再收到任何通知。
/// 界面挂载/卸载、切歌、关闭页面都必须清理句柄。
public protocol PlaybackSubscriptionHandle: AnyObject, Sendable {
    func cancel()
}

/// 播放控制器契约。
///
/// - `snapshot()` 是同步读取的权威状态。
/// - `subscribe` 返回可取消句柄；重复订阅互不影响；`dispose()` 后全部失效。
/// - 所有命令（play/pause/…）只表示“请求”，不得立即冒充 SDK 已成功；
///   结果以随后的快照通知为准。
/// - 目录身份队列（`setQueue`）保留用于 Mock；脚本适配器不把目录 ID
///   当作本机 persistent ID，明确返回不支持。真实点播使用 `playTrackRef`。
/// - 继承 Sendable：实现方须保证跨隔离访问安全
///   （现有两实现均为 @unchecked Sendable，串行使用约定见各自类型注释）；
///   UI 层在 @MainActor 上通过非隔离异步方法调用接收方时不需要跨隔离发送。
public protocol PlaybackController: AnyObject, Sendable {
    /// 当前播放快照。
    func snapshot() -> PlaybackSnapshot

    /// 订阅快照变化。返回可取消句柄。
    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle

    /// 设置播放队列并从 `startAt` 对应项目开始装载（nil 表示从头开始）。
    /// 项目契约，非 SDK 方法清单。
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws

    func play() async throws
    func pause() async throws

    /// 跳转到指定位置（整数毫秒）。越界值由实现裁剪到合法时长范围。
    func seek(positionMs: Int64) async throws

    func next() async throws
    func previous() async throws

    /// 释放全部监听与内部任务；调用后控制器不再发出任何通知。
    func dispose()

    /// 通过项目内 trackRef 点播歌曲：
    /// （`music-script:persistent:<persistentID>`）在音乐库定位曲目并从其
    /// 开始播放。这是「从学习列表点播」的预留能力；默认实现如实抛
    /// trackUnavailable（不具备该能力的适配器不假装成功）。
    /// 命令发出不冒充成功，结果以随后的快照为准。
    func playTrackRef(_ trackRef: String) async throws
}

/// playTrackRef 的默认实现（无点播能力的适配器自动获得）。
public extension PlaybackController {
    func playTrackRef(_ trackRef: String) async throws {
        throw PlaybackError.trackUnavailable
    }
}
