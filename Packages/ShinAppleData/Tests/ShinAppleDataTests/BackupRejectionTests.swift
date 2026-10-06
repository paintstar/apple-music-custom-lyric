import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 非法备份的拒绝矩阵（1/2）：schema、结构、身份与语义类拒绝。
// 每个用例都断言"原库快照前后相等"——拒绝绝不触碰已有数据。

@Suite("备份拒绝矩阵：结构与语义")
struct BackupRejectionTests {

    @Test("未来 schemaVersion：拒绝且原库不变")
    func futureBackupVersionRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        // v2起同时接受 v1 与 v2；「未来版本」= current + 1。
        let futureVersion = BackupFile.currentSchemaVersion + 1
        let data = try await patchExport(store) { root in
            root["schemaVersion"] = futureVersion
        }
        await expectBackupRejection(
            data, from: store,
            equals: .unsupportedSchemaVersion(found: futureVersion),
            librarySnapshot: before
        )
    }

    @Test("文档级未来 schemaVersion：由 LyricSchemaValidator 拒绝")
    func futureDocumentVersionRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let data = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if !documents.isEmpty {
                documents[0]["schemaVersion"] = 2
            }
            root["documents"] = documents
        }
        guard case let .schemaIssues(issues) = firstBackupRejection(data, store) else {
            Issue.record("期望 schemaIssues")
            return
        }
        #expect(issues.contains(.unsupportedSchemaVersion(found: 2)))
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("错误类型：revision/startMs 类型不符逐个拒绝")
    func wrongTypesRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)

        let revisionAsString = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if !documents.isEmpty {
                documents[0]["revision"] = "3"
            }
            root["documents"] = documents
        }
        await expectBackupRejection(
            revisionAsString, from: store,
            equals: .wrongType(path: "root.documents[0].revision", expected: "整数"),
            librarySnapshot: before
        )

        let startMsAsString = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if !documents.isEmpty {
                var lines = documents[0]["lines"] as? [[String: Any]] ?? []
                if !lines.isEmpty {
                    lines[0]["startMs"] = "1000"
                }
                documents[0]["lines"] = lines
            }
            root["documents"] = documents
        }
        await expectBackupRejection(
            startMsAsString, from: store,
            equals: .wrongType(path: "root.documents[0].lines[0].startMs", expected: "整数毫秒或 null"),
            librarySnapshot: before
        )
    }

    @Test("重复文档 id / 重复曲目键：拒绝")
    func duplicateIdentifiersRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let exportData = try await store.exportBackup(at: Fixture.fixedDate)
        let exported = try JSONDecoder().decode(BackupFile.self, from: exportData)

        let duplicatedDocs = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if let first = documents.first {
                documents.append(first)
            }
            root["documents"] = documents
        }
        let firstId = try #require(exported.documents.first?.id)
        await expectBackupRejection(
            duplicatedDocs, from: store,
            equals: .duplicateDocumentId(firstId),
            librarySnapshot: before
        )

        let duplicatedBindings = try await patchExport(store) { root in
            var bindings = root["bindings"] as? [[String: Any]] ?? []
            if let first = bindings.first {
                bindings.append(first)
            }
            root["bindings"] = bindings
        }
        let firstKey = try #require(exported.bindings.first?.trackKey)
        await expectBackupRejection(
            duplicatedBindings, from: store,
            equals: .duplicateTrackKey(firstKey),
            librarySnapshot: before
        )
    }

    @Test("小数毫秒与重复行 id：复用 LyricSchemaValidator 拒绝")
    func validatorIssuesRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let lineId = try await currentLineId(store)

        let fractional = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if !documents.isEmpty {
                var lines = documents[0]["lines"] as? [[String: Any]] ?? []
                if !lines.isEmpty {
                    lines[0]["startMs"] = 1_000.5
                }
                documents[0]["lines"] = lines
            }
            root["documents"] = documents
        }
        guard case let .schemaIssues(fractionalIssues) = firstBackupRejection(fractional, store) else {
            Issue.record("期望 schemaIssues")
            return
        }
        #expect(fractionalIssues.contains(.fractionalMilliseconds(lineId: lineId)))
        #expect(try await store.currentSnapshot() == before)

        let duplicatedLine = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if !documents.isEmpty {
                var lines = documents[0]["lines"] as? [[String: Any]] ?? []
                if let first = lines.first {
                    lines.append(first)
                }
                documents[0]["lines"] = lines
            }
            root["documents"] = documents
        }
        guard case let .schemaIssues(dupIssues) = firstBackupRejection(duplicatedLine, store) else {
            Issue.record("期望 schemaIssues")
            return
        }
        #expect(dupIssues.contains(.duplicateLineId(lineId)))
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("悬空绑定（指向备份中不存在的文档）：拒绝")
    func danglingBindingRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let missing = UUID()
        let binding: [String: Any] = [
            "trackKey": "apple-music:catalog:us:9000001",
            "track": ["storefront": "us", "catalogSongId": "9000001"],
            "lyricDocumentId": missing.uuidString.lowercased(),
            "userDelayMs": 0,
            "titleHint": NSNull(),
            "artistHint": NSNull(),
            "durationHintMs": NSNull(),
            "updatedAt": Fixture.fixedTimestamp
        ]
        let data = try await patchExport(store) { root in
            root["bindings"] = [binding]
        }
        await expectBackupRejection(
            data, from: store,
            equals: .danglingBinding(documentId: missing),
            librarySnapshot: before
        )
    }

    @Test("trackKey 与 track 身份不一致（篡改）：拒绝")
    func trackKeyMismatchRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let data = try await patchExport(store) { root in
            var bindings = root["bindings"] as? [[String: Any]] ?? []
            if !bindings.isEmpty {
                bindings[0]["trackKey"] = "apple-music:catalog:us:0000000"
            }
            root["bindings"] = bindings
        }
        await expectBackupRejection(
            data, from: store,
            equals: .trackKeyMismatch(
                path: "root.bindings[0].trackKey",
                declared: "apple-music:catalog:us:0000000",
                expected: "apple-music:catalog:us:9000001"
            ),
            librarySnapshot: before
        )
    }

    @Test("非法时间戳与非法 UUID：拒绝")
    func invalidTimestampAndUUIDRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)

        let badExportedAt = try await patchExport(store) { root in
            root["exportedAt"] = "不是时间"
        }
        await expectBackupRejection(
            badExportedAt, from: store,
            equals: .invalidTimestamp(path: "root.exportedAt", value: "不是时间"),
            librarySnapshot: before
        )

        let badBindingUpdatedAt = try await patchExport(store) { root in
            var bindings = root["bindings"] as? [[String: Any]] ?? []
            if !bindings.isEmpty {
                bindings[0]["updatedAt"] = "2026/09/10 08:00:00"
            }
            root["bindings"] = bindings
        }
        await expectBackupRejection(
            badBindingUpdatedAt, from: store,
            equals: .invalidTimestamp(path: "root.bindings[0].updatedAt", value: "2026/09/10 08:00:00"),
            librarySnapshot: before
        )

        let badUUID = try await patchExport(store) { root in
            var bindings = root["bindings"] as? [[String: Any]] ?? []
            if !bindings.isEmpty {
                bindings[0]["lyricDocumentId"] = "不是UUID"
            }
            root["bindings"] = bindings
        }
        await expectBackupRejection(
            badUUID, from: store,
            equals: .invalidUUID(path: "root.bindings[0].lyricDocumentId", value: "不是UUID"),
            librarySnapshot: before
        )
    }

    private func currentLineId(_ store: GRDBLyricsStore) async throws -> UUID {
        let snapshot = try await store.currentSnapshot()
        guard let document = snapshot.documents.values.first,
              let line = document.lines.first else {
            Issue.record("库中没有夹具文档")
            return UUID()
        }
        return line.id
    }
}

/// 读导出 → 修改 → 重新序列化（拒绝矩阵共用的夹具修改器）。
func patchExport(
    _ store: GRDBLyricsStore,
    mutate: (inout [String: Any]) -> Void
) async throws -> Data {
    let exportData = try await store.exportBackup(at: Fixture.fixedDate)
    guard var root = try JSONSerialization.jsonObject(with: exportData) as? [String: Any] else {
        Issue.record("导出顶层不是对象")
        return Data()
    }
    mutate(&root)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}
