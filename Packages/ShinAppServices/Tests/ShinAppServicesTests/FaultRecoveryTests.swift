import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 故障恢复：
// - 错误映射完整性：每个 ShinAppleDataError case 经三个应用服务映射后
//   都有类型化结果与中文 message（不泄漏原始枚举调试文本）；
// - 恢复建议分类：每个 case 有明确分类；
// - 备份损坏：保留 parse 阶段的类型化拒绝原因；
// - 冲突恢复环：编辑提交冲突 → 载入库中最新版本 → 再提交成功（不丢库数据）。

/// 粗查文本包含中日韩统一表意文字（验证面向用户的消息确为中文）。
private func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
    }
}

/// 覆盖全部 case 的样例集（id 相同便于拼装期望值）。
private enum MappedCases {
    static let id = UUID()

    static var all: [ShinAppleDataError] {
        [
            .revisionConflict(documentId: id, storedRevision: 2, submittedRevision: 1),
            .storageUnavailable("演练细节"),
            .invalidDocument([]),
            .invalidRevision(documentId: id, revision: 0),
            .invalidBinding("关联非法"),
            .invalidSettingKey("演练键"),
            .documentNotFound(id),
            .documentInUse(documentId: id, affectedBindingCount: 2),
            .invalidBackup(.tooLarge(bytes: 9, limit: 5))
        ]
    }
}

@Suite("错误映射完整性")
struct FaultMappingTests {

    @Test("导入工作流映射：9 类存储错误全部有类型化结果与中文 message")
    func importMappingExhaustive() throws {
        let expected: [(ShinAppleDataError, ImportWorkflowError)] = [
            (.revisionConflict(documentId: MappedCases.id, storedRevision: 2, submittedRevision: 1),
             .revisionConflict(documentId: MappedCases.id, storedRevision: 2, submittedRevision: 1)),
            (.storageUnavailable("演练细节"), .storageUnavailable("演练细节")),
            (.invalidDocument([]), .schemaRejected([])),
            (.invalidRevision(documentId: MappedCases.id, revision: 0),
             .storeRejection("文档 \(MappedCases.id.uuidString) 的 revision 非法：0")),
            (.invalidBinding("关联非法"), .storeRejection("关联非法")),
            (.invalidSettingKey("演练键"), .storeRejection("设置项非法：演练键")),
            (.documentNotFound(MappedCases.id),
             .storeRejection("目标文档不存在：\(MappedCases.id.uuidString)")),
            (.documentInUse(documentId: MappedCases.id, affectedBindingCount: 2),
             .storeRejection("文档 \(MappedCases.id.uuidString) 仍被 2 个绑定引用")),
            (.invalidBackup(.tooLarge(bytes: 9, limit: 5)),
             .storeRejection("备份文件未通过校验：文件过大（9 字节，上限 5 字节）"))
        ]
        for (dataError, expectedError) in expected {
            let mapped = ImportWorkflowError.mapStoreError(dataError)
            #expect(mapped == expectedError, "映射不符：\(dataError) → \(mapped)")
            #expect(!mapped.message.isEmpty)
            #expect(containsCJK(mapped.message), "中文说明缺失：\(mapped.message)")
            #expect(!mapped.message.contains("ShinAppleDataError"), "不应泄漏调试文本")
            #expect(!mapped.message.contains("BackupRejection"), "不应泄漏调试文本")
        }
        // 覆盖数与源枚举一致（9 个 case 样例）。
        #expect(expected.count == 9)
        #expect(MappedCases.all.count == 9)
    }

    @Test("编辑会话映射：9 类存储错误全部有类型化结果与中文 message")
    func editingMappingExhaustive() throws {
        let expected: [(ShinAppleDataError, LyricsEditingError)] = [
            (.revisionConflict(documentId: MappedCases.id, storedRevision: 2, submittedRevision: 1),
             .revisionConflict(documentId: MappedCases.id, storedRevision: 2, submittedRevision: 1)),
            (.storageUnavailable("演练细节"), .storageUnavailable("演练细节")),
            (.invalidDocument([]), .storeRejection("歌词数据未通过完整性校验（0 处）")),
            (.invalidRevision(documentId: MappedCases.id, revision: 0),
             .storeRejection("文档 \(MappedCases.id.uuidString) 的 revision 非法：0")),
            (.invalidBinding("关联非法"), .storeRejection("歌曲关联数据非法：关联非法")),
            (.invalidSettingKey("演练键"), .storeRejection("设置项非法：演练键")),
            (.documentNotFound(MappedCases.id), .documentNotFound(MappedCases.id)),
            (.documentInUse(documentId: MappedCases.id, affectedBindingCount: 2),
             .storeRejection("文档 \(MappedCases.id.uuidString) 仍被 2 个绑定引用")),
            (.invalidBackup(.tooLarge(bytes: 9, limit: 5)),
             .storeRejection("备份文件未通过校验：文件过大（9 字节，上限 5 字节）"))
        ]
        for (dataError, expectedError) in expected {
            let mapped = LyricsEditingError.mapStoreError(dataError)
            #expect(mapped == expectedError, "映射不符：\(dataError) → \(mapped)")
            #expect(!mapped.message.isEmpty)
            #expect(containsCJK(mapped.message), "中文说明缺失：\(mapped.message)")
            #expect(!mapped.message.contains("ShinAppleDataError"))
        }
    }

    @Test("歌词库映射：9 类存储错误全部有类型化结果与中文 message")
    func libraryMappingExhaustive() throws {
        let expected: [(ShinAppleDataError, LyricsLibraryError)] = [
            (.revisionConflict(documentId: MappedCases.id, storedRevision: 2, submittedRevision: 1),
             .storeRejection(
                "文档已被其他窗口修改（库中 revision 2，提交 1）：\(MappedCases.id.uuidString)"
             )),
            (.storageUnavailable("演练细节"), .storageUnavailable("演练细节")),
            (.invalidDocument([]), .storeRejection("歌词数据未通过完整性校验（共 0 处），已拒绝写入。")),
            (.invalidRevision(documentId: MappedCases.id, revision: 0),
             .storeRejection("文档 \(MappedCases.id.uuidString) 的 revision 非法：0")),
            (.invalidBinding("关联非法"), .storeRejection("歌曲关联数据非法：关联非法")),
            (.invalidSettingKey("演练键"), .storeRejection("设置项非法：演练键")),
            (.documentNotFound(MappedCases.id), .documentNotFound(MappedCases.id)),
            (.documentInUse(documentId: MappedCases.id, affectedBindingCount: 2),
             .storeRejection("文档 \(MappedCases.id.uuidString) 仍被 2 个绑定引用")),
            (.invalidBackup(.tooLarge(bytes: 9, limit: 5)),
             .storeRejection("备份文件未通过校验：文件过大（9 字节，上限 5 字节）"))
        ]
        for (dataError, expectedError) in expected {
            let mapped = LyricsLibraryError.mapStoreError(dataError)
            #expect(mapped == expectedError, "映射不符：\(dataError) → \(mapped)")
            #expect(!mapped.message.isEmpty)
            #expect(containsCJK(mapped.message), "中文说明缺失：\(mapped.message)")
            #expect(!mapped.message.contains("ShinAppleDataError"))
        }
    }

    @Test("恢复建议分类：每个 case 有明确、可操作的分类")
    func recoveryHintsAreTotal() {
        let hints: [(ShinAppleDataError, LyricsRecoveryHint)] = [
            (.revisionConflict(documentId: MappedCases.id, storedRevision: 2, submittedRevision: 1),
             .reloadLatest),
            (.storageUnavailable("演练细节"), .checkStorageAndBackup),
            (.invalidDocument([]), .fixInput),
            (.invalidRevision(documentId: MappedCases.id, revision: 0), .fixInput),
            (.invalidBinding("关联非法"), .fixInput),
            (.invalidSettingKey("演练键"), .fixInput),
            (.documentNotFound(MappedCases.id), .refreshState),
            (.documentInUse(documentId: MappedCases.id, affectedBindingCount: 2), .resolveReferences),
            (.invalidBackup(.tooLarge(bytes: 9, limit: 5)), .fixBackup)
        ]
        #expect(hints.count == MappedCases.all.count, "样例集必须覆盖全部 case")
        for (dataError, expectedHint) in hints {
            #expect(
                ShinDataFaultPresentation.recoveryHint(for: dataError) == expectedHint,
                "分类不符：\(dataError)"
            )
            // 统一呈现的 message 与分类同源（非空、中文）。
            let message = ShinDataFaultPresentation.message(for: dataError)
            #expect(!message.isEmpty)
            #expect(containsCJK(message))
        }
    }

    @Test("备份损坏：经服务层映射后仍保留 parse 的类型化拒绝原因")
    func backupRejectionReasonSurvivesServiceMapping() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = LyricsLibraryService(store: store)

        // 半截/非法 JSON 备份：invalidJSON 拒绝。
        let garbage = Data("这不是 JSON 的备份内容（故障夹具）".utf8)
        do {
            _ = try service.parseBackup(garbage)
            Issue.record("非法备份应当被拒绝")
        } catch let error as LyricsLibraryError {
            guard case let .storeRejection(detail) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(detail.contains("备份文件未通过校验"))
            #expect(detail.contains("JSON"))
            #expect(!error.message.contains("BackupRejection"))
        }

        // 未来 schema 版本：拒绝并说明版本（原库不变）。
        let futureVersion = Data("""
        {"schemaVersion": 99, "exportedAt": "2026-01-01T00:00:00Z", \
        "documents": [], "bindings": [], "settings": {}}
        """.utf8)
        do {
            _ = try service.parseBackup(futureVersion)
            Issue.record("未来版本备份应当被拒绝")
        } catch let error as LyricsLibraryError {
            guard case let .storeRejection(detail) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(detail.contains("99"))
            #expect(try await store.currentSnapshot().documents.isEmpty, "解析拒绝不得改动原库")
        }
    }
}

@Suite("冲突恢复流程")
struct ConflictRecoveryLoopTests {

    @Test("编辑提交冲突 → 载入库中最新版本 → 再提交成功（草稿不静默覆盖库）")
    func editConflictReloadResubmitSucceeds() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        // rev1 入库并绑定到 trackA（模拟编辑器打开前的库状态）。
        let document = try await Fixture.seedOldDocument(in: store)
        #expect(document.revision == 1)
        let firstLineId = document.lines[0].id

        let editor = LyricsEditingService(store: store)
        _ = try await editor.openEditor(documentId: document.id)
        _ = try await editor.setLineText(lineId: firstLineId, text: "本地草稿修改测试文本")

        // 并发窗口直接提交 rev2（模拟另一窗口已保存更新版本）。
        var concurrent = document
        concurrent.revision = 2
        concurrent.lines[1].text = "另一窗口测试文本"
        try await store.save(
            document: concurrent,
            binding: SongBinding(
                track: Fixture.trackA,
                lyricDocumentId: concurrent.id,
                userDelayMs: 250
            )
        )

        // 本编辑器仍提交 rev2 → 类型化冲突（stored 2 / submitted 2），不覆盖。
        do {
            _ = try await editor.commitChanges()
            Issue.record("过期提交应当冲突")
        } catch let error as LyricsEditingError {
            guard case let .revisionConflict(documentId, stored, submitted) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(documentId == document.id)
            #expect(stored == 2)
            #expect(submitted == 2)
        }
        // 冲突后草稿保留（可重试/放弃），库中仍是并发窗口的 rev2。
        let draft = await editor.currentSnapshot()
        #expect(draft?.hasUnsavedChanges == true)
        #expect(draft?.lines.first { $0.id == firstLineId }?.text == "本地草稿修改测试文本")
        #expect(try await store.document(id: document.id)?.revision == 2)

        // 恢复路径「载入库中最新版本」（App 层 = 关闭会话后按原文档重开）。
        await editor.closeEditor()
        let reloaded = try await editor.openEditor(documentId: document.id)
        #expect(reloaded.baseRevision == 2)

        // 重新应用同类修改并提交 → 成功，rev3 落库。
        _ = try await editor.setLineText(lineId: firstLineId, text: "重新应用修改测试文本")
        let committed = try await editor.commitChanges()
        #expect(committed.baseRevision == 3)
        let storedAfter = try await store.document(id: document.id)
        #expect(storedAfter?.revision == 3)
        #expect(storedAfter?.lines.first { $0.id == firstLineId }?.text == "重新应用修改测试文本")
        // 绑定全程未丢。
        #expect(try await store.binding(for: Fixture.trackA) != nil)
    }
}
