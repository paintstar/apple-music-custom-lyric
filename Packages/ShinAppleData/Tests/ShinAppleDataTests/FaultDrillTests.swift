import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 故障演练与恢复（「迁移异常、损坏数据：UI 不假装
// 保存成功，旧数据尽量可恢复」）：
// - 损坏库文件：类型化 storageUnavailable，消息与 dataFilePath 携带数据
//   文件路径；绝不自动删除/重建库文件（字节原样）；
// - 迁移中途失败：迁移事务回滚，旧库保留、旧数据可读、仍可导出完整备份；
// - 非法路径/只读目录：打开与保存都是类型化失败，读取不受影响；
// - exportPreOpenBackup：升级前安全备份的可选调用点（成功导出可再解析；
//   失败 soft-fail，不动原文件）。
//
// 说明：只读演练依赖 POSIX 权限（chmod），以普通用户身份运行有效；
// 以 root 运行测试时权限检查会被绕过，该组用例不适用（本仓库从不以
// root 运行测试）。

private struct InjectedMigrationFailure: Error { }

@Suite("故障演练与恢复")
struct FaultDrillTests {

    // MARK: - 损坏库文件

    @Test("损坏库：打开抛类型化 storageUnavailable，错误携带数据文件路径")
    func corruptFileFailsTypedWithPath() throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)
        try Data("这明显不是一个 SQLite 数据库文件（故障夹具）。".utf8)
            .write(to: URL(fileURLWithPath: path))

        do {
            _ = try TestEnv.makeStore(dir)
            Issue.record("损坏文件应当打开失败")
        } catch let error as ShinAppleDataError {
            guard case let .storageUnavailable(message) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(message.contains(path), "错误消息应包含数据文件路径：\(message)")
            #expect(error.dataFilePath == path, "dataFilePath 应能提取出路径供 UI 展示指引")
        }
    }

    @Test("损坏库：打开失败后库文件绝不自动删除/重建（字节原样保留）")
    func corruptFileIsNotDeletedOrRebuilt() throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)
        let garbage = Data("不是数据库的字节（故障夹具，不应被改动）。".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))

        do {
            _ = try TestEnv.makeStore(dir)
            Issue.record("损坏文件应当打开失败")
        } catch let error as ShinAppleDataError {
            guard case .storageUnavailable = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
        // 恢复路径的前提：失败的打开尝试不销毁现场（用户可拿原文件另寻修复）。
        #expect(FileManager.default.fileExists(atPath: path), "库文件不应被删除")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == garbage, "库文件字节不应被重建/改写")
    }

    @Test("非法路径（父目录不存在）：打开失败为类型化错误，消息含路径")
    func missingDirectoryFailsTyped() throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let badPath = dir + "/不存在的子目录/lyrics.sqlite"
        do {
            _ = try GRDBLyricsStore(path: badPath)
            Issue.record("父目录缺失应当打开失败")
        } catch let error as ShinAppleDataError {
            guard case let .storageUnavailable(message) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(message.contains(badPath))
            #expect(error.dataFilePath == badPath)
        }
    }

    // MARK: - 迁移失败

    @Test("迁移中途失败：库文件保留、旧数据可读、仍可导出完整备份")
    func failedMigrationKeepsFileReadableAndExportable() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)

        let store1 = try GRDBLyricsStore(path: path)
        let document = Fixture.documentA()
        try await store1.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        // 模拟未来升级中途失败：v1 之后注入一个必失败的迁移。
        var badMigrator = Schema.migrator()
        badMigrator.registerMigration("v2.p401.bad") { _ in
            throw InjectedMigrationFailure()
        }
        #expect(throws: InjectedMigrationFailure.self) {
            try badMigrator.migrate(DatabaseQueue(path: path))
        }

        #expect(FileManager.default.fileExists(atPath: path), "迁移失败后库文件必须保留")
        // 旧数据仍可读（回滚到上一版本）。
        let store2 = try GRDBLyricsStore(path: path)
        #expect(try await store2.document(for: Fixture.trackA) == document)
        #expect(try await store2.binding(for: Fixture.trackA) != nil)
        // 恢复出口：旧库仍可导出完整备份，且导出物可被再次解析。
        let backup = try await store2.exportBackup()
        let parsed = try store2.parseBackup(backup)
        #expect(parsed.file.documents.map(\.id) == [document.id])
    }

    @Test("打开入口迁移失败（同名异构表冲突）：类型化错误含路径与保留说明，文件不删除")
    func storeInitMigrationFailureIsTypedAndKeepsFile() throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)

        // 构造「会让 migrator 中途失败」的库：已存在同名但结构不同的表，
        // v1.schema 建表必然失败。
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.create(table: "lyricDocument") { t in
                t.primaryKey("id", .text).notNull()
                t.column("不相关的旧结构", .text)
            }
        }

        do {
            _ = try TestEnv.makeStore(dir)
            Issue.record("迁移失败应当让打开失败")
        } catch let error as ShinAppleDataError {
            guard case let .storageUnavailable(message) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(message.contains("迁移失败"), "应说明是迁移失败：\(message)")
            #expect(message.contains("原库保留"), "应说明旧库保留：\(message)")
            #expect(error.dataFilePath == path)
        }
        #expect(FileManager.default.fileExists(atPath: path), "迁移失败后库文件必须保留")
    }

    // MARK: - 只读目录（磁盘写入失败模拟）

    @Test("只读目录：保存得到类型化失败；读取不受影响（旧数据完好）")
    func readOnlyDirectorySaveFailsReadIntact() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)

        let store1 = try GRDBLyricsStore(path: path)
        let document = Fixture.documentA()
        try await store1.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await store1.setSettingValue("mock", forKey: "playback.mode")

        try TestEnv.makeReadOnly(dir)
        // 说明：POSIX 权限位在 open() 时检查——chmod 前
        // 已打开的连接持有可写 fd，写入可能仍然成功；真实「磁盘/权限故障」
        // 对应的是**新连接**访问只读库。这里与既有用例一致，用新连接演练。
        if let store2 = try? GRDBLyricsStore(path: path) {
            do {
                try await store2.setSettingValue("changed", forKey: "playback.mode")
                Issue.record("只读库的新连接保存应当失败（不允许假成功）")
            } catch let error as ShinAppleDataError {
                guard case .storageUnavailable = error else {
                    Issue.record("错误类型不符：\(error)")
                    return
                }
            }
            // 写失败未改写数据：旧值与旧文档原样可读（UI 可如实呈现「保存失败」）。
            #expect(try await store2.settingValue(forKey: "playback.mode") == "mock")
            #expect(try await store2.document(for: Fixture.trackA) == document)
        } else {
            // 新连接打开即失败：也必须是类型化错误（与既有用例一致）。
            do {
                _ = try GRDBLyricsStore(path: path)
                Issue.record("应当打开失败")
            } catch let error as ShinAppleDataError {
                guard case .storageUnavailable = error else {
                    Issue.record("错误类型不符：\(error)")
                    return
                }
            }
        }
    }

    // MARK: - 升级前安全备份（exportPreOpenBackup）

    @Test("exportPreOpenBackup：已存在的库导出完整快照，导出物可再解析且含原数据")
    func preOpenBackupExportsParseableSnapshot() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let path = TestEnv.storePath(in: dir)

        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await store.setSettingValue("mock", forKey: "playback.mode")

        let destination = URL(fileURLWithPath: dir + "/lyrics.preopen.json")
        let succeeded = await GRDBLyricsStore.exportPreOpenBackup(at: path, to: destination)
        #expect(succeeded, "正常库的打开前备份应当成功")

        let data = try Data(contentsOf: destination)
        let parsed = try store.parseBackup(data)
        #expect(parsed.file.documents.map(\.id) == [document.id])
        #expect(parsed.file.bindings.count == 1)
        // 设置仅按白名单导出（standard 白名单为空，行为由 BackupRoundTripTests 覆盖）。
        #expect(parsed.file.settings.isEmpty)
    }

    @Test("exportPreOpenBackup：库不存在或损坏时 soft-fail——不抛错、不写目标、不动原文件")
    func preOpenBackupFailsSoft() async throws {
        // 库不存在：返回 false，目标不产生文件。
        let dir1 = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir1) }
        let destination1 = URL(fileURLWithPath: dir1 + "/lyrics.preopen.json")
        let missing = await GRDBLyricsStore.exportPreOpenBackup(
            at: TestEnv.storePath(in: dir1), to: destination1
        )
        #expect(missing == false)
        #expect(!FileManager.default.fileExists(atPath: destination1.path))

        // 库损坏：返回 false，不抛错；目标不产生文件；原文件字节不动。
        let dir2 = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir2) }
        let path2 = TestEnv.storePath(in: dir2)
        let garbage = Data("不是数据库的字节（故障夹具）。".utf8)
        try garbage.write(to: URL(fileURLWithPath: path2))
        let destination2 = URL(fileURLWithPath: dir2 + "/lyrics.preopen.json")
        let corrupted = await GRDBLyricsStore.exportPreOpenBackup(at: path2, to: destination2)
        #expect(corrupted == false)
        #expect(!FileManager.default.fileExists(atPath: destination2.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path2)) == garbage)
    }

    @Test("dataFilePath：运行期写入失败等其他 storageUnavailable 返回 nil")
    func dataFilePathNilForOtherMessages() {
        let injected = ShinAppleDataError.storageUnavailable("注入失败点：文档写入后、绑定写入前")
        #expect(injected.dataFilePath == nil)
        #expect(ShinAppleDataError.documentNotFound(UUID()).dataFilePath == nil)
    }
}
