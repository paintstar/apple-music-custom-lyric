import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppServices

// 无绑定文档的编辑保存：store 层提供文档级写入通道
// updateDocument 后，LyricsEditingService 解除「无绑定文档不可提交」的
// v1 限制。独立成文件以保持 LyricsEditingServiceTests 聚焦既有行为。

@Suite("无绑定文档保存")
struct LyricsEditingUnboundDocumentTests {

    @Test("无绑定文档保存：经文档级通道保存成功，revision 正常递增")
    func unboundDocumentCommit() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await LyricsEditingServiceTests.EditFixture.seedEditableDocument(in: store)
        try await store.deleteBinding(for: Fixture.trackA)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        _ = try await service.setLineText(lineId: document.lines[0].id, text: "无关联保存测试")

        // 解除绑定后仍可保存（store.updateDocument 通道），revision 正常递增。
        let committed = try await service.commitChanges()
        #expect(committed.hasUnsavedChanges == false)
        #expect(committed.baseRevision == 2)
        let stored = try await store.document(id: document.id)
        #expect(stored?.revision == 2)
        #expect(stored?.lines.first { $0.id == document.lines[0].id }?.text == "无关联保存测试")
        #expect(try await store.bindings(referencing: document.id).isEmpty)
    }
}
