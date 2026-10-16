import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

@Suite("用户删除本地歌词资源")
struct ResourceDeletionTests {
    @Test("最后一个关联解除时删除歌词和译文，重复解除无变化")
    func deleteLastAssociation() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let document = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: document)
        try await store.save(document: document, binding: binding)
        #expect(!document.lines[0].translations.isEmpty)
        let deleted = try await store.deleteAssociation(
            forTrackKey: binding.trackKey, expectedDocumentId: document.id, expectedRevision: document.revision
        )
        #expect(deleted)
        #expect(try await store.document(id: document.id) == nil)
        #expect(try await store.allBindings().isEmpty)
        #expect(try await store.currentSnapshot().documents.isEmpty)
        let repeated = try await store.deleteAssociation(
            forTrackKey: binding.trackKey, expectedDocumentId: document.id, expectedRevision: document.revision
        )
        #expect(!repeated)
    }

    @Test("共享歌词只移除当前关联，最后一个关联解除才删文档")
    func sharedDocumentSurvives() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let document = Fixture.documentA()
        let bindingA = Fixture.binding(Fixture.trackA, to: document)
        let bindingB = Fixture.binding(Fixture.trackB, to: document)
        try await store.save(document: document, binding: bindingA)
        try await store.updateBinding(bindingB)
        let deleted = try await store.deleteAssociation(
            forTrackKey: bindingA.trackKey, expectedDocumentId: document.id, expectedRevision: document.revision
        )
        #expect(!deleted)
        #expect(try await store.binding(for: Fixture.trackA) == nil)
        #expect(try await store.binding(for: Fixture.trackB) == bindingB)
        #expect(try await store.document(id: document.id) == document)
        let lastDeleted = try await store.deleteAssociation(
            forTrackKey: bindingB.trackKey, expectedDocumentId: document.id, expectedRevision: document.revision
        )
        #expect(lastDeleted)
        #expect(try await store.allDocuments().isEmpty)
    }

    @Test("编辑或换绑后旧解除请求不能删除新内容", arguments: [false, true])
    func staleAssociationCannotDelete(rebind: Bool) async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let document = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: document)
        try await store.save(document: document, binding: binding)
        if rebind {
            let replacement = Fixture.textDocument()
            try await store.save(document: replacement, binding: Fixture.binding(Fixture.trackA, to: replacement))
        } else {
            var edited = document
            edited.revision += 1
            edited.lines[0].text = "人工修改后的原创文本"
            try await store.updateDocument(edited)
        }
        let before = try await store.currentSnapshot()
        await #expect(throws: ShinAppleDataError.self) {
            _ = try await store.deleteAssociation(
                forTrackKey: binding.trackKey, expectedDocumentId: document.id, expectedRevision: document.revision
            )
        }
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("批量删除共享与未关联文档及译文，保留目标外资料")
    func batchDeletion() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let shared = Fixture.documentA()
        let orphan = Fixture.textDocument()
        let retained = Fixture.textDocument()
        let bindingA = Fixture.binding(Fixture.trackA, to: shared)
        let bindingB = Fixture.binding(Fixture.trackB, to: shared)
        let bindingC = Fixture.binding(Fixture.trackC, to: retained)
        try await store.save(document: shared, binding: bindingA)
        try await store.updateBinding(bindingB)
        try await store.save(document: orphan, binding: Fixture.binding(Fixture.trackC, to: orphan))
        try await store.save(document: retained, binding: bindingC)
        let deleted = try await store.deleteDocumentsIfUnchanged([
            request(shared, bindings: [bindingB, bindingA]), request(orphan, bindings: [])
        ])
        #expect(deleted == [bindingA, bindingB].sorted { $0.trackKey < $1.trackKey })
        #expect(try await store.allDocuments() == [retained])
        #expect(try await store.allBindings() == [bindingC])
        #expect(try await store.deleteDocumentsIfUnchanged([]).isEmpty)
    }

    @Test("批量删除的过期版本、新增关联或目标消失均整批回滚", arguments: ["revision", "binding", "missing"])
    func changedPreviewRollsBack(change: String) async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let first = Fixture.documentA()
        let second = Fixture.textDocument()
        let bindingA = Fixture.binding(Fixture.trackA, to: first)
        let bindingB = Fixture.binding(Fixture.trackB, to: second)
        try await store.save(document: first, binding: bindingA)
        try await store.save(document: second, binding: bindingB)
        let requests = [request(first, bindings: [bindingA]), request(second, bindings: [bindingB])]
        switch change {
        case "revision":
            var edited = second
            edited.revision += 1
            try await store.updateDocument(edited)
        case "binding":
            try await store.updateBinding(Fixture.binding(Fixture.trackC, to: second))
        default:
            try await store.deleteDocument(id: second.id, deletingAffectedBindings: true)
        }
        let before = try await store.currentSnapshot()
        await #expect(throws: ShinAppleDataError.self) {
            _ = try await store.deleteDocumentsIfUnchanged(requests)
        }
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("重复文档、重复曲目及非法输入拒绝且不改库")
    func invalidDeletionRequests() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let document = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: document)
        try await store.save(document: document, binding: binding)
        let valid = request(document, bindings: [binding])
        let before = try await store.currentSnapshot()
        for requests in [
            [valid, valid],
            [LyricsDocumentDeletionRequest(documentId: document.id, revision: document.revision,
                                          trackKeys: [binding.trackKey, binding.trackKey])],
            [LyricsDocumentDeletionRequest(documentId: document.id, revision: document.revision, trackKeys: ["invalid"])],
            [LyricsDocumentDeletionRequest(documentId: document.id, revision: 0, trackKeys: [binding.trackKey])]
        ] {
            await #expect(throws: ShinAppleDataError.self) {
                _ = try await store.deleteDocumentsIfUnchanged(requests)
            }
            #expect(try await store.currentSnapshot() == before)
        }
    }

    @Test("真实数据库删除失败时文档、绑定和其他设置全部保留")
    func storageFailureRollsBack() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let first = Fixture.documentA()
        let second = Fixture.textDocument()
        let bindingA = Fixture.binding(Fixture.trackA, to: first)
        let bindingB = Fixture.binding(Fixture.trackB, to: second)
        try await store.save(document: first, binding: bindingA)
        try await store.save(document: second, binding: bindingB)
        try await store.setSettingValue("保留设置", forKey: "test.resource-retention")
        try await store.relocationSourcePool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_resource_deletion BEFORE DELETE ON lyricDocument
                WHEN OLD.id = '\(second.id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END
                """)
        }
        let before = try await store.currentSnapshot()
        do {
            _ = try await store.deleteDocumentsIfUnchanged([
                request(first, bindings: [bindingA]), request(second, bindings: [bindingB])
            ])
            Issue.record("应当上报数据库删除失败")
        } catch let error as ShinAppleDataError {
            guard case .storageUnavailable = error else {
                Issue.record("应当映射为 storageUnavailable")
                return
            }
        }
        #expect(try await store.currentSnapshot() == before)
        #expect(try await store.settingValue(forKey: "test.resource-retention") == "保留设置")
    }

    private func request(_ document: LyricDocument, bindings: [SongBinding]) -> LyricsDocumentDeletionRequest {
        LyricsDocumentDeletionRequest(
            documentId: document.id, revision: document.revision, trackKeys: bindings.map(\.trackKey)
        )
    }
}
