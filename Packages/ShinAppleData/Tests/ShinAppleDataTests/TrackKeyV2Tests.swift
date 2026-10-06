import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

// MARK: - trackKey v2
//
// 覆盖：v1→v2 真实迁移（旧目录绑定/文档完整保留）、v2 脚本绑定的
// 读写与备份往返、v1 备份文件导入兼容、v2 备份身份拒绝矩阵。
// 夹具全部原创虚构（测试曲目甲/乙、假十六进制 ID）。

/// v1 测试库夹具（避免 >2 成员的元组）。
struct V1DatabaseFixture {
    let path: String
    let document: LyricDocument
    let track: CatalogIdentity
}

@Suite("trackKey v2：迁移与命名空间")
struct TrackKeyV2Tests {

    static let pidA = "0A1B2C3D4E5F6071"
    static let pidB = "77665544332211FF"

    /// 用 v1 迁移器构造真实 v1 库并插入一条 v1 形状的目录绑定。
    private func makeV1Database(at directory: String) throws -> V1DatabaseFixture {
        let path = TestEnv.storePath(in: directory)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Schema.v1Migrator().migrate(pool)
        let document = Fixture.documentA()
        let track = Fixture.trackA
        let documentRow = try LyricDocumentRow(from: document)
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO lyricDocument (id, schemaVersion, revision, payload, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    documentRow.id, documentRow.schemaVersion, documentRow.revision,
                    documentRow.payload, documentRow.updatedAt
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO songBinding (trackKey, storefront, catalogSongId, lyricDocumentId,
                                         userDelayMs, titleHint, artistHint, durationHintMs, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    SongBinding.trackKey(for: track), track.storefront, track.catalogSongId,
                    document.id.uuidString, Int64(500), "测试曲目甲", "测试歌手乙",
                    Int64?(123_000), Fixture.fixedTimestamp
                ]
            )
        }
        return V1DatabaseFixture(path: path, document: document, track: track)
    }

    @Test("v1 库升级到 v2：旧目录绑定与文档完整保留，随后可写脚本绑定")
    func v1ToV2MigrationPreservesData() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let v1 = try makeV1Database(at: dir)

        // 用完整迁移器打开：v1.schema 已记录、v2.trackKeyNamespace 在此执行。
        let store = try GRDBLyricsStore(path: v1.path)

        // 旧目录绑定原样可读（「旧数据当作不可自动播放的历史资料保留」）。
        let binding = try await store.binding(for: v1.track)
        #expect(binding?.track == v1.track)
        #expect(binding?.persistentID == nil)
        #expect(binding?.userDelayMs == 500)
        #expect(binding?.titleHint == "测试曲目甲")
        let document = try await store.document(for: v1.track)
        #expect(document == v1.document)

        // 升级后的库可以写入 v2 脚本绑定（新旧命名空间并存）。
        let documentB = Fixture.textDocument()
        let scriptBinding = SongBinding(
            persistentID: Self.pidA,
            lyricDocumentId: documentB.id,
            userDelayMs: 0,
            titleHint: "测试曲目乙"
        )
        try await store.save(document: documentB, binding: scriptBinding)
        let readBack = try await store.binding(forTrackKey: scriptBinding.trackKey)
        #expect(readBack == scriptBinding)
        // 旧绑定不受影响。
        let oldBinding = try await store.binding(for: v1.track)
        #expect(oldBinding?.track == v1.track)
    }

    @Test("v2 脚本绑定：保存/按 trackKey 读取/userDelay 更新/按 trackKey 删除")
    func scriptBindingLifecycle() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let document = Fixture.documentA()
        let binding = SongBinding(
            persistentID: Self.pidA,
            lyricDocumentId: document.id,
            userDelayMs: 0,
            titleHint: "测试曲目甲",
            durationHintMs: 123_000
        )
        try await store.save(document: document, binding: binding)

        let readBack = try await store.binding(forTrackKey: binding.trackKey)
        #expect(readBack == binding)
        let documentForTrack = try await store.document(forTrackKey: binding.trackKey)
        #expect(documentForTrack == document)
        // 旧 CatalogIdentity 查询路径读不到脚本绑定（命名空间隔离）。
        let byCatalog = try await store.binding(for: Fixture.trackA)
        #expect(byCatalog == nil)

        var updated = binding
        updated.userDelayMs = 800
        try await store.updateBinding(updated)
        let updatedBinding = try await store.binding(forTrackKey: binding.trackKey)
        #expect(updatedBinding?.userDelayMs == 800)

        try await store.deleteBinding(forTrackKey: binding.trackKey)
        let deleted = try await store.binding(forTrackKey: binding.trackKey)
        #expect(deleted == nil)
        // 文档保留（解除关联不删文档）。
        let keptDocument = try await store.document(id: document.id)
        #expect(keptDocument != nil)
    }

    @Test("非法绑定：双重身份/键与 persistentID 不一致在写入时被拒绝")
    func invalidBindingsRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()

        // 双重身份：目录绑定被注入 persistentID（身份字段可变，构造非法形状）。
        var dual = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        dual.persistentID = "0000000000000001"
        await #expect(throws: ShinAppleDataError.self) {
            try await store.updateBinding(dual)
        }

        // 键与 persistentID 不一致（防篡改）。
        var mismatched = SongBinding(
            persistentID: Self.pidA,
            lyricDocumentId: document.id
        )
        mismatched.trackKey = SongBinding.trackKey(persistentID: Self.pidB)
        await #expect(throws: ShinAppleDataError.self) {
            try await store.save(document: Fixture.textDocument(), binding: mismatched)
        }
    }

    @Test("v2 备份往返：脚本绑定导出（track 缺省 + persistentId）→ 空库导入逐字段一致")
    func scriptBindingBackupRoundTrip() async throws {
        let dirA = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirA) }
        let dirB = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirB) }

        let storeA = try TestEnv.makeStore(dirA)
        let document = Fixture.documentA()
        let binding = SongBinding(
            persistentID: Self.pidA,
            lyricDocumentId: document.id,
            userDelayMs: -300,
            titleHint: "测试曲目甲"
        )
        try await storeA.save(document: document, binding: binding)

        let exportData = try await storeA.exportBackup(at: Fixture.fixedDate)
        let exported = try JSONDecoder().decode(BackupFile.self, from: exportData)
        #expect(exported.schemaVersion == BackupFile.currentSchemaVersion)
        #expect(exported.bindings.count == 1)
        #expect(exported.bindings[0].track == nil)
        #expect(exported.bindings[0].persistentId == Self.pidA)

        let storeB = try TestEnv.makeStore(dirB)
        let parsed = try storeB.parseBackup(exportData)
        try await storeB.importBackup(parsed)
        let importedBinding = try await storeB.binding(forTrackKey: binding.trackKey)
        #expect(importedBinding == binding)
    }

    @Test("v1 备份文件导入兼容：schemaVersion 1 + 纯目录身份绑定照常导入")
    func v1BackupImportCompatible() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let document = Fixture.documentA()
        let track = Fixture.trackA
        // 手工构造 v1 形状的备份 JSON（无 persistentId 键；行结构为 v1 语义）。
        let v1JSON = """
        {
          "schemaVersion": 1,
          "exportedAt": "\(Fixture.fixedTimestamp)",
          "documents": [{
            "schemaVersion": 1,
            "id": "\(document.id.uuidString)",
            "revision": \(document.revision),
            "sourceLanguage": "ja",
            "sourceFormat": "lrc",
            "sourceOffsetMs": 200,
            "originalText": "[00:01]第一句测试文本\\n",
            "originalFilename": "fixture-a.lrc",
            "metadata": {},
            "lines": [{"id": "\(UUID())", "startMs": 1000, "text": "第一句测试文本", "translations": {}}],
            "createdAt": "\(Fixture.fixedTimestamp)",
            "updatedAt": "\(Fixture.fixedTimestamp)"
          }],
          "bindings": [{
            "trackKey": "\(SongBinding.trackKey(for: track))",
            "track": {"storefront": "\(track.storefront)", "catalogSongId": "\(track.catalogSongId)"},
            "lyricDocumentId": "\(document.id.uuidString)",
            "userDelayMs": 500,
            "titleHint": "测试曲目甲",
            "artistHint": null,
            "durationHintMs": null,
            "updatedAt": "\(Fixture.fixedTimestamp)"
          }],
          "settings": {}
        }
        """
        let parsed = try store.parseBackup(Data(v1JSON.utf8))
        try await store.importBackup(parsed)
        let binding = try await store.binding(forTrackKey: SongBinding.trackKey(for: track))
        #expect(binding?.track == track)
        #expect(binding?.userDelayMs == 500)
    }

    @Test("v2 备份拒绝矩阵：双重身份/身份缺失/非法 persistentId/键不一致")
    func v2BackupRejectionMatrix() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)

        let documentId = UUID()

        // 双重身份 → wrongType。
        let dual = rejectionBackupData(documentId: documentId, binding: rejectionBindingJSON(
            documentId: documentId,
            trackJSON: "{\"storefront\": \"us\", \"catalogSongId\": \"9000001\"}",
            persistentId: Self.pidA,
            trackKey: SongBinding.trackKey(persistentID: Self.pidA)
        ))
        await expectBackupRejection(
            dual, from: store,
            equals: .wrongType(
                path: "root.bindings[0].persistentId",
                expected: "目录身份与 persistentId 不可同时存在（track=us/9000001）"
            ),
            librarySnapshot: before
        )

        // 身份缺失 → missingField。
        let missing = rejectionBackupData(documentId: documentId, binding: rejectionBindingJSON(
            documentId: documentId,
            trackKey: SongBinding.trackKey(persistentID: Self.pidA)
        ))
        await expectBackupRejection(
            missing, from: store,
            equals: .missingField(path: "root.bindings[0].track 或 root.bindings[0].persistentId"),
            librarySnapshot: before
        )

        // 非法 persistentId（非十六进制）→ wrongType。
        let invalidPID = rejectionBackupData(documentId: documentId, binding: rejectionBindingJSON(
            documentId: documentId,
            persistentId: "NOT-HEX",
            trackKey: SongBinding.trackKey(persistentID: "NOT-HEX")
        ))
        await expectBackupRejection(
            invalidPID, from: store,
            equals: .wrongType(
                path: "root.bindings[0].persistentId",
                expected: "1–64 位十六进制字符串"
            ),
            librarySnapshot: before
        )

        // 键与身份不一致 → trackKeyMismatch（防篡改）。
        let mismatched = rejectionBackupData(documentId: documentId, binding: rejectionBindingJSON(
            documentId: documentId,
            persistentId: Self.pidA,
            trackKey: SongBinding.trackKey(persistentID: Self.pidB)
        ))
        await expectBackupRejection(
            mismatched, from: store,
            equals: .trackKeyMismatch(
                path: "root.bindings[0].trackKey",
                declared: SongBinding.trackKey(persistentID: Self.pidB),
                expected: SongBinding.trackKey(persistentID: Self.pidA)
            ),
            librarySnapshot: before
        )
    }

    @Test("v1 迁移器可独立构造（v1→v2 升级路径的构造基础；回滚演练见 FaultDrillTests）")
    func v1MigratorConstructible() throws {
        _ = Schema.v1Migrator() // 构造成功即通过（防 API 回归）
    }
}

// MARK: - 拒绝矩阵夹具（文件级助手，保持测试函数在行数限值内）

/// 构造一份带单文档的 v2 备份字节。
private func rejectionBackupData(documentId: UUID, binding: String) -> Data {
    let updatedAt = Fixture.fixedTimestamp
    return Data("""
    {
      "schemaVersion": 2,
      "exportedAt": "\(updatedAt)",
      "documents": [\(rejectionDocumentJSON(documentId: documentId))],
      "bindings": [\(binding)],
      "settings": {}
    }
    """.utf8)
}

private func rejectionDocumentJSON(documentId: UUID) -> String {
    let updatedAt = Fixture.fixedTimestamp
    return """
    {
      "schemaVersion": 1,
      "id": "\(documentId)",
      "revision": 1,
      "sourceLanguage": "ja",
      "sourceFormat": "lrc",
      "sourceOffsetMs": 0,
      "originalText": "[00:01]第一句测试文本\\n",
      "originalFilename": "fixture-a.lrc",
      "metadata": {},
      "lines": [{"id": "\(UUID())", "startMs": 1000, "text": "第一句测试文本", "translations": {}}],
      "createdAt": "\(updatedAt)",
      "updatedAt": "\(updatedAt)"
    }
    """
}

private func rejectionBindingJSON(
    documentId: UUID,
    trackJSON: String? = nil,
    persistentId: String? = nil,
    trackKey: String
) -> String {
    let updatedAt = Fixture.fixedTimestamp
    var head = ""
    if let trackJSON {
        head += "\"track\": \(trackJSON),"
    }
    if let persistentId {
        head += "\"persistentId\": \"\(persistentId)\","
    }
    return """
    {\(head)"trackKey": "\(trackKey)",
    "lyricDocumentId": "\(documentId)",
    "userDelayMs": 0,
    "titleHint": null,
    "artistHint": null,
    "durationHintMs": null,
    "updatedAt": "\(updatedAt)"}
    """
}
