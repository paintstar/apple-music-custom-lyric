import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

// revision 乐观并发（多标签页/多窗口）与事务原子性：
// 文档写成功 + 绑定写失败 → 整体回滚；数据库只读/损坏 → 类型化错误；
// 迁移失败 → 回滚到上一版本，旧数据可读。

private struct InjectedMigrationFailure: Error { }

@Suite("revision 与事务")
struct RevisionTransactionTests {

    @Test("新文档可用任意 revision >= 1 插入；同 revision 重复保存是冲突")
    func insertThenSameRevisionConflicts() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        // 导入恢复场景：文档可携带历史 revision（如 7）直接入库。
        let restored = Fixture.documentA(revision: 7)
        try await store.save(document: restored, binding: Fixture.binding(Fixture.trackA, to: restored))

        // 未递增 revision 的再次保存必须失败（默认 rev1 的新文档同理）。
        do {
            try await store.save(document: restored, binding: Fixture.binding(Fixture.trackA, to: restored))
            Issue.record("同 revision 重复保存应当冲突")
        } catch let error as ShinAppleDataError {
            #expect(error == .revisionConflict(
                documentId: restored.id, storedRevision: 7, submittedRevision: 7
            ))
        }
        // 契约错误的映射。
        #expect(errorContractType(ShinAppleDataError.revisionConflict(
            documentId: restored.id, storedRevision: 7, submittedRevision: 7
        )) == .revisionConflict(documentId: restored.id))
        #expect(try await store.document(for: Fixture.trackA) == restored)
    }

    @Test("revision < 1 的文档被拒绝")
    func invalidRevisionRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA(revision: 0)
        do {
            try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
            Issue.record("revision 0 应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .invalidRevision(documentId: document.id, revision: 0))
        }
        #expect(try await store.allDocuments().isEmpty)
    }

    @Test("两个窗口/标签页基于同一版本编辑：后提交者收到类型化冲突，不静默覆盖")
    func concurrentTabsConflict() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)

        let windowA = try GRDBLyricsStore(path: path)
        let windowB = try GRDBLyricsStore(path: path)

        let document = Fixture.documentA(revision: 1)
        try await windowA.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        // 两个窗口都基于 rev1 载入，各自提交 rev2。
        let editB = Fixture.documentA(id: document.id, revision: 2)
        try await windowB.save(document: editB, binding: Fixture.binding(Fixture.trackA, to: editB))

        // 窗口 A 提交过期的 rev2：stored 已是 2，submitted 2 ≠ 3 → 冲突。
        do {
            try await windowA.save(document: editB, binding: Fixture.binding(Fixture.trackA, to: editB))
            Issue.record("过期 revision 应当冲突")
        } catch let error as ShinAppleDataError {
            #expect(error == .revisionConflict(
                documentId: document.id, storedRevision: 2, submittedRevision: 2
            ))
        }

        // 窗口 A 重新载入最新版本后提交 rev3 成功。
        let reloaded = try await windowA.document(for: Fixture.trackA)
        #expect(reloaded?.revision == 2)
        let editA = Fixture.documentA(id: document.id, revision: 3)
        try await windowA.save(document: editA, binding: Fixture.binding(Fixture.trackA, to: editA))
        #expect(try await windowB.document(for: Fixture.trackA)?.revision == 3)
    }

    @Test("文档写成功但绑定写失败：事务整体回滚，半成品状态不存在")
    func bindingWriteFailureRollsBackDocument() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let document = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: document)
        await #expect(throws: ShinAppleDataError.self) {
            try await store.performSave(
                document: document, binding: binding, failurePoint: .afterDocumentWrite
            )
        }

        #expect(try await store.document(id: document.id) == nil)
        #expect(try await store.binding(for: Fixture.trackA) == nil)
        #expect(try await store.allDocuments().isEmpty)
        #expect(try await store.allBindings().isEmpty)
    }

    @Test("绑定写成功后注入失败：同样整体回滚（不留新文档与新绑定）")
    func postBindingFailureRollsBackEverything() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        // 先放入一个既有文档，验证回滚不会波及无关数据。
        let existing = Fixture.textDocument()
        try await store.save(document: existing, binding: Fixture.binding(Fixture.trackB, to: existing))

        let document = Fixture.documentA()
        await #expect(throws: ShinAppleDataError.self) {
            try await store.performSave(
                document: document,
                binding: Fixture.binding(Fixture.trackA, to: document),
                failurePoint: .afterBindingWrite
            )
        }
        #expect(try await store.document(id: document.id) == nil)
        #expect(try await store.binding(for: Fixture.trackA) == nil)
        #expect(try await store.document(for: Fixture.trackB) == existing)
    }

    @Test("trackKey 与 track 身份不一致：保存前拒绝，不写库")
    func trackKeyMismatchRejectedBeforeWrite() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let document = Fixture.documentA()
        var binding = Fixture.binding(Fixture.trackA, to: document)
        binding.trackKey = "apple-music:catalog:us:9999999"
        do {
            try await store.save(document: document, binding: binding)
            Issue.record("trackKey 不一致应当被拒绝")
        } catch let error as ShinAppleDataError {
            guard case .invalidBinding = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
        #expect(try await store.allDocuments().isEmpty)
    }

    @Test("损坏的数据库文件：打开失败并给出类型化错误，不假装成功")
    func corruptDatabaseFileFailsTyped() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)
        try Data("这明显不是一个 SQLite 数据库文件。".utf8)
            .write(to: URL(fileURLWithPath: path))

        do {
            _ = try TestEnv.makeStore(dir)
            Issue.record("损坏文件应当打开失败")
        } catch let error as ShinAppleDataError {
            guard case .storageUnavailable = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("数据库目录只读：写入得到类型化错误，不假装保存成功")
    func readOnlyDatabaseFailsTyped() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }

        let store1 = try TestEnv.makeStore(dir)
        try await store1.setSettingValue("mock", forKey: "playback.mode")
        try TestEnv.makeReadOnly(dir)

        // 新连接：打开成功与否取决于 SQLite 对只读 WAL 的处理；
        // 无论哪种情况，写操作都必须得到类型化失败。
        if let store2 = try? TestEnv.makeStore(dir) {
            await #expect(throws: ShinAppleDataError.self) {
                try await store2.setSettingValue("changed", forKey: "playback.mode")
            }
        } else {
            // 打开即失败也必须落在 storageUnavailable 上（上面 try? 已隐藏类型，
            // 这里重新打开验证错误类型）。
            do {
                _ = try TestEnv.makeStore(dir)
                Issue.record("应当打开失败")
            } catch let error as ShinAppleDataError {
                guard case .storageUnavailable = error else {
                    Issue.record("错误类型不符：\(error)")
                    return
                }
            }
        }
    }

    @Test("迁移失败：事务回滚，旧版本数据保持可读可恢复")
    func failedMigrationKeepsOldDataReadable() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)

        let store1 = try GRDBLyricsStore(path: path)
        let document = Fixture.documentA()
        try await store1.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        // 构造一个在 v1 之后注入的坏迁移（模拟未来升级中途失败）。
        var badMigrator = Schema.migrator()
        badMigrator.registerMigration("v2.test.bad") { _ in
            throw InjectedMigrationFailure()
        }
        #expect(throws: InjectedMigrationFailure.self) {
            try badMigrator.migrate(DatabaseQueue(path: path))
        }

        // 失败的迁移不破坏旧库：重新打开，v1 数据原样可读。
        let store2 = try GRDBLyricsStore(path: path)
        #expect(try await store2.document(for: Fixture.trackA) == document)
        #expect(try await store2.binding(for: Fixture.trackA) != nil)
    }
}

/// 契约错误映射检查用的小工具。
private func errorContractType(_ error: ShinAppleDataError) -> LyricsRepositoryError? {
    error.contractError
}
