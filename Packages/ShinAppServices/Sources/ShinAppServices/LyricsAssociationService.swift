import Foundation
import ShinAppleKit
import ShinAppleData

// 歌词关联查询服务：当前歌曲的绑定/文档查询、空态判定与解除关联。
// 只按明确的 CatalogIdentity 查询（trackKey 命名空间），不提供任何按歌名
// 匹配的入口——同名歌、Live、Remaster 永不自动共用歌词。

/// 当前歌曲歌词空态信息（UI 空态与正常态的唯一判定来源）。
public enum LyricsAssociationState: Equatable, Sendable {
    /// 无绑定：当前歌曲没有本地歌词（显示「导入歌词」入口）。
    case unbound
    /// 有绑定和文档，但全部行未打轴（startMs 均为 nil）：只能静态显示。
    case untimedOnly(document: LyricDocument)
    /// 正常：文档至少有一行已打轴，可参与后续的同步显示。
    case available(document: LyricDocument, binding: SongBinding)
}

/// 关联查询服务。无状态、线程安全；存储错误原样抛出
/// `ShinAppleDataError`（类型化、可判别，UI 层负责中文呈现）。
public struct LyricsAssociationService: Sendable {

    private let store: GRDBLyricsStore

    public init(store: GRDBLyricsStore) {
        self.store = store
    }

    /// 查询当前歌曲的关联状态（绑定 + 文档 + 空态判定，一次调用完成）。
    public func associationState(for track: CatalogIdentity) async throws -> LyricsAssociationState {
        try await associationState(forTrackKey: SongBinding.trackKey(for: track))
    }

    /// v2：按命名空间化 trackKey 查询（music-script:persistent:<id> 或
    /// 旧 apple-music:catalog: 键）。
    public func associationState(forTrackKey trackKey: String) async throws -> LyricsAssociationState {
        guard let binding = try await store.binding(forTrackKey: trackKey) else {
            return .unbound
        }
        // 防御：绑定指向的文档缺失视为未绑定（外键约束下不应发生）。
        guard let document = try await store.document(id: binding.lyricDocumentId) else {
            return .unbound
        }
        let hasTimedLine = document.lines.contains { $0.startMs != nil }
        if hasTimedLine {
            return .available(document: document, binding: binding)
        }
        return .untimedOnly(document: document)
    }

    /// 解除当前歌曲的关联；文档保留在库中。
    /// 绑定不存在时为幂等 no-op。
    public func deleteBinding(for track: CatalogIdentity) async throws {
        try await store.deleteBinding(for: track)
    }

    /// v2：按命名空间化 trackKey 解除关联；文档保留，幂等 no-op。
    public func deleteBinding(forTrackKey trackKey: String) async throws {
        try await store.deleteBinding(forTrackKey: trackKey)
    }
}
