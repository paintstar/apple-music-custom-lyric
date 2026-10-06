import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 文档级写入通道 updateDocument：
// - 无绑定文档也能更新（解除编辑/导出流程对绑定的依赖）；
// - revision 乐观并发与 save 同规则：过期提交抛类型化冲突，绝不静默覆盖；
// - 文档不存在抛 documentNotFound；绑定字段不受文档更新影响。

@Suite("文档级写入通道")
struct DocumentUpdateTests {

    @Test("无绑定文档更新成功：revision +1，内容落盘，绑定仍为空")
    func unboundDocumentUpdateSucceeds() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))
        try await store.deleteBinding(for: Fixture.trackA)

        var updated = document
        updated.revision = document.revision + 1
        updated.lines[0].text = "更新后的第一句测试文本"
        updated.updatedAt = LyricTimestamp.string(from: Fixture.fixedDate.addingTimeInterval(60))
        try await store.updateDocument(updated)

        let stored = try await store.document(id: document.id)
        #expect(stored == updated)
        #expect(stored?.lines[0].text == "更新后的第一句测试文本")
        #expect(try await store.bindings(referencing: document.id).isEmpty)
    }

    @Test("revision 冲突：非 stored + 1 的提交被类型化拒绝，原库不变")
    func revisionConflictRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        // 相同 revision（应为 stored + 1）。
        var stale = document
        stale.lines[1].text = "过期提交测试文本"
        do {
            try await store.updateDocument(stale)
            Issue.record("相同 revision 提交应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .revisionConflict(
                documentId: document.id,
                storedRevision: document.revision,
                submittedRevision: document.revision
            ))
        }
        // 跳版提交（stored + 2）同样拒绝。
        var skipping = document
        skipping.revision = document.revision + 2
        do {
            try await store.updateDocument(skipping)
            Issue.record("跳版提交应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .revisionConflict(
                documentId: document.id,
                storedRevision: document.revision,
                submittedRevision: document.revision + 2
            ))
        }
        // 原库未被覆盖。
        let stored = try await store.document(id: document.id)
        #expect(stored == document)
    }

    @Test("文档不存在：抛 documentNotFound，不新建行")
    func missingDocumentRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        var document = Fixture.documentA()
        document.revision = 7
        do {
            try await store.updateDocument(document)
            Issue.record("不存在的文档应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .documentNotFound(document.id))
        }
        #expect(try await store.allDocuments().isEmpty)
    }

    @Test("有绑定的文档更新：绑定字段逐字段保持不变")
    func boundDocumentUpdateKeepsBindings() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: document)
        try await store.save(document: document, binding: binding)

        var updated = document
        updated.revision = document.revision + 1
        try await store.updateDocument(updated)

        let bindings = try await store.bindings(referencing: document.id)
        #expect(bindings == [binding])
        #expect(bindings[0].userDelayMs == binding.userDelayMs)
        #expect(bindings[0].titleHint == binding.titleHint)
    }

    @Test("schema 非法或 revision < 1 的文档被拒绝")
    func invalidDocumentsRejected() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        // 重复 line.id：schema 校验拒绝。
        var duplicate = document
        duplicate.revision = document.revision + 1
        duplicate.lines[1].id = duplicate.lines[0].id
        do {
            try await store.updateDocument(duplicate)
            Issue.record("schema 非法文档应当被拒绝")
        } catch let error as ShinAppleDataError {
            guard case .invalidDocument = error else {
                Issue.record("期望 invalidDocument，实际：\(error)")
                return
            }
        }
        // revision < 1：直接拒绝。
        var zero = document
        zero.revision = 0
        do {
            try await store.updateDocument(zero)
            Issue.record("revision < 1 应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .invalidRevision(documentId: document.id, revision: 0))
        }
        // 原库未被覆盖。
        #expect(try await store.document(id: document.id) == document)
    }
}
