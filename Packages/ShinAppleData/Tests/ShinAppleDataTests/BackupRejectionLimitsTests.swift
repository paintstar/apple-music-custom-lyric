import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 非法备份的拒绝矩阵（2/2）：资源限制与编码类拒绝。
// 半截 JSON、超大数组、非 UTF-8、深度异常、超限设置、超限字节——
// 全部拒绝且原库一个字节不动（快照前后相等）。

@Suite("备份拒绝矩阵：资源限制与编码")
struct BackupRejectionLimitsTests {

    @Test("半截 JSON（截断字节）被拒绝，原库不变")
    func truncatedJSONRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let exportData = try await store.exportBackup(at: Fixture.fixedDate)
        let truncated = Data(exportData.dropLast(24))

        guard case .invalidJSON = firstBackupRejection(truncated, store) else {
            Issue.record("期望 invalidJSON")
            return
        }
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("超大数组：documents 条数超过可配置上限即拒绝")
    func oversizedDocumentsRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let data = try await patchExport(store) { root in
            root["documents"] = [[String: Any]](repeating: minimalDocumentObject(), count: 3)
        }
        await expectBackupRejection(
            data, from: store, configuration: limitsWith(maxDocuments: 2),
            equals: .oversizedArray(path: "root.documents", count: 3, limit: 2),
            librarySnapshot: before
        )
    }

    @Test("行数超限：lines 数组超过上限拒绝")
    func oversizedLinesRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let line: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "startMs": NSNull(),
            "text": "测试行",
            "translations": [String: Any]()
        ]
        let data = try await patchExport(store) { root in
            var documents = root["documents"] as? [[String: Any]] ?? []
            if !documents.isEmpty {
                documents[0]["lines"] = [Any](repeating: line, count: 5)
            }
            root["documents"] = documents
        }
        await expectBackupRejection(
            data, from: store, configuration: limitsWith(maxTotalLines: 4),
            equals: .oversizedArray(path: "root.documents[0].lines", count: 5, limit: 4),
            librarySnapshot: before
        )
    }

    @Test("非 UTF-8 字节与 UTF-16 BOM：拒绝")
    func nonUTF8Rejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)

        await expectBackupRejection(
            Data([0x7B, 0xFF, 0xFE, 0x7D]), from: store,
            equals: .notUTF8(reason: "字节序列不是合法 UTF-8"),
            librarySnapshot: before
        )
        await expectBackupRejection(
            Data([0xFF, 0xFE, 0x7B, 0x7D]), from: store,
            equals: .notUTF8(reason: "检测到 UTF-16/32 BOM；备份必须是 UTF-8"),
            librarySnapshot: before
        )
    }

    @Test("深度异常的未知键内容：拒绝")
    func deepNestingRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let data = try await patchExport(store) { root in
            var nested: Any = "底"
            for _ in 0 ..< 40 {
                nested = [nested]
            }
            root["sneakyDeep"] = nested
        }
        guard case let .tooDeep(path, depth, limit) = firstBackupRejection(data, store) else {
            Issue.record("期望 tooDeep")
            return
        }
        #expect(path.hasPrefix("root.sneakyDeep"))
        #expect(depth > 32)
        #expect(limit == 32)
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("设置值非字符串与设置条数超限：拒绝")
    func invalidSettingsRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let configuration = BackupConfiguration(
            limits: .standard,
            settingAllowlist: ["test.portable.setting"]
        )
        let store = try TestEnv.makeStore(dir, configuration: configuration)
        let before = try await seedBackupFixture(store)

        let nonString = try await patchExport(store) { root in
            root["settings"] = ["test.portable.setting": 42]
        }
        await expectBackupRejection(
            nonString, from: store,
            equals: .settingsValueNotString(key: "test.portable.setting"),
            librarySnapshot: before
        )

        let tooMany = try await patchExport(store) { root in
            root["settings"] = ["a": "1", "b": "2", "c": "3"]
        }
        await expectBackupRejection(
            tooMany, from: store, configuration: limitsWith(maxSettingsEntries: 2),
            equals: .tooManySettings(count: 3, limit: 2),
            librarySnapshot: before
        )
    }

    @Test("字节数超限：拒绝")
    func oversizedBytesRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let data = try await store.exportBackup(at: Fixture.fixedDate)
        await expectBackupRejection(
            data, from: store, configuration: limitsWith(maxBytes: 16),
            equals: .tooLarge(bytes: data.count, limit: 16),
            librarySnapshot: before
        )
    }
}

private func minimalDocumentObject() -> [String: Any] {
    [
        "schemaVersion": 1,
        "id": UUID().uuidString.lowercased(),
        "revision": 1,
        "sourceFormat": "text",
        "sourceOffsetMs": 0,
        "metadata": [String: Any](),
        "lines": [[String: Any]](),
        "createdAt": Fixture.fixedTimestamp,
        "updatedAt": Fixture.fixedTimestamp
    ]
}
