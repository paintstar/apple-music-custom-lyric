import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

@Suite("歌词资源删除服务")
struct ResourceDeletionServiceTests {
    @Test("用户解除关联删除最后一份本地歌词，低级解绑仍保留原用途")
    func associationDeletion() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let document = try await Fixture.seedOldDocument(in: store)
        let service = LyricsAssociationService(store: store)
        let deleted = try await service.deleteAssociation(
            forTrackKey: SongBinding.trackKey(for: Fixture.trackA),
            expectedDocumentId: document.id, expectedRevision: document.revision
        )
        #expect(deleted)
        #expect(try await service.associationState(for: Fixture.trackA) == .unbound)
        #expect(try await store.document(id: document.id) == nil)
    }

    @Test("缓存资源按概览删除文档及全部关联，返回受影响歌曲")
    func libraryDeletionUsesPreview() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let first = try await Fixture.seedOldDocument(in: store)
        let second = try await Fixture.seedOldDocument(in: store, track: Fixture.trackB)
        let third = try await Fixture.seedOldDocument(in: store, track: Fixture.trackC)
        try await store.deleteBinding(for: Fixture.trackB)
        let service = LyricsLibraryService(store: store)
        let items = try await service.libraryOverview().filter { $0.documentId != third.id }
        #expect(Set(items.map(\.documentId)) == Set([first.id, second.id]))
        let deleted = try await service.deleteDocuments(items)
        #expect(deleted.map(\.trackKey) == [SongBinding.trackKey(for: Fixture.trackA)])
        #expect(try await store.allDocuments() == [third])
        #expect(try await service.deleteDocuments([]).isEmpty)
    }

    @Test("概览后新增关联或编辑时服务报错且保留整批资料", arguments: [false, true])
    func staleOverviewRejected(edit: Bool) async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        _ = try await Fixture.seedOldDocument(in: store)
        let second = try await Fixture.seedOldDocument(in: store, track: Fixture.trackB)
        let service = LyricsLibraryService(store: store)
        let preview = try await service.libraryOverview()
        if edit {
            var updated = second
            updated.revision += 1
            updated.lines[0].text = "人工调整后的原创测试文本"
            try await store.updateDocument(updated)
        } else {
            try await store.updateBinding(SongBinding(track: Fixture.trackC, lyricDocumentId: second.id))
        }
        let before = try await store.currentSnapshot()
        await #expect(throws: LyricsLibraryError.self) {
            _ = try await service.deleteDocuments(preview)
        }
        #expect(try await store.currentSnapshot() == before)
    }
}
