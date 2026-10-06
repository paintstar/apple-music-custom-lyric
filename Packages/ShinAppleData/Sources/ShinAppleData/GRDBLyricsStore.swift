import Foundation
import GRDB
import ShinAppleKit

// GRDB/SQLite 实现的歌词仓库。
// 关键保证：
// - 文档与绑定在同一事务写入；任何一步失败整体回滚，"绑定成功但文档
//   未落盘"的半成品状态不可能出现（外键 restrict 另加一层防护）；
// - revision 乐观并发：更新要求 submittedRevision == storedRevision + 1，
//   过期提交抛类型化冲突错误，绝不静默覆盖；
// - 时间同步与本包零耦合：包内没有任何定时器/监听器/播放依赖，
//   播放侧调用读取接口不会触发写入。
//
// 注入失败点（SaveFailurePoint）仅供测试通过 internal 通道使用，
// 不出现在公开 API 中。

public final class GRDBLyricsStore: LyricsRepository, Sendable {

    /// 备份导出/导入使用的配置（限制与设置白名单）。
    public let backupConfiguration: BackupConfiguration

    private let pool: DatabasePool

    /// 打开（必要时创建）数据库并执行显式迁移。
    /// 打开/迁移失败映射为 storageUnavailable，绝不假装成功，
    /// 也绝不删除或重建库文件（消息内嵌路径，供 UI 给出备份指引；
    /// 升级前备份等打开安全路径见 `GRDBLyricsStore+OpenSafety.swift`）。
    public convenience init(
        path: String,
        backupConfiguration: BackupConfiguration = .standard
    ) throws {
        var configuration = Configuration()
        // 外键约束：绑定必须指向存在的文档，删除被引用文档被 SQLite 拒绝。
        configuration.foreignKeysEnabled = true
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: configuration)
        } catch {
            throw ShinAppleDataError.storageUnavailable(
                Self.openFailureMessage(path: path, detail: Self.describe(error))
            )
        }
        do {
            try Schema.migrator().migrate(pool)
        } catch {
            // 迁移失败时该迁移事务整体回滚，旧库保留在上一版本；
            // 这里只上报类型化错误，不做任何删除/重建（由用户决定如何处置）。
            throw ShinAppleDataError.storageUnavailable(
                Self.migrationFailureMessage(path: path, detail: Self.describe(error))
            )
        }
        self.init(ownedPool: pool, backupConfiguration: backupConfiguration)
    }

    init(ownedPool: DatabasePool, backupConfiguration: BackupConfiguration) {
        self.pool = ownedPool
        self.backupConfiguration = backupConfiguration
    }

    /// 保存位置切换的搬移扩展使用的底层连接池。
    /// 见 GRDBLyricsStore+Relocation.swift。
    var relocationSourcePool: DatabasePool { pool }

    // MARK: - LyricsRepository 契约

    public func document(for track: CatalogIdentity) async throws -> LyricDocument? {
        try await document(forTrackKey: SongBinding.trackKey(for: track))
    }

    /// v2：按命名空间化 trackKey 读取绑定指向的文档。
    public func document(forTrackKey trackKey: String) async throws -> LyricDocument? {
        try await performRead { db in
            guard let bindingRow = try SongBindingRow.fetchOne(db, key: trackKey) else { return nil }
            guard let documentRow = try LyricDocumentRow.fetchOne(db, key: bindingRow.lyricDocumentId) else {
                return nil
            }
            return try documentRow.decodeDocument()
        }
    }

    public func binding(for track: CatalogIdentity) async throws -> SongBinding? {
        try await binding(forTrackKey: SongBinding.trackKey(for: track))
    }

    /// v2：按命名空间化 trackKey 读取绑定（music-script:persistent:<id> 或
    /// 旧 apple-music:catalog: 键）。
    public func binding(forTrackKey trackKey: String) async throws -> SongBinding? {
        try await performRead { db in
            guard let row = try SongBindingRow.fetchOne(db, key: trackKey) else { return nil }
            return try row.songBinding()
        }
    }

    /// 原子保存文档与绑定。
    /// - 新文档：接受任意 revision >= 1（导入恢复的文档可能已有高 revision）。
    /// - 已存在文档：必须提交 storedRevision + 1，否则抛 revisionConflict。
    /// - 绑定必须指向本文档；同一曲目已有绑定时被替换（调用方先用
    ///   reimportPreview 做确认，导入默认不覆盖旧数据）。
    public func save(document: LyricDocument, binding: SongBinding) async throws {
        _ = try await performSave(document: document, binding: binding, failurePoint: nil)
    }

    /// 解除某曲目的绑定；不删除文档。绑定不存在时为幂等 no-op。
    public func deleteBinding(for track: CatalogIdentity) async throws {
        try await deleteBinding(forTrackKey: SongBinding.trackKey(for: track))
    }

    /// v2：按命名空间化 trackKey 解除绑定；不删除文档。幂等 no-op。
    public func deleteBinding(forTrackKey trackKey: String) async throws {
        try await performWrite { db in
            _ = try SongBindingRow.deleteOne(db, key: trackKey)
        }
    }

    // MARK: - 导入、编辑与备份 API

    /// 按 id 读取文档；不存在返回 nil。
    public func document(id: UUID) async throws -> LyricDocument? {
        try await performRead { db in
            guard let row = try LyricDocumentRow.fetchOne(db, key: id.uuidString) else { return nil }
            return try row.decodeDocument()
        }
    }

    /// 列出全部文档（按 id 排序，输出确定）。
    public func allDocuments() async throws -> [LyricDocument] {
        try await performRead { db in
            let rows = try LyricDocumentRow.fetchAll(db)
            return try rows
                .sorted { $0.id < $1.id }
                .map { try $0.decodeDocument() }
        }
    }

    /// 列出全部绑定（按 trackKey 排序，输出确定）。
    public func allBindings() async throws -> [SongBinding] {
        try await performRead { db in
            let rows = try SongBindingRow.fetchAll(db)
            return try rows
                .sorted { $0.trackKey < $1.trackKey }
                .map { try $0.songBinding() }
        }
    }

    /// 列出全部文档摘要（按 id 排序，输出确定；只读摘要列，不解码 payload）。
    /// 这是库总览页的数据源；打开/编辑/导出仍走 document(id:) 全量解码。
    public func allDocumentSummaries() async throws -> [DocumentSummary] {
        try await performRead { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, revision, updatedAt, lineCount, timedLineCount,
                       sourceOffsetMs, titleHint, originalFilename
                FROM lyricDocument
                """
            )
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return DocumentSummary(
                    id: id,
                    revision: row["revision"],
                    updatedAt: row["updatedAt"],
                    lineCount: row["lineCount"],
                    timedLineCount: row["timedLineCount"],
                    sourceOffsetMs: row["sourceOffsetMs"],
                    titleHint: row["titleHint"],
                    originalFilename: row["originalFilename"]
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// 引用某文档的全部绑定（删除共享文档前的"受影响绑定"确认接口）。
    public func bindings(referencing documentId: UUID) async throws -> [SongBinding] {
        try await performRead { db in
            let rows = try SongBindingRow
                .filter(Column("lyricDocumentId") == documentId.uuidString)
                .fetchAll(db)
            return try rows
                .sorted { $0.trackKey < $1.trackKey }
                .map { try $0.songBinding() }
        }
    }

    /// 更新/新建单条绑定（如调整 userDelayMs、重新关联），不改动文档 revision。
    /// 绑定必须指向已存在的文档。
    public func updateBinding(_ binding: SongBinding) async throws {
        try Self.validateBindingShape(binding, referencedDocument: binding.lyricDocumentId)
        try await performWrite { db in
            guard try LyricDocumentRow.fetchOne(db, key: binding.lyricDocumentId.uuidString) != nil else {
                throw ShinAppleDataError.documentNotFound(binding.lyricDocumentId)
            }
            var bindingRow = SongBindingRow(from: binding)
            try bindingRow.save(db)
        }
    }

    /// 删除文档。仍被绑定时：
    /// - deletingAffectedBindings == false：抛 documentInUse（调用方先列出
    ///   bindings(referencing:) 供用户确认）；
    /// - deletingAffectedBindings == true：同一事务先删绑定再删文档。
    /// 外键 restrict 保证任何路径都不产生悬空绑定。
    public func deleteDocument(
        id: UUID,
        deletingAffectedBindings: Bool
    ) async throws {
        try await performWrite { db in
            let affected = try SongBindingRow
                .filter(Column("lyricDocumentId") == id.uuidString)
                .fetchAll(db)
            if !affected.isEmpty && !deletingAffectedBindings {
                throw ShinAppleDataError.documentInUse(
                    documentId: id, affectedBindingCount: affected.count
                )
            }
            for row in affected {
                try row.delete(db)
            }
            let deleted = try LyricDocumentRow.deleteOne(db, key: id.uuidString)
            guard deleted else {
                throw ShinAppleDataError.documentNotFound(id)
            }
        }
    }

    // MARK: - 设置（最小键值）

    public func settingValue(forKey key: String) async throws -> String? {
        try await performRead { db in
            try SettingRow.fetchOne(db, key: key)?.value
        }
    }

    public func setSettingValue(_ value: String, forKey key: String) async throws {
        guard !key.isEmpty else {
            throw ShinAppleDataError.invalidSettingKey("设置键不能为空")
        }
        try await performWrite { db in
            var settingRow = SettingRow(key: key, value: value)
                try settingRow.save(db)
        }
    }

    public func removeSetting(forKey key: String) async throws {
        try await performWrite { db in
            _ = try SettingRow.deleteOne(db, key: key)
        }
    }

    public func allSettings() async throws -> [String: String] {
        try await performRead { db in
            let rows = try SettingRow.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
        }
    }

    // MARK: - 备份

    /// 导出完整备份（权威无损出口）。同一 Date 参数下输出字节确定
    /// （sortedKeys + 确定性排序），便于 diff 与测试。
    public func exportBackup(at date: Date = Date()) async throws -> Data {
        let snapshot = try await currentSnapshot()
        let documents = snapshot.documents.values
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let bindings = snapshot.bindings.values
            .sorted { $0.trackKey < $1.trackKey }
            .map { BackupBinding(from: $0) }
        let settings = snapshot.settings
            .filter { backupConfiguration.settingAllowlist.contains($0.key) }
        let file = BackupFile(
            exportedAt: LyricTimestamp.string(from: date),
            documents: Array(documents),
            bindings: bindings,
            settings: settings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    /// 当前库的纯值快照（冲突预览的输入）。
    public func currentSnapshot() async throws -> BackupStoreSnapshot {
        try await performRead { db in
            var documents: [UUID: LyricDocument] = [:]
            for row in try LyricDocumentRow.fetchAll(db) {
                guard let id = row.documentId else {
                    throw CorruptRowError(reason: "lyricDocument.id 不是合法 UUID：\(row.id)")
                }
                documents[id] = try row.decodeDocument()
            }
            var bindings: [String: SongBinding] = [:]
            for row in try SongBindingRow.fetchAll(db) {
                bindings[row.trackKey] = try row.songBinding()
            }
            let settings = try SettingRow.fetchAll(db)
            return BackupStoreSnapshot(
                documents: documents,
                bindings: bindings,
                settings: Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.value) })
            )
        }
    }

    /// 解析备份字节（不写库）。抛 invalidBackup（类型化拒绝原因）。
    public func parseBackup(
        _ data: Data,
        configuration: BackupConfiguration? = nil
    ) throws -> BackupParseResult {
        try BackupParser.parse(data, configuration: configuration ?? backupConfiguration)
    }

    /// 冲突预览：读取当前快照 + 纯函数计算。
    public func backupConflictPreview(
        for parsed: BackupParseResult
    ) async throws -> BackupConflictPreview {
        let snapshot = try await currentSnapshot()
        return BackupPlanner.conflictPreview(parsed: parsed, currentState: snapshot)
    }

    /// 重新导入同一首歌的预览（确认界面数据源）。
    public func reimportPreview(
        incomingDocument: LyricDocument,
        binding: SongBinding
    ) async throws -> ReimportPreview {
        try Self.validateBindingShape(binding, referencedDocument: incomingDocument.id)
        let trackKey = binding.trackKey
        return try await performRead { db in
            let currentRow = try SongBindingRow.fetchOne(db, key: trackKey)
            let currentBinding = try currentRow?.songBinding()
            var replacedDocument: LyricDocument?
            var otherBindings: [SongBinding] = []
            if let current = currentBinding {
                let oldId = current.lyricDocumentId.uuidString
                replacedDocument = try LyricDocumentRow.fetchOne(db, key: oldId)?.decodeDocument()
                let rows = try SongBindingRow
                    .filter(Column("lyricDocumentId") == oldId)
                    .fetchAll(db)
                otherBindings = try rows
                    .filter { $0.trackKey != trackKey }
                    .map { try $0.songBinding() }
            }
            return BackupPlanner.reimportPreview(
                incomingDocument: incomingDocument,
                incomingBinding: binding,
                currentBinding: currentBinding,
                replacedDocument: replacedDocument,
                otherBindingsForReplacedDocument: otherBindings
            )
        }
    }

    /// 用户确认后单事务提交。提交前对每个文档做防御性 schema 校验；
    /// 绑定直接按备份内容 upsert（备份对同 id 文档/同键绑定是权威替换，
    /// 预览已展示将替换的内容）。备份中不存在的本地数据不受影响。
    public func importBackup(_ parsed: BackupParseResult) async throws {
        for document in parsed.file.documents {
            let issues = LyricSchemaValidator.issues(in: document)
            guard issues.isEmpty else {
                throw ShinAppleDataError.invalidDocument(issues)
            }
        }
        let documents = parsed.file.documents
        let bindings = parsed.file.bindings.map { $0.songBinding }
        let settings = parsed.file.settings.sorted(by: { $0.key < $1.key })
        try await performWrite { db in
            for document in documents {
                var documentRow = try LyricDocumentRow(from: document)
                try documentRow.save(db)
            }
            for binding in bindings {
                guard try LyricDocumentRow.fetchOne(db, key: binding.lyricDocumentId.uuidString) != nil else {
                    // 防御：手工构造的 ParseResult 绕过了导入前校验。
                    throw ShinAppleDataError.invalidBackup(
                        .danglingBinding(documentId: binding.lyricDocumentId)
                    )
                }
                var bindingRow = SongBindingRow(from: binding)
                try bindingRow.save(db)
            }
            for (key, value) in settings {
                var settingRow = SettingRow(key: key, value: value)
                try settingRow.save(db)
            }
        }
    }

    // MARK: - 保存核心（事务 + 失败注入点）

    func performSave(
        document: LyricDocument,
        binding: SongBinding,
        failurePoint: SaveFailurePoint?,
        onlyIfUnbound: Bool = false,
        isValid: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Bool {
        try Self.validateDocumentForWrite(document)
        try Self.validateBindingShape(binding, referencedDocument: document.id)
        return try await performWrite { db in
            guard isValid() else { throw CancellationError() }
            if onlyIfUnbound, try SongBindingRow.fetchOne(db, key: binding.trackKey) != nil { return false }
            let key = document.id.uuidString
            let existing = try LyricDocumentRow.fetchOne(db, key: key)
            if let existing = existing {
                // 乐观并发：过期 revision 提交必须失败，绝不静默覆盖。
                guard document.revision == existing.revision + 1 else {
                    throw ShinAppleDataError.revisionConflict(
                        documentId: document.id,
                        storedRevision: existing.revision,
                        submittedRevision: document.revision
                    )
                }
            }
            var documentRow = try LyricDocumentRow(from: document)
            try documentRow.save(db)
            if failurePoint == .afterDocumentWrite {
                throw ShinAppleDataError.storageUnavailable("注入失败点：文档写入后、绑定写入前")
            }
            var bindingRow = SongBindingRow(from: binding)
            try bindingRow.save(db)
            if failurePoint == .afterBindingWrite {
                throw ShinAppleDataError.storageUnavailable("注入失败点：绑定写入后（验证回滚）")
            }
            guard isValid() else { throw CancellationError() }
            return true
        }
    }

    // 校验函数移至 GRDBLyricsStore+Validation.swift（文件/类型长度约束）。

    // MARK: - 错误包装

    private func performRead<T: Sendable>(
        _ body: @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await pool.read(body)
        } catch let error as ShinAppleDataError {
            throw error
        } catch {
            throw ShinAppleDataError.storageUnavailable(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        "\(String(describing: type(of: error))): \(error.localizedDescription)"
    }
}

// MARK: - 文档级写入通道

public extension GRDBLyricsStore {

    /// 文档级写入通道：更新已存在的文档，不要求、也不改动任何绑定
    /// 无绑定文档也能保存，配合歌词库管理与 LRC 导出。
    /// - 文档必须已存在（新建文档走 `save(document:binding:)` 或备份导入），
    ///   不存在抛 documentNotFound；
    /// - revision 乐观并发与 `save` 同规则：提交必须是 storedRevision + 1，
    ///   过期提交抛 revisionConflict，绝不静默覆盖；
    /// - 单事务只写文档一行；绑定的 userDelayMs 等字段不受影响。
    func updateDocument(_ document: LyricDocument) async throws {
        try Self.validateDocumentForWrite(document)
        try await performWrite { db in
            let key = document.id.uuidString
            guard let existing = try LyricDocumentRow.fetchOne(db, key: key) else {
                throw ShinAppleDataError.documentNotFound(document.id)
            }
            guard document.revision == existing.revision + 1 else {
                throw ShinAppleDataError.revisionConflict(
                    documentId: document.id,
                    storedRevision: existing.revision,
                    submittedRevision: document.revision
                )
            }
            var documentRow = try LyricDocumentRow(from: document)
            try documentRow.save(db)
        }
    }
}

/// 文档摘要（v3 摘要列；库总览不解码 payload 全文）。
public struct DocumentSummary: Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let updatedAt: String
    public let lineCount: Int
    public let timedLineCount: Int
    public var untimedLineCount: Int { lineCount - timedLineCount }
    public let sourceOffsetMs: Int64
    public let titleHint: String?
    public let originalFilename: String?
}
