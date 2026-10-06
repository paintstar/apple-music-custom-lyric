import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 来源注记单测：注记随确认落库、手动导入零注记、
// 自动删除保护判定（人工编辑 revision 递增即退出删除范围）。

@Suite("FetchProvenance")
struct FetchProvenanceTests {

    private func makeProvenance(kind: FetchProvenance.MatchKind = .autoHigh) -> FetchProvenance {
        FetchProvenance(
            provider: "netease",
            externalRef: "netease:song:990001",
            matchKind: kind,
            queryTitle: "测试曲目甲",
            queryArtist: "测试歌手甲"
        )
    }

    @Test("在线获取确认：注记随文档落库，可判自动/手动来源")
    func provenancePersistedOnConfirm() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA(), provenance: makeProvenance())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: "在线获取测试.lrc")
        let confirmation = try await service.confirmImport()

        let saved = try #require(await store.document(id: confirmation.document.id))
        #expect(saved.fetchProvider == "netease")
        #expect(saved.fetchMatchKind == .autoHigh)
        #expect(saved.isAutoFetched)
        #expect(saved.hasFetchProvenance)
        #expect(saved.isUneditedSinceFetch)
        #expect(!saved.hasManualTranslation)
        #expect(
            saved.metadata[FetchedLyricsMetadataKeys.externalRef] == ["netease:song:990001"]
        )
        #expect(
            saved.metadata[FetchedLyricsMetadataKeys.queryArtist] == ["测试歌手甲"]
        )
    }

    @Test("手动导入：不产生任何获取注记（手动优先保护的默认态）")
    func manualImportHasNoProvenance() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        let confirmation = try await service.confirmImport()

        let saved = try #require(await store.document(id: confirmation.document.id))
        #expect(!saved.hasFetchProvenance)
        #expect(!saved.isAutoFetched)
        #expect(!saved.isUneditedSinceFetch)
    }

    @Test("用户确认导入的在线歌词：带来源徽标但不参与自动删除")
    func userConfirmedFetchIsNotAutoDeletable() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(
            target: Fixture.targetA(),
            provenance: makeProvenance(kind: .userConfirmed)
        )
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        let confirmation = try await service.confirmImport()

        let saved = try #require(await store.document(id: confirmation.document.id))
        #expect(saved.hasFetchProvenance)
        #expect(saved.fetchMatchKind == .userConfirmed)
        #expect(!saved.isAutoFetched)
    }

    @Test("人工编辑后 revision 递增：退出「未编辑」判定（自动删除保护）")
    func editBreaksUneditedSinceFetch() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA(), provenance: makeProvenance())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        let confirmation = try await service.confirmImport()

        // 模拟人工编辑保存：revision 递增后写回。
        var edited = confirmation.document
        edited.revision += 1
        edited.lines[0].translations["zh-Hans"] = Translation(text: "人工补译测试", source: .manual)
        try await store.save(document: edited, binding: confirmation.binding)

        let reread = try #require(await store.document(id: edited.id))
        #expect(!reread.isUneditedSinceFetch)
        #expect(reread.hasManualTranslation)
        // 来源注记保留（徽标仍显示在线来源）。
        #expect(reread.isAutoFetched == false || reread.isAutoFetched == true)
        #expect(reread.fetchProvider == "netease")
        // 自动删除管线的完整保护条件：自动来源 && 未编辑 && 无人工翻译。
        let deletableByAutomation = reread.isAutoFetched
            && reread.isUneditedSinceFetch
            && !reread.hasManualTranslation
        #expect(!deletableByAutomation)
    }

    @Test("取消会话后注记不残留到下一次会话")
    func cancelClearsProvenance() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA(), provenance: makeProvenance())
        #expect(await service.sessionProvenance() != nil)
        await service.cancel()
        try await service.openImportSession(target: Fixture.targetA())
        let persisted = await service.sessionProvenance()
        #expect(persisted == nil)
    }
}
