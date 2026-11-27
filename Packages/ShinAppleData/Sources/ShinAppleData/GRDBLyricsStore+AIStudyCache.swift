import Foundation
import GRDB

public extension GRDBLyricsStore {
    /// 开始实际生成前读取库内代次。清空缓存后，旧请求的返回值只能用于当前预览。
    func aiStudyCacheGeneration() async throws -> UUID? {
        try await performRead { db in try AIStudyCacheGeneration.current(in: db) }
    }

    /// 只返回仍在有效期内、属于指定文档的完整缓存载荷。
    func aiStudyCachePayload(
        documentID: UUID, key: String, now: Date = .now
    ) async throws -> Data? {
        let cutoff = now.timeIntervalSince1970 - AIStudyCacheLimit.lifetime
        return try await performRead { db in
            try AIStudyCacheLimit.payload(in: db, documentID: documentID, key: key, cutoff: cutoff)
        }
    }

    /// 调用方先验证完整结果。尚未入库或已删除的文档跳过持久化。
    func saveAIStudyCachePayload(
        _ payload: Data, documentID: UUID, key: String, generation: UUID, now: Date = .now
    ) async throws {
        guard AIStudyCacheLimit.accepts(payload) else { return }
        let timestamp = now.timeIntervalSince1970
        try await performWrite { db in
            guard try AIStudyCacheGeneration.current(in: db) == generation else { return }
            try AIStudyCacheLimit.upsert(payload, in: db, documentID: documentID, key: key, timestamp: timestamp)
            try AIStudyCacheLimit.prune(in: db, timestamp: timestamp)
        }
    }

    /// 完整批次和候选行索引在同一事务合并。并发保存不同批次时，双方都基于最新索引更新。
    func saveAIStudyCacheBatch(
        _ payload: Data, documentID: UUID, keys: (batch: String, index: String), generation: UUID, now: Date = .now,
        updateIndex: @escaping @Sendable (Data?) -> Data?
    ) async throws {
        guard AIStudyCacheLimit.accepts(payload) else { return }
        let timestamp = now.timeIntervalSince1970
        let (key, indexKey) = keys
        try await performWrite { db in
            guard try AIStudyCacheGeneration.current(in: db) == generation else { return }
            let current = try AIStudyCacheLimit.payload(
                in: db, documentID: documentID, key: indexKey, cutoff: timestamp - AIStudyCacheLimit.lifetime
            )
            try AIStudyCacheLimit.upsert(payload, in: db, documentID: documentID, key: key, timestamp: timestamp)
            if let updated = updateIndex(current), AIStudyCacheLimit.accepts(updated) {
                try AIStudyCacheLimit.upsert(updated, in: db, documentID: documentID, key: indexKey, timestamp: timestamp)
            }
            try AIStudyCacheLimit.prune(in: db, timestamp: timestamp)
        }
    }

    func clearAIStudyCache() async throws {
        try await performWrite { db in
            try AIStudyCacheGeneration.clearCache(in: db)
        }
    }
}

enum AIStudyCacheGeneration {
    static func current(in db: Database) throws -> UUID? {
        try String.fetchOne(db, sql: "SELECT token FROM aiStudyCacheGeneration WHERE id = 1")
            .flatMap(UUID.init(uuidString:))
    }

    static func renew(in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO aiStudyCacheGeneration (id, token) VALUES (1, ?)
            ON CONFLICT (id) DO UPDATE SET token = excluded.token
            """, arguments: [UUID().uuidString])
    }

    static func clearCache(in db: Database) throws {
        try db.execute(sql: "DELETE FROM aiStudyCache")
        try renew(in: db)
    }
}

enum AIStudyCacheLimit {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Cache payload budget, excluding SQLite page and index overhead.
    static let bytes = 20 * 1_024 * 1_024

    static func accepts(_ payload: Data) -> Bool {
        !payload.isEmpty && payload.count <= bytes
    }

    static func payload(in db: Database, documentID: UUID, key: String, cutoff: TimeInterval) throws -> Data? {
        try Data.fetchOne(db, sql: """
            SELECT payload FROM aiStudyCache
            WHERE documentId = ? AND cacheKey = ? AND createdAt > ?
            """, arguments: [documentID.uuidString, key, cutoff])
    }

    static func upsert(_ data: Data, in db: Database, documentID: UUID, key: String, timestamp: TimeInterval) throws {
        try db.execute(sql: """
            INSERT INTO aiStudyCache (documentId, cacheKey, payload, createdAt)
            SELECT ?, ?, ?, ?
            WHERE EXISTS (SELECT 1 FROM lyricDocument WHERE id = ?)
            ON CONFLICT (documentId, cacheKey) DO UPDATE
            SET payload = excluded.payload, createdAt = excluded.createdAt
            """, arguments: [documentID.uuidString, key, data, timestamp, documentID.uuidString])
    }

    static func prune(in db: Database, timestamp: TimeInterval) throws {
        try deleteExpired(in: db, timestamp: timestamp)
        // 遇到相同时间戳时仍使用稳定顺序，保证并发写入下的上限和确定性。
        try db.execute(sql: """
            DELETE FROM aiStudyCache WHERE rowid IN (
                SELECT rowid FROM (
                    SELECT rowid, SUM(length(payload)) OVER (
                        ORDER BY createdAt DESC, rowid DESC
                        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                    ) AS retainedBytes
                    FROM aiStudyCache
                ) WHERE retainedBytes > ?
            )
            """, arguments: [bytes])
    }

    static func deleteExpired(in db: Database, timestamp: TimeInterval) throws {
        try db.execute(
            sql: "DELETE FROM aiStudyCache WHERE createdAt <= ?",
            arguments: [timestamp - lifetime]
        )
    }
}
