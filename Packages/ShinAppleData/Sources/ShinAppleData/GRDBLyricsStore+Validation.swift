import Foundation
import ShinAppleKit

// MARK: - 写入前校验（自 GRDBLyricsStore 拆出，约束文件/类型长度）
//
// 纯静态校验：文档 schema/revision 与绑定身份形状（v2 双命名空间）。
// internal：供 GRDBLyricsStore 与测试直接调用。

extension GRDBLyricsStore {

    static func validateDocumentForWrite(_ document: LyricDocument) throws {
        let issues = LyricSchemaValidator.issues(in: document)
        guard issues.isEmpty else {
            throw ShinAppleDataError.invalidDocument(issues)
        }
        guard document.revision >= 1 else {
            throw ShinAppleDataError.invalidRevision(
                documentId: document.id, revision: document.revision
            )
        }
    }

    static func validateBindingShape(
        _ binding: SongBinding,
        referencedDocument: UUID
    ) throws {
        // v2：目录身份与脚本身份二选一，trackKey 必须与身份推导值一致。
        if let persistentID = binding.persistentID {
            try validateScriptIdentity(binding, persistentID: persistentID)
        } else if let track = binding.track {
            try validateCatalogIdentity(binding, track: track)
        } else {
            throw ShinAppleDataError.invalidBinding(
                "绑定缺少曲目身份（目录或 persistentID 二者必有其一）"
            )
        }
        guard binding.lyricDocumentId == referencedDocument else {
            throw ShinAppleDataError.invalidBinding(
                "绑定指向的文档与保存的文档不一致"
            )
        }
    }

    private static func validateScriptIdentity(
        _ binding: SongBinding,
        persistentID: String
    ) throws {
        guard binding.track == nil else {
            throw ShinAppleDataError.invalidBinding(
                "绑定同时携带目录身份与 persistentID（二选一）：\(binding.trackKey)"
            )
        }
        guard SongBinding.isValidPersistentID(persistentID) else {
            throw ShinAppleDataError.invalidBinding(
                "persistentID 非法（须为 1–64 位十六进制）：\(binding.trackKey)"
            )
        }
        let expectedKey = SongBinding.trackKey(persistentID: persistentID)
        guard binding.trackKey == expectedKey else {
            throw ShinAppleDataError.invalidBinding(
                "trackKey 与 persistentID 不一致：\(binding.trackKey) ≠ \(expectedKey)"
            )
        }
    }

    private static func validateCatalogIdentity(
        _ binding: SongBinding,
        track: CatalogIdentity
    ) throws {
        guard !track.storefront.isEmpty, !track.catalogSongId.isEmpty else {
            throw ShinAppleDataError.invalidBinding("storefront/catalogSongId 不能为空")
        }
        let expectedKey = SongBinding.trackKey(for: track)
        guard binding.trackKey == expectedKey else {
            throw ShinAppleDataError.invalidBinding(
                "trackKey 与 track 身份不一致：\(binding.trackKey) ≠ \(expectedKey)"
            )
        }
    }
}
