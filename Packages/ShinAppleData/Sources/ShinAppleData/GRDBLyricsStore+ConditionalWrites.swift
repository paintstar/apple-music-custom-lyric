import Foundation
import GRDB
import ShinAppleKit

public extension GRDBLyricsStore {
    /// 偏移命令只作用于装载时的现有绑定与文档版本；不创建或整行回写绑定。
    /// delay 字段不参与关联校验，连续合法命令可按调用顺序保存；文档 revision
    /// 与绑定的其余字段保持不变，人工编辑、换绑和解绑会拒绝过期命令。
    func updateBindingDelay(
        _ delayMs: Int64, expectedBinding: SongBinding, documentRevision: Int
    ) async throws {
        try Self.validateBindingShape(expectedBinding, referencedDocument: expectedBinding.lyricDocumentId)
        try await performWrite { db in
            let conflict = ShinAppleDataError.invalidBinding("歌曲或歌词关联已变化，偏移未保存。请刷新后重试。")
            guard let current = try SongBindingRow.fetchOne(db, key: expectedBinding.trackKey)
            else { throw conflict }
            var currentBinding = try current.songBinding()
            var expected = expectedBinding
            currentBinding.userDelayMs = 0
            expected.userDelayMs = 0
            guard currentBinding == expected else { throw conflict }
            guard let document = try LyricDocumentRow.fetchOne(db, key: expectedBinding.lyricDocumentId.uuidString)
            else { throw ShinAppleDataError.documentNotFound(expectedBinding.lyricDocumentId) }
            guard document.revision == documentRevision else {
                throw ShinAppleDataError.revisionConflict(
                    documentId: expectedBinding.lyricDocumentId,
                    storedRevision: document.revision, submittedRevision: documentRevision
                )
            }
            try db.execute(
                sql: "UPDATE songBinding SET userDelayMs = ? WHERE trackKey = ? AND lyricDocumentId = ?",
                arguments: [delayMs, expectedBinding.trackKey, expectedBinding.lyricDocumentId.uuidString]
            )
            guard db.changesCount == 1 else { throw conflict }
        }
    }

    /// 自动导入只接受事务内仍未绑定的曲目；既有人工或自动内容均不覆盖。
    func saveIfUnbound(
        document: LyricDocument, binding: SongBinding,
        isValid: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try await performSave(document: document, binding: binding, failurePoint: nil,
                              onlyIfUnbound: true, isValid: isValid)
    }

    /// 自动删除须在同一事务内重验绑定、revision 和调用方的人工保护规则。
    /// 共享文档不自动删除，避免连带移除其他曲目的绑定。
    func deleteDocumentIfUnchanged(
        binding: SongBinding, revision: Int,
        isValid: @escaping @Sendable () -> Bool,
        shouldDelete: @escaping @Sendable (LyricDocument) -> Bool
    ) async throws -> Bool {
        try await performWrite { db in
            guard isValid() else { throw CancellationError() }
            guard let currentBinding = try SongBindingRow.fetchOne(db, key: binding.trackKey),
                  try currentBinding.songBinding() == binding,
                  let row = try LyricDocumentRow.fetchOne(db, key: binding.lyricDocumentId.uuidString),
                  row.revision == revision, shouldDelete(try row.decodeDocument())
            else { return false }
            let affected = try SongBindingRow
                .filter(Column("lyricDocumentId") == binding.lyricDocumentId.uuidString).fetchAll(db)
            guard affected.count == 1 else { return false }
            _ = try currentBinding.delete(db)
            _ = try row.delete(db)
            guard isValid() else { throw CancellationError() }
            return true
        }
    }

    /// 成组设置原子写入；异步任务的有效性在实际写事务中重验。
    func setSettingValues(
        _ values: [String: String], isValid: @escaping @Sendable () -> Bool = { true }
    ) async throws {
        guard !values.keys.contains("") else { throw ShinAppleDataError.invalidSettingKey("设置键不能为空") }
        try await performWrite { db in
            guard isValid() else { throw CancellationError() }
            for (key, value) in values {
                var row = SettingRow(key: key, value: value)
                try row.save(db)
            }
            guard isValid() else { throw CancellationError() }
        }
    }

    /// 同一事务读取并修改设置；nil 值删除对应键，其他设置不受影响。
    /// 用于观察快照与待办一起推进，以及逐项确认，避免读改写丢失工作。
    func updateSettings(
        isValid: @escaping @Sendable () -> Bool = { true },
        changes: @escaping @Sendable ([String: String]) throws -> [String: String?]
    ) async throws {
        try await performWrite { db in
            guard isValid() else { throw CancellationError() }
            let current = Dictionary(uniqueKeysWithValues: try SettingRow.fetchAll(db).map { ($0.key, $0.value) })
            let updates = try changes(current)
            guard !updates.keys.contains("") else { throw ShinAppleDataError.invalidSettingKey("设置键不能为空") }
            for (key, value) in updates {
                if let value {
                    var row = SettingRow(key: key, value: value)
                    try row.save(db)
                } else {
                    _ = try SettingRow.deleteOne(db, key: key)
                }
            }
            guard isValid() else { throw CancellationError() }
        }
    }

    /// 保存位置复制前的写队列屏障；不改变任何数据。
    func waitForPendingWrites() async throws {
        try await performWrite { _ in }
    }
}

extension GRDBLyricsStore {
    func performWrite<T: Sendable>(
        _ body: @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await relocationSourcePool.write(body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ShinAppleDataError {
            throw error
        } catch {
            throw ShinAppleDataError.storageUnavailable(Self.describe(error))
        }
    }

}
