import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// 存储测试：保存→重开连接→读回一致；换歌→回原歌；
// 重新导入替换关联但保留旧文档；解除绑定保留文档；删除共享文档的
// 受影响绑定确认接口；设置读写。

@Suite("仓库基础行为")
struct RepositoryTests {

    @Test("保存后用全新连接重开，读回完全一致（持久性）")
    func saveReopenReadBack() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }

        let store1 = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: document)
        try await store1.save(document: document, binding: binding)
        try await store1.setSettingValue("mock", forKey: "playback.mode")

        // 进程内重开连接（模拟 App 刷新/重启后的恢复）。
        let store2 = try TestEnv.makeStore(dir)
        let readDocument = try await store2.document(for: Fixture.trackA)
        #expect(readDocument == document)
        let readBinding = try await store2.binding(for: Fixture.trackA)
        #expect(readBinding == binding)
        #expect(try await store2.document(id: document.id) == document)
        #expect(try await store2.allDocuments() == [document])
        #expect(try await store2.allBindings() == [binding])
        #expect(try await store2.settingValue(forKey: "playback.mode") == "mock")
    }

    @Test("未绑定的曲目读取返回 nil，而不是错误")
    func unknownTrackReturnsNil() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        #expect(try await store.document(for: Fixture.trackA) == nil)
        #expect(try await store.binding(for: Fixture.trackA) == nil)
        #expect(try await store.document(id: UUID()) == nil)
    }

    @Test("换歌后再回到原歌：两首歌的文档与延迟互不干扰")
    func switchTrackAndBack() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let docA = Fixture.documentA()
        let docB = Fixture.textDocument()
        try await store.save(document: docA, binding: Fixture.binding(Fixture.trackA, to: docA, delayMs: 500))
        try await store.save(document: docB, binding: Fixture.binding(Fixture.trackB, to: docB, delayMs: -200))

        // 播放 B 之后回到 A：A 的歌词与延迟必须原样恢复。
        #expect(try await store.document(for: Fixture.trackB) == docB)
        #expect(try await store.document(for: Fixture.trackA) == docA)
        #expect(try await store.binding(for: Fixture.trackA)?.userDelayMs == 500)
        #expect(try await store.binding(for: Fixture.trackB)?.userDelayMs == -200)
    }

    @Test("同一首歌重新导入：创建新文档并替换关联，旧文档不删除")
    func reimportReplacesBindingKeepsOldDocument() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let oldDocument = Fixture.documentA()
        try await store.save(document: oldDocument, binding: Fixture.binding(Fixture.trackA, to: oldDocument))

        let newDocument = Fixture.documentA(revision: 1)
        #expect(newDocument.id != oldDocument.id)
        // 冲突预览（确认界面的数据）：替换现有绑定 + 旧文档失去最后一个引用。
        let preview = try await store.reimportPreview(
            incomingDocument: newDocument,
            binding: Fixture.binding(Fixture.trackA, to: newDocument)
        )
        #expect(preview.replacedBinding?.lyricDocumentId == oldDocument.id)
        #expect(preview.documentsLosingLastBinding == [oldDocument])

        // 用户确认后保存：关联指向新文档；旧文档仍在库中，可查、可导出。
        try await store.save(document: newDocument, binding: Fixture.binding(Fixture.trackA, to: newDocument))
        #expect(try await store.document(for: Fixture.trackA) == newDocument)
        #expect(try await store.document(id: oldDocument.id) == oldDocument)
        #expect(try await store.bindings(referencing: oldDocument.id).isEmpty)
    }

    @Test("重新导入取消（不保存）：库里什么都不变")
    func reimportCancelKeepsEverything() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let oldDocument = Fixture.documentA()
        try await store.save(document: oldDocument, binding: Fixture.binding(Fixture.trackA, to: oldDocument))
        let before = try await store.currentSnapshot()

        // 用户在确认界面点了取消：不调用 save，仅生成过预览。
        let newDocument = Fixture.documentA()
        _ = try await store.reimportPreview(incomingDocument: newDocument, binding: Fixture.binding(Fixture.trackA, to: newDocument))

        #expect(try await store.currentSnapshot() == before)
        #expect(try await store.document(for: Fixture.trackA) == oldDocument)
    }

    @Test("解除绑定保留文档；旧文档被共享时不丢最后一个引用")
    func deleteBindingKeepsDocument() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let document = Fixture.documentA()
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document))

        try await store.deleteBinding(for: Fixture.trackA)
        #expect(try await store.binding(for: Fixture.trackA) == nil)
        #expect(try await store.document(for: Fixture.trackA) == nil)
        #expect(try await store.document(id: document.id) == document)

        // 幂等：再次解除不报错。
        try await store.deleteBinding(for: Fixture.trackA)
    }

    @Test("删除共享文档：先列出受影响绑定，确认后一并删除，不产生悬空引用")
    func deleteSharedDocumentRequiresConfirmation() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        // 同一份歌词文档被两首曲目共享（各自保存自己的偏移）。
        let shared = Fixture.documentA()
        try await store.save(document: shared, binding: Fixture.binding(Fixture.trackA, to: shared, delayMs: 0))
        try await store.updateBinding(Fixture.binding(Fixture.trackB, to: shared, delayMs: 1_000))

        // 受影响绑定确认接口。
        let affected = try await store.bindings(referencing: shared.id)
        #expect(affected.count == 2)

        // 未确认（默认不允许级联）：拒绝删除，数据原样。
        await #expect(throws: ShinAppleDataError.self) {
            try await store.deleteDocument(id: shared.id, deletingAffectedBindings: false)
        }
        #expect(try await store.document(id: shared.id) == shared)

        // 确认后：绑定与文档一起删除。
        try await store.deleteDocument(id: shared.id, deletingAffectedBindings: true)
        #expect(try await store.document(id: shared.id) == nil)
        #expect(try await store.binding(for: Fixture.trackA) == nil)
        #expect(try await store.binding(for: Fixture.trackB) == nil)
    }

    @Test("删除不存在的文档：documentNotFound")
    func deleteMissingDocumentThrows() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let missing = UUID()
        do {
            try await store.deleteDocument(id: missing, deletingAffectedBindings: false)
            Issue.record("应当抛出 documentNotFound")
        } catch let error as ShinAppleDataError {
            #expect(error == .documentNotFound(missing))
        }
    }

    @Test("设置读写：写入、覆盖、删除、未知键")
    func settingsRoundTrip() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        #expect(try await store.settingValue(forKey: "ui.language") == nil)
        try await store.setSettingValue("zh-Hans", forKey: "ui.language")
        try await store.setSettingValue("en", forKey: "ui.language")
        #expect(try await store.settingValue(forKey: "ui.language") == "en")
        #expect(try await store.allSettings() == ["ui.language": "en"])
        try await store.removeSetting(forKey: "ui.language")
        #expect(try await store.settingValue(forKey: "ui.language") == nil)

        do {
            try await store.setSettingValue("x", forKey: "")
            Issue.record("空设置键应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .invalidSettingKey("设置键不能为空"))
        }
    }

    @Test("updateBinding：调整延迟不改动文档 revision；指向不存在的文档被拒绝")
    func updateBindingSemantics() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let document = Fixture.documentA(revision: 2)
        try await store.save(document: document, binding: Fixture.binding(Fixture.trackA, to: document, delayMs: 0))

        let adjusted = Fixture.binding(Fixture.trackA, to: document, delayMs: 1_500)
        try await store.updateBinding(adjusted)
        #expect(try await store.binding(for: Fixture.trackA)?.userDelayMs == 1_500)
        // 文档 revision 未被绑定更新触碰。
        #expect(try await store.document(for: Fixture.trackA)?.revision == 2)

        let dangling = SongBinding(
            track: Fixture.trackA,
            lyricDocumentId: UUID(),
            userDelayMs: 0
        )
        do {
            try await store.updateBinding(dangling)
            Issue.record("指向不存在文档的绑定应当被拒绝")
        } catch let error as ShinAppleDataError {
            #expect(error == .documentNotFound(dangling.lyricDocumentId))
        }
    }
}
