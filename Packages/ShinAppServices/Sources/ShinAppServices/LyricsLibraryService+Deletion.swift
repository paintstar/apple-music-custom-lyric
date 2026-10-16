import Foundation
import ShinAppleKit
import ShinAppleData

public extension LyricsLibraryService {
    /// 删除已确认概览中的资源、行内译文及其关联。
    /// 在写事务中重验整个清单；版本或关联歌曲变化时整批拒绝，调用方刷新后重新确认。
    @discardableResult
    func deleteDocuments(_ items: [LyricsLibraryOverviewItem]) async throws -> [SongBinding] {
        do {
            return try await store.deleteDocumentsIfUnchanged(items.map { item in
                LyricsDocumentDeletionRequest(
                    documentId: item.documentId, revision: item.revision,
                    trackKeys: item.bindings.map(\.trackKey)
                )
            })
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }
}
