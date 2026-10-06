import Foundation
import GRDB
import ShinAppleKit

// 数据库 schema：显式迁移（DatabaseMigrator），GRDB 将已应用的迁移 id
// 记录在 grdbMigrations 表中（即版本记录）。每个迁移自身在事务中执行：
// 迁移失败时该迁移整体回滚，数据库停留在上一个已应用版本，旧数据可读、
// 可导出，作为迁移失败后的恢复来源。

/// v1 表结构。
enum Schema {
    /// 迁移器。每次返回新值（DatabaseMigrator 是值类型，register 是 mutating）。
    /// internal：供测试注入坏迁移验证回滚行为。
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1Schema(on: &migrator)
        registerV2TrackKeyNamespace(on: &migrator)
        registerV3DocumentSummary(on: &migrator)
        return migrator
    }

    /// 仅含 v1 的迁移器。internal：供测试构造真实 v1 库，
    /// 验证 v1→v2 升级路径（旧数据迁移不丢失）。
    static func v1Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1Schema(on: &migrator)
        return migrator
    }

    /// v1 + v2 的迁移器。internal：供测试构造真实 v2 库，
    /// 验证 v2→v3 摘要列回填（增删改查性能补强）。
    static func v2Migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1Schema(on: &migrator)
        registerV2TrackKeyNamespace(on: &migrator)
        return migrator
    }

    private static func registerV1Schema(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1.schema") { db in
            try db.create(table: "lyricDocument") { t in
                // UUID 字符串主键（LyricDocument.id）。
                t.primaryKey("id", .text).notNull()
                t.column("schemaVersion", .integer).notNull()
                t.column("revision", .integer).notNull()
                // 文档完整权威 JSON（Codable），读回时解码；查询列另存。
                t.column("payload", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "songBinding") { t in
                // 稳定曲目键：apple-music:catalog:<storefront>:<catalogSongId>。
                t.primaryKey("trackKey", .text).notNull()
                t.column("storefront", .text).notNull()
                t.column("catalogSongId", .text).notNull()
                // 外键 restrict：文档仍被绑定时不能删除，杜绝悬空引用。
                t.column("lyricDocumentId", .text).notNull()
                    .references("lyricDocument", onDelete: .restrict)
                t.column("userDelayMs", .integer).notNull()
                t.column("titleHint", .text)
                t.column("artistHint", .text)
                t.column("durationHintMs", .integer)
                t.column("updatedAt", .text).notNull()
            }
            // 按 lyricDocumentId 查"受影响绑定"（删除前确认）需要索引。
            try db.create(
                index: "songBinding.on.lyricDocumentId",
                on: "songBinding",
                columns: ["lyricDocumentId"]
            )
            // 最小键值设置表；备份只携带白名单键。
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }
        }
    }

    /// v3（增删改查性能补强）：lyricDocument 增加摘要列，
    /// 库总览不再解码每篇文档的完整 payload（全部歌词行）。
    /// 加列不重建表，迁移事务失败整体回滚；写路径（LyricDocumentRow）同步
    /// 维护这些列。回填对 payload 损坏的行按 0/nil 处理，不阻塞迁移——
    /// 该行在读取/导出时仍按既有语义抛 CorruptRowError，摘要不额外伪造。
    private static func registerV3DocumentSummary(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3.documentSummary") { db in
            try db.alter(table: "lyricDocument") { t in
                t.add(column: "lineCount", .integer).notNull().defaults(to: 0)
                t.add(column: "timedLineCount", .integer).notNull().defaults(to: 0)
                t.add(column: "sourceOffsetMs", .integer).notNull().defaults(to: 0)
                t.add(column: "titleHint", .text)
                t.add(column: "originalFilename", .text)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, payload FROM lyricDocument")
            for row in rows {
                let summary = summaryFields(fromPayload: row["payload"])
                try db.execute(
                    sql: """
                    UPDATE lyricDocument
                    SET lineCount = ?, timedLineCount = ?, sourceOffsetMs = ?, titleHint = ?, originalFilename = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        summary.lineCount, summary.timedLineCount, summary.sourceOffsetMs,
                        summary.titleHint, summary.originalFilename, row["id"]
                    ]
                )
            }
        }
    }

    /// 摘要回填的中间结果（仅迁移使用；正式读经 DocumentSummary）。
    private struct PayloadSummaryFields {
        var lineCount = 0
        var timedLineCount = 0
        var sourceOffsetMs: Int64 = 0
        var titleHint: String?
        var originalFilename: String?
    }

    /// 从 payload JSON 提取摘要字段（仅迁移回填使用；正式写路径经
    /// LyricDocumentRow 直接计算）。解码失败返回零值。
    private static func summaryFields(fromPayload payload: String) -> PayloadSummaryFields {
        var fields = PayloadSummaryFields()
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return fields
        }
        let lines = object["lines"] as? [[String: Any]] ?? []
        fields.lineCount = lines.count
        fields.timedLineCount = lines.filter { line in
            // startMs 为整数毫秒；JSON null（NSNull）与缺失都算未打轴。
            line["startMs"] is NSNumber
        }.count
        fields.sourceOffsetMs = (object["sourceOffsetMs"] as? NSNumber)?.int64Value ?? 0
        fields.titleHint = ((object["metadata"] as? [String: Any])?["ti"] as? [Any])?
            .compactMap { $0 as? String }.first
        fields.originalFilename = object["originalFilename"] as? String
        return fields
    }

    /// v2：曲目身份命名空间扩展。
    /// songBinding 表重建：storefront/catalogSongId 放开 NOT NULL，新增
    /// persistentId 列；每行恰好一种身份（目录 或 脚本 persistent ID）。
    /// SQLite 不能直接放开列约束，按「建新表 → 复制 → 换名」迁移；
    /// 该迁移在事务中执行，失败整体回滚，旧库保留在 v1 可读可导出。
    private static func registerV2TrackKeyNamespace(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2.trackKeyNamespace") { db in
            try db.create(table: "songBinding__v2") { t in
                // 稳定曲目键：apple-music:catalog:<storefront>:<id> 或
                // music-script:persistent:<persistentID>。
                t.primaryKey("trackKey", .text).notNull()
                t.column("storefront", .text)
                t.column("catalogSongId", .text)
                t.column("persistentId", .text)
                t.column("lyricDocumentId", .text).notNull()
                    .references("lyricDocument", onDelete: .restrict)
                t.column("userDelayMs", .integer).notNull()
                t.column("titleHint", .text)
                t.column("artistHint", .text)
                t.column("durationHintMs", .integer)
                t.column("updatedAt", .text).notNull()
                // 恰好一种身份：目录（storefront+catalogSongId）或脚本 persistentId。
                t.check(
                    sql: """
                    ((storefront IS NOT NULL AND catalogSongId IS NOT NULL AND persistentId IS NULL)
                      OR (storefront IS NULL AND catalogSongId IS NULL AND persistentId IS NOT NULL))
                    """
                )
            }
            try db.execute(sql: """
                INSERT INTO "songBinding__v2"
                    (trackKey, storefront, catalogSongId, persistentId, lyricDocumentId,
                     userDelayMs, titleHint, artistHint, durationHintMs, updatedAt)
                SELECT trackKey, storefront, catalogSongId, NULL, lyricDocumentId,
                       userDelayMs, titleHint, artistHint, durationHintMs, updatedAt
                FROM songBinding
                """)
            try db.drop(table: "songBinding")
            try db.rename(table: "songBinding__v2", to: "songBinding")
            try db.create(
                index: "songBinding.on.lyricDocumentId",
                on: "songBinding",
                columns: ["lyricDocumentId"]
            )
        }
    }
}

/// lyricDocument 行。payload 是文档的权威 JSON（sortedKeys 规范化）。
/// v3 摘要列（lineCount 等）由本构造器从文档直接计算维护，库总览读摘要
/// 不再解码 payload（增删改查性能补强）。
struct LyricDocumentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "lyricDocument"

    var id: String
    var schemaVersion: Int
    var revision: Int
    var payload: String
    var updatedAt: String
    // v3 摘要列（读取总览用；untimedLineCount = lineCount - timedLineCount）。
    var lineCount: Int
    var timedLineCount: Int
    var sourceOffsetMs: Int64
    var titleHint: String?
    var originalFilename: String?

    init(from document: LyricDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CorruptRowError(reason: "文档 payload 不是合法 UTF-8")
        }
        self.id = document.id.uuidString
        self.schemaVersion = document.schemaVersion
        self.revision = document.revision
        self.payload = json
        self.updatedAt = document.updatedAt
        self.lineCount = document.lines.count
        self.timedLineCount = document.lines.filter { $0.startMs != nil }.count
        self.sourceOffsetMs = document.sourceOffsetMs
        self.titleHint = document.metadata["ti"]?.first
        self.originalFilename = document.originalFilename
    }

    func decodeDocument() throws -> LyricDocument {
        guard let data = payload.data(using: .utf8) else {
            throw CorruptRowError(reason: "文档 payload 不是合法 UTF-8")
        }
        return try JSONDecoder().decode(LyricDocument.self, from: data)
    }

    var documentId: UUID? {
        UUID(uuidString: id)
    }
}

/// songBinding 行（schema v2：目录身份与脚本身份二选一，均按列存取）。
struct SongBindingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "songBinding"

    var trackKey: String
    /// v1 目录身份（历史绑定；脚本绑定为 nil）。
    var storefront: String?
    var catalogSongId: String?
    /// v2 Music 脚本 persistent ID（目录绑定为 nil）。
    var persistentId: String?
    var lyricDocumentId: String
    var userDelayMs: Int64
    var titleHint: String?
    var artistHint: String?
    var durationHintMs: Int64?
    var updatedAt: String

    init(from binding: SongBinding) {
        self.trackKey = binding.trackKey
        self.storefront = binding.track?.storefront
        self.catalogSongId = binding.track?.catalogSongId
        self.persistentId = binding.persistentID
        self.lyricDocumentId = binding.lyricDocumentId.uuidString
        self.userDelayMs = binding.userDelayMs
        self.titleHint = binding.titleHint
        self.artistHint = binding.artistHint
        self.durationHintMs = binding.durationHintMs
        self.updatedAt = binding.updatedAt
    }

    /// 还原为领域模型；行损坏时抛错（由上层包装为 storageUnavailable）。
    func songBinding() throws -> SongBinding {
        guard let documentId = UUID(uuidString: lyricDocumentId) else {
            throw CorruptRowError(reason: "songBinding.lyricDocumentId 不是合法 UUID：\(lyricDocumentId)")
        }
        // 恰好一种身份（CHECK 约束兜底；此处对读出的行再验证一次）。
        if let persistentId {
            guard storefront == nil, catalogSongId == nil else {
                throw CorruptRowError(reason: "songBinding 同时携带目录身份与 persistentId：\(trackKey)")
            }
            guard SongBinding.isValidPersistentID(persistentId) else {
                throw CorruptRowError(reason: "songBinding.persistentId 非法：\(trackKey)")
            }
            return SongBinding(
                persistentID: persistentId,
                lyricDocumentId: documentId,
                userDelayMs: userDelayMs,
                titleHint: titleHint,
                artistHint: artistHint,
                durationHintMs: durationHintMs,
                updatedAt: updatedAt
            )
        }
        guard let storefront, let catalogSongId else {
            throw CorruptRowError(reason: "songBinding 缺少目录身份与 persistentId：\(trackKey)")
        }
        let track = CatalogIdentity(storefront: storefront, catalogSongId: catalogSongId)
        return SongBinding(
            track: track,
            lyricDocumentId: documentId,
            userDelayMs: userDelayMs,
            titleHint: titleHint,
            artistHint: artistHint,
            durationHintMs: durationHintMs,
            updatedAt: updatedAt
        )
    }
}

/// settings 行（最小键值表）。
struct SettingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "settings"

    var key: String
    var value: String
}

/// 行损坏（库能打开但内容不可解码）。
struct CorruptRowError: Error, Sendable {
    let reason: String
}
