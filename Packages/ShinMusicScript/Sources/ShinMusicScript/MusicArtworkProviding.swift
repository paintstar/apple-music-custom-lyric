import AppKit
import Foundation

// MARK: - 封面提供接口

/// 一次封面读取的产出：曲目身份与图像同批返回。
/// 调用方以 `persistentID`（按 `SongBinding.trackKey(persistentID:)` 命名
/// 空间化后）校验时效——读取期间切歌则整批丢弃，不展示错配封面。
public struct MusicArtworkResult {
    /// 当前曲目的 persistent ID（词典：hexadecimal string）。
    public let persistentID: String
    /// 封面图像：ScriptingBridge 执行器通过 sdef picture 读取 NSImage。
    public let image: NSImage

    public init(persistentID: String, image: NSImage) {
        self.persistentID = persistentID
        self.image = image
    }
}

/// 封面提供契约（可选能力）：执行器实现它才具备封面读取。
/// NSAppleScript 兜底执行器不实现（二进制图像不经脚本文本通道搬运），
/// 无封面能力的适配器走 App 层「封面主色渐变占位」，不阻塞核心功能。
///
/// 线程模型与 MusicScriptExecutor 相同：调用方必须串行化访问
/// （生产由 MusicScriptPlaybackController 的执行锁约束）。
public protocol MusicArtworkProviding: AnyObject, Sendable {
    /// 读取当前曲目封面。Music 未运行 / 无曲目 / 无封面 / 读取失败 / 读取
    /// 期间身份变化一律返回 nil（未知与缺失不冒充占位图之外的东西）。
    func readCurrentTrackArtwork() -> MusicArtworkResult?
}
