import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 备份导出/导入：逐字段无损往返、字节确定性、不含敏感字段的结构证明、
// 冲突预览（新增/替换/no-op）、未知键 warning + 白名单导入、
// 重新导入纯函数预览。

@Suite("备份导出与导入")
struct BackupRoundTripTests {

    @Test("导出 → 全新空库导入 → 逐字段一致；再次导出字节相同")
    func exportImportRoundTripFieldByField() async throws {
        let dirA = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirA) }
        let dirB = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirB) }

        let configuration = BackupConfiguration(
            limits: .standard,
            settingAllowlist: ["test.portable.setting"]
        )
        let storeA = try TestEnv.makeStore(dirA, configuration: configuration)

        let docA = Fixture.documentA()
        let docB = Fixture.textDocument()
        try await storeA.save(document: docA, binding: Fixture.binding(Fixture.trackA, to: docA, delayMs: 500))
        try await storeA.save(document: docB, binding: Fixture.binding(Fixture.trackB, to: docB, delayMs: -200))
        try await storeA.setSettingValue("v1", forKey: "test.portable.setting")
        try await storeA.setSettingValue("本地私有", forKey: "test.local.only")

        let exportData = try await storeA.exportBackup(at: Fixture.fixedDate)

        // 权威出口：导出的 JSON 里就应当只有白名单设置。
        let exported = try JSONDecoder().decode(BackupFile.self, from: exportData)
        #expect(exported.schemaVersion == BackupFile.currentSchemaVersion)
        #expect(exported.exportedAt == Fixture.fixedTimestamp)
        #expect(exported.settings == ["test.portable.setting": "v1"])

        // 全新空库：解析 → 预览（全部为新增）→ 确认导入。
        let storeB = try TestEnv.makeStore(dirB, configuration: configuration)
        let parsed = try storeB.parseBackup(exportData)
        #expect(parsed.warnings.isEmpty)
        let preview = try await storeB.backupConflictPreview(for: parsed)
        #expect(preview.documentsToAdd.count == 2)
        #expect(preview.documentReplacements.isEmpty)
        #expect(preview.bindingsToAdd.count == 2)
        #expect(preview.bindingReplacements.isEmpty)
        #expect(preview.settingsToWrite == ["test.portable.setting": "v1"])
        try await storeB.importBackup(parsed)

        // 逐字段对比：文档（原文/译文/时间/offset/revision/schemaVersion/行 id）。
        let docsA = try await storeA.allDocuments()
        let docsB = try await storeB.allDocuments()
        #expect(docsB == docsA)
        #expect(docsB.contains(docA))
        #expect(docsB.contains(docB))
        // 绑定（曲目身份/延迟/提示字段/指向）。
        let bindingsA = try await storeA.allBindings()
        let bindingsB = try await storeB.allBindings()
        #expect(bindingsB == bindingsA)
        #expect(try await storeB.document(for: Fixture.trackA) == docA)
        #expect(try await storeB.binding(for: Fixture.trackA)?.userDelayMs == 500)
        // 设置白名单键恢复，本地私有键不进入备份。
        #expect(try await storeB.settingValue(forKey: "test.portable.setting") == "v1")
        #expect(try await storeB.settingValue(forKey: "test.local.only") == nil)

        // 同一时刻导出：两个库的字节完全一致（确定性输出）。
        let exportB = try await storeB.exportBackup(at: Fixture.fixedDate)
        #expect(exportB == exportData)
    }

    @Test("备份结构上不存在任何 token/密钥/身份/音频字段")
    func backupContainsNoSensitiveKeys() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        let data = try await store.exportBackup(at: Fixture.fixedDate)
        let root = try JSONSerialization.jsonObject(with: data)
        guard let rootObject = root as? [String: Any] else {
            Issue.record("备份顶层不是对象")
            return
        }
        // 每一层对象的键都在白名单内（必需键齐全）：结构上不存在敏感字段的位置。
        // 说明：synthesized Codable 对可选字段用 encodeIfPresent，nil 字段不出现。
        #expect(Set(rootObject.keys) == ["schemaVersion", "exportedAt", "documents", "bindings", "settings"])
        let documents = rootObject["documents"] as? [[String: Any]] ?? []
        for documentObject in documents {
            let keys = Set(documentObject.keys)
            #expect(keys.isSubset(of: [
                "schemaVersion", "id", "revision", "sourceLanguage", "sourceFormat",
                "sourceOffsetMs", "originalText", "originalFilename", "metadata",
                "lines", "createdAt", "updatedAt"
            ]))
            #expect(["schemaVersion", "id", "revision", "sourceFormat",
                     "sourceOffsetMs", "metadata", "lines", "createdAt", "updatedAt"]
                .allSatisfy(keys.contains))
            for line in documentObject["lines"] as? [[String: Any]] ?? [] {
                let lineKeys = Set(line.keys)
                #expect(lineKeys.isSubset(of: ["id", "startMs", "text", "translations"]))
                #expect(["id", "text"].allSatisfy(lineKeys.contains))
                for translation in line["translations"] as? [String: [String: Any]] ?? [:] {
                    #expect(Set(translation.value.keys) == ["text", "source", "needsReview"])
                }
            }
        }
        for binding in rootObject["bindings"] as? [[String: Any]] ?? [] {
            let keys = Set(binding.keys)
            #expect(keys.isSubset(of: [
                "trackKey", "track", "lyricDocumentId", "userDelayMs",
                "titleHint", "artistHint", "durationHintMs", "updatedAt"
            ]))
            #expect(["trackKey", "track", "lyricDocumentId", "userDelayMs", "updatedAt"]
                .allSatisfy(keys.contains))
        }
        // 纵深防御：原始字节中不出现敏感词。
        let lowered = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        for banned in ["token", "secret", "password", "apikey", "authorization", ".p8", "musicsession"] {
            #expect(!lowered.contains(banned), "备份中不应出现敏感词：\(banned)")
        }
    }

    @Test("备份导入替换已有文档与绑定：预览展示全部替换项，提交后生效")
    func importConflictPreviewAndReplace() async throws {
        let dirA = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirA) }
        let dirB = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirB) }

        let storeA = try TestEnv.makeStore(dirA)
        // 库 B 现状：旧版 docX（rev 3）绑定 trackA；无关文档 docOther。
        let oldX = Fixture.documentA(revision: 3)
        let other = Fixture.textDocument()
        try await storeA.save(document: oldX, binding: Fixture.binding(Fixture.trackA, to: oldX, delayMs: 100))
        try await storeA.save(document: other, binding: Fixture.binding(Fixture.trackB, to: other, delayMs: 0))

        // 备份内容：同 id 的 docX（rev 7，内容已改）+ 新文档 docY + 绑定变化。
        let newX = Fixture.documentA(id: oldX.id, revision: 7)
        let newY = Fixture.textDocument()
        let backup: BackupFile = BackupFile(
            exportedAt: Fixture.fixedTimestamp,
            documents: [newX, newY],
            bindings: [
                BackupBinding(from: Fixture.binding(Fixture.trackA, to: newX, delayMs: 300)),
                BackupBinding(from: Fixture.binding(Fixture.trackC, to: newY, delayMs: 0))
            ],
            settings: [:]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(backup)

        let parsed = try storeA.parseBackup(data)
        let preview = try await storeA.backupConflictPreview(for: parsed)
        #expect(preview.documentReplacements == [BackupDocumentReplacement(existing: oldX, incoming: newX)])
        #expect(preview.documentsToAdd == [newY])
        #expect(preview.bindingReplacements.count == 1)
        #expect(preview.bindingReplacements.first?.existing.lyricDocumentId == oldX.id)
        #expect(preview.bindingReplacements.first?.incoming.lyricDocumentId == newX.id)
        #expect(preview.bindingsToAdd.count == 1)
        #expect(preview.bindingsToAdd.first?.track == Fixture.trackC)

        try await storeA.importBackup(parsed)
        #expect(try await storeA.document(for: Fixture.trackA) == newX)
        #expect(try await storeA.binding(for: Fixture.trackA)?.userDelayMs == 300)
        #expect(try await storeA.document(id: oldX.id) == newX)
        // 无关数据不受影响；旧文档 docX 被 rev7 内容替换（同 id 即同文档）。
        #expect(try await storeA.document(for: Fixture.trackB) == other)
    }

    @Test("完全一致的备份导入：预览为空（no-op），提交无变化")
    func identicalBackupPreviewIsEmpty() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        let data = try await store.exportBackup()
        let parsed = try store.parseBackup(data)
        let preview = try await store.backupConflictPreview(for: parsed)
        #expect(preview.isEmpty)
        let before = try await store.currentSnapshot()
        try await store.importBackup(parsed)
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("含未知键的备份：warning 不静默丢弃；白名单字段正常导入")
    func unknownKeysProduceWarningsAndAllowlistImports() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        let exportData = try await store.exportBackup(at: Fixture.fixedDate)

        // 注入各层未知键（含恶意风格的键）后重新序列化。
        guard var root = try JSONSerialization.jsonObject(with: exportData) as? [String: Any] else {
            Issue.record("导出顶层不是对象")
            return
        }
        root["sneakyRootKey"] = "ignore-me"
        var documents = root["documents"] as? [[String: Any]] ?? []
        if !documents.isEmpty {
            var first = documents[0]
            first["words"] = [["测试逐字数据"]]
            if var lines = first["lines"] as? [[String: Any]], !lines.isEmpty {
                var firstLine = lines[0]
                var translations = firstLine["translations"] as? [String: [String: Any]] ?? [:]
                if let zh = translations["zh-Hans"] {
                    var patched = zh
                    patched["model"] = "未知字段"
                    translations["zh-Hans"] = patched
                }
                firstLine["translations"] = translations
                lines[0] = firstLine
                first["lines"] = lines
            }
            documents[0] = first
        }
        root["documents"] = documents
        let patchedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        let parsed = try store.parseBackup(patchedData)
        let warningKeys = parsed.warnings.map { warning -> String in
            if case let .unknownKey(path, key) = warning { return "\(path).\(key)" }
            return ""
        }
        #expect(warningKeys.contains("root.sneakyRootKey"))
        #expect(warningKeys.contains("root.documents[0].words"))
        #expect(parsed.warnings.contains(.unknownKey(path: "root.documents[0].lines[0].translations.zh-Hans", key: "model")))

        // 白名单字段照常导入且与原库一致。
        try await store.importBackup(parsed)
        #expect(try await store.document(for: Fixture.trackA) == document)
        // 未知键不会被持久化：再次导出不包含它们。
        let reexport = try await store.exportBackup(at: Fixture.fixedDate)
        #expect(!(String(data: reexport, encoding: .utf8) ?? "").contains("sneakyRootKey"))
        #expect(!(String(data: reexport, encoding: .utf8) ?? "").contains("words"))
    }

    @Test("设置白名单：导出只含白名单键；导入未知设置键产出 warning")
    func settingsAllowlistExportAndImport() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let configuration = BackupConfiguration(
            limits: .standard,
            settingAllowlist: ["test.portable.setting"]
        )
        let store = try TestEnv.makeStore(dir, configuration: configuration)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await store.setSettingValue("v1", forKey: "test.portable.setting")
        try await store.setSettingValue("x", forKey: "local.notes")

        let data = try await store.exportBackup(at: Fixture.fixedDate)
        let exported = try JSONDecoder().decode(BackupFile.self, from: data)
        #expect(exported.settings == ["test.portable.setting": "v1"])

        // 导入带未知设置键的备份：键被剔除并警告，白名单键正常写入。
        let backup: BackupFile = BackupFile(
            exportedAt: Fixture.fixedTimestamp,
            documents: [],
            bindings: [],
            settings: [
                "test.portable.setting": "v2",
                "unknown.setting": "y"
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let patchedData = try encoder.encode(backup)
        let parsed = try store.parseBackup(patchedData)
        #expect(parsed.warnings.contains(.settingNotInAllowlist(key: "unknown.setting")))
        #expect(parsed.file.settings == ["test.portable.setting": "v2"])
        try await store.importBackup(parsed)
        #expect(try await store.settingValue(forKey: "test.portable.setting") == "v2")
        #expect(try await store.settingValue(forKey: "unknown.setting") == nil)
    }

    @Test("重新导入纯函数预览：共享旧文档时不提示失去最后一个引用")
    func reimportPreviewSharedDocument() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let shared = Fixture.documentA()
        try await store.save(document: shared, binding: Fixture.binding(Fixture.trackA, to: shared))
        try await store.updateBinding(Fixture.binding(Fixture.trackB, to: shared, delayMs: 1))

        let incoming = Fixture.documentA()
        let preview = try await store.reimportPreview(
            incomingDocument: incoming,
            binding: Fixture.binding(Fixture.trackA, to: incoming)
        )
        #expect(preview.replacedBinding?.track == Fixture.trackA)
        #expect(preview.replacedBinding?.lyricDocumentId == shared.id)
        // 旧文档还被 trackB 引用：不是"失去最后一个引用"。
        #expect(preview.documentsLosingLastBinding.isEmpty)

        // 全新关联（无现有绑定）：replacedBinding 为 nil。
        let freshPreview = try await store.reimportPreview(
            incomingDocument: incoming,
            binding: Fixture.binding(Fixture.trackC, to: incoming)
        )
        #expect(freshPreview.replacedBinding == nil)
        #expect(freshPreview.documentsLosingLastBinding.isEmpty)
    }
}
