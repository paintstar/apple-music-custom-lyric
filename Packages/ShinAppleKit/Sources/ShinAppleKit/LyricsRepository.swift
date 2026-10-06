import Foundation

// domain/lyrics：歌词存储契约。
// 数据模型位于 Lyrics/LyricModels.swift；本文件定义仓库接口。
// 本地存储实现负责事务、原子写入和 revision 保护。

/// 歌词仓库契约。实现必须满足：
/// - 文档与绑定原子保存（不允许绑定成功而文档未落盘）；
/// - 读取不存在的数据返回 nil，而不是错误；
/// - 未知错误抛出 `LyricsRepositoryError`。
public protocol LyricsRepository: Sendable {
    /// 读取某目录歌曲当前绑定的歌词文档；无绑定或无文档返回 nil。
    func document(for track: CatalogIdentity) async throws -> LyricDocument?
    /// 读取某目录歌曲的绑定关系；无绑定时返回 nil。
    func binding(for track: CatalogIdentity) async throws -> SongBinding?
    /// 原子保存文档与绑定；导入默认不覆盖旧数据（由调用方先做冲突确认）。
    func save(document: LyricDocument, binding: SongBinding) async throws
    /// 解除某目录歌曲的绑定；不删除文档本身。
    func deleteBinding(for track: CatalogIdentity) async throws
}

/// 歌词仓库错误。
public enum LyricsRepositoryError: Error, Equatable, Sendable {
    /// 保存时检测到 revision 冲突（文档被并发修改）。
    case revisionConflict(documentId: UUID)
    /// 仓库不可用（I/O 失败、损坏等）。
    case storageUnavailable(String)
}
