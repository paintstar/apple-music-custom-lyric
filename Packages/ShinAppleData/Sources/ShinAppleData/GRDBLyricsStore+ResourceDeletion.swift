import Foundation
import GRDB
import ShinAppleKit

/// 用户确认删除时看到的文档版本及完整关联清单。
public struct LyricsDocumentDeletionRequest: Equatable, Sendable {
    public let documentId: UUID
    public let revision: Int
    public let trackKeys: [String]

    public init(documentId: UUID, revision: Int, trackKeys: [String]) {
        self.documentId = documentId
        self.revision = revision
        self.trackKeys = trackKeys
    }
}

public extension GRDBLyricsStore {
    /// 用户解除当前关联；最后一条关联解除后同步删除文档（含行内译文）。
    /// 已解绑为幂等 no-op；换绑或文档编辑拒绝旧请求，保护新内容。
    /// 返回 true 表示文档也已删除；false 表示仍有其他关联或已无当前关联。
    func deleteAssociation(
        forTrackKey trackKey: String, expectedDocumentId: UUID, expectedRevision: Int
    ) async throws -> Bool {
        try Self.validateDeletionRequest(LyricsDocumentDeletionRequest(
            documentId: expectedDocumentId, revision: expectedRevision, trackKeys: [trackKey]
        ))
        return try await performWrite { db in
            guard let binding = try SongBindingRow.fetchOne(db, key: trackKey) else { return false }
            guard binding.lyricDocumentId == expectedDocumentId.uuidString else {
                throw ShinAppleDataError.invalidBinding("歌曲关联已变化，未删除歌词。请刷新后重试。")
            }
            guard let document = try LyricDocumentRow.fetchOne(db, key: expectedDocumentId.uuidString) else {
                throw ShinAppleDataError.documentNotFound(expectedDocumentId)
            }
            try Self.validateDeletionRevision(document, expected: expectedRevision, documentId: expectedDocumentId)
            _ = try binding.delete(db)
            let hasOtherBindings = try SongBindingRow
                .filter(Column("lyricDocumentId") == expectedDocumentId.uuidString).fetchCount(db) > 0
            guard !hasOtherBindings else { return false }
            _ = try document.delete(db)
            return true
        }
    }

    /// 显式删除用户选中的本地资源；同事务重验每篇文档的版本和完整关联集合。
    /// 任一预览过期、输入非法或存储失败均整批回滚，不扩大用户确认的删除范围。
    func deleteDocumentsIfUnchanged(
        _ requests: [LyricsDocumentDeletionRequest]
    ) async throws -> [SongBinding] {
        guard !requests.isEmpty else { return [] }
        guard Set(requests.map(\.documentId)).count == requests.count else {
            throw ShinAppleDataError.invalidBinding("删除清单包含重复的歌词文档。")
        }
        for request in requests {
            try Self.validateDeletionRequest(request)
        }
        return try await performWrite { db in
            var affected: [SongBinding] = []
            for request in requests {
                guard let document = try LyricDocumentRow.fetchOne(db, key: request.documentId.uuidString) else {
                    throw ShinAppleDataError.documentNotFound(request.documentId)
                }
                try Self.validateDeletionRevision(document, expected: request.revision, documentId: request.documentId)
                let bindings = try SongBindingRow
                    .filter(Column("lyricDocumentId") == request.documentId.uuidString).fetchAll(db)
                guard Set(bindings.map(\.trackKey)) == Set(request.trackKeys) else {
                    throw ShinAppleDataError.invalidBinding("歌词的关联歌曲已变化，未删除资源。请刷新后重新确认。")
                }
                affected.append(contentsOf: try bindings.map { try $0.songBinding() })
                for binding in bindings {
                    _ = try binding.delete(db)
                }
                _ = try document.delete(db)
            }
            return affected.sorted { $0.trackKey < $1.trackKey }
        }
    }
}

private extension GRDBLyricsStore {
    static func validateDeletionRequest(_ request: LyricsDocumentDeletionRequest) throws {
        guard request.revision >= 1 else {
            throw ShinAppleDataError.invalidRevision(documentId: request.documentId, revision: request.revision)
        }
        guard Set(request.trackKeys).count == request.trackKeys.count,
              request.trackKeys.allSatisfy({ SongBinding.trackIdentity(fromTrackKey: $0) != nil }) else {
            throw ShinAppleDataError.invalidBinding("删除清单包含重复或非法的曲目标识。")
        }
    }

    static func validateDeletionRevision(
        _ document: LyricDocumentRow, expected: Int, documentId: UUID
    ) throws {
        guard document.revision == expected else {
            throw ShinAppleDataError.revisionConflict(
                documentId: documentId, storedRevision: document.revision, submittedRevision: expected
            )
        }
    }
}
