import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

@Suite("自动写入的事务保护")
struct ConditionalWritesTests {
    private final class Validity: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(allowChecks: Int) { remaining = allowChecks }
        func check() -> Bool {
            lock.withLock {
                defer { remaining -= 1 }
                return remaining > 0
            }
        }
    }

    @Test("自动导入不能替换等待期间新增的人工绑定，也不能留下孤立文档")
    func existingBindingWins() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let manual = Fixture.documentA(revision: 1)
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: manual.id)
        try await store.save(document: manual, binding: binding)
        let incoming = Fixture.documentA(revision: 1)
        let saved = try await store.saveIfUnbound(
            document: incoming, binding: SongBinding(track: Fixture.trackA, lyricDocumentId: incoming.id)
        )
        #expect(!saved)
        #expect(try await store.binding(for: Fixture.trackA) == binding)
        #expect(try await store.allDocuments() == [manual])
    }

    @Test("运行失效时拒绝写入；在事务末尾失效时已写内容也整体回滚")
    func invalidRunRollsBack() async throws {
        for checks in [0, 1] {
            let directory = try TestEnv.makeTempDirectory()
            defer { TestEnv.cleanup(directory) }
            let store = try TestEnv.makeStore(directory)
            let document = Fixture.documentA(revision: 1)
            let valid = Validity(allowChecks: checks)
            await #expect(throws: CancellationError.self) {
                _ = try await store.saveIfUnbound(
                    document: document,
                    binding: SongBinding(track: Fixture.trackA, lyricDocumentId: document.id),
                    isValid: { valid.check() }
                )
            }
            #expect(try await store.allDocuments().isEmpty)
            #expect(try await store.allBindings().isEmpty)
        }
    }

    @Test("删除前发生人工编辑时，事务内 revision 检查保留文档和绑定")
    func editedDocumentSurvives() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let original = Fixture.documentA(revision: 1)
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: original.id)
        try await store.save(document: original, binding: binding)
        var edited = original
        edited.revision += 1
        edited.lines[0].text = "人工改过的原创测试文本"
        try await store.updateDocument(edited)
        let deleted = try await store.deleteDocumentIfUnchanged(
            binding: binding, revision: original.revision, isValid: { true }, shouldDelete: { _ in true }
        )
        #expect(!deleted)
        #expect(try await store.document(id: original.id) == edited)
        #expect(try await store.binding(for: Fixture.trackA) == binding)
    }

    @Test("删除事务重验人工保护；共享文档和变化后的绑定均保留")
    func protectionAndBindingAreRechecked() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let document = Fixture.documentA(revision: 1)
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let protected = try await store.deleteDocumentIfUnchanged(
            binding: binding, revision: document.revision, isValid: { true }, shouldDelete: { _ in false }
        )
        #expect(!protected)
        try await store.updateBinding(SongBinding(track: Fixture.trackB, lyricDocumentId: document.id))
        let shared = try await store.deleteDocumentIfUnchanged(
            binding: binding, revision: document.revision, isValid: { true }, shouldDelete: { _ in true }
        )
        #expect(!shared)
        var changedBinding = binding
        changedBinding.userDelayMs = 250
        try await store.updateBinding(changedBinding)
        let changed = try await store.deleteDocumentIfUnchanged(
            binding: binding, revision: document.revision, isValid: { true }, shouldDelete: { _ in true }
        )
        #expect(!changed)
        #expect(try await store.document(id: document.id) == document)
        #expect(try await store.binding(for: Fixture.trackA) == changedBinding)
    }

    @Test("合法删除同步清理唯一绑定；失效删除回滚，不触碰旧资料")
    func deletionRollbackAndSuccess() async throws {
        let directory = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(directory) }
        let store = try TestEnv.makeStore(directory)
        let document = Fixture.documentA(revision: 1)
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let valid = Validity(allowChecks: 1)
        await #expect(throws: CancellationError.self) {
            _ = try await store.deleteDocumentIfUnchanged(
                binding: binding, revision: document.revision,
                isValid: { valid.check() }, shouldDelete: { _ in true }
            )
        }
        #expect(try await store.document(id: document.id) == document)
        #expect(try await store.binding(for: Fixture.trackA) == binding)
        let deleted = try await store.deleteDocumentIfUnchanged(
            binding: binding, revision: document.revision, isValid: { true }, shouldDelete: { _ in true }
        )
        #expect(deleted)
        #expect(try await store.allDocuments().isEmpty)
        #expect(try await store.allBindings().isEmpty)
    }
}
