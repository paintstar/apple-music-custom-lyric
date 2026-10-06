import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 关联查询服务测试：空态判定、解除关联保留文档、
// 以及「绝不按歌名关联」的边界（同名不同目录身份互不影响）。

@Suite("歌词关联查询")
struct LyricsAssociationServiceTests {

    @Test("三种空态：无绑定 / 有绑定但全未打轴 / 正常")
    func associationStates() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let association = LyricsAssociationService(store: store)

        // 1) 无绑定。
        #expect(try await association.associationState(for: Fixture.trackA) == .unbound)

        // 2) 有绑定但全部未打轴。
        try await Fixture.seedUntimedDocument(in: store, track: Fixture.trackA)
        if case let .untimedOnly(document) = try await association.associationState(for: Fixture.trackA) {
            #expect(document.lines.allSatisfy { $0.startMs == nil })
            #expect(document.lines.count == 2)
        } else {
            Issue.record("全未打轴应为 untimedOnly 状态")
        }

        // 3) 正常（至少一行已打轴）。
        let timedDocument = LyricDocument(
            sourceFormat: .lrc,
            lines: [
                LyricLine(startMs: 1_000, text: "第一句测试文本"),
                LyricLine(startMs: nil, text: "未打轴补记测试文本")
            ]
        )
        try await store.save(
            document: timedDocument,
            binding: SongBinding(
                track: Fixture.trackB, lyricDocumentId: timedDocument.id, userDelayMs: 300
            )
        )
        if case let .available(document, binding) = try await association.associationState(for: Fixture.trackB) {
            #expect(document.id == timedDocument.id)
            #expect(binding.userDelayMs == 300)
        } else {
            Issue.record("已打轴文档应为 available 状态")
        }
    }

    @Test("解除关联保留文档；重复解除为幂等 no-op")
    func deleteBindingKeepsDocument() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let association = LyricsAssociationService(store: store)
        let oldDocument = try await Fixture.seedOldDocument(in: store)

        try await association.deleteBinding(for: Fixture.trackA)
        #expect(try await association.associationState(for: Fixture.trackA) == .unbound)
        // 文档仍在库中：解除关联不删除文档。
        #expect(try await store.document(id: oldDocument.id)?.id == oldDocument.id)

        // 幂等：再次解除不报错、无变化。
        try await association.deleteBinding(for: Fixture.trackA)
        #expect(try await store.allDocuments().count == 1)
    }

    @Test("同名不同目录身份不共享关联：绝不按歌名查询")
    func sameTitleDifferentIdentityNeverShares() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let association = LyricsAssociationService(store: store)
        try await Fixture.seedOldDocument(in: store, track: Fixture.trackA)

        // 只有目录身份一致才可见；同名不同 ID 的歌曲仍是未绑定。
        #expect(try await association.associationState(for: Fixture.trackA) != .unbound)
        #expect(
            try await association.associationState(for: Fixture.trackSameTitleDifferentId) == .unbound
        )
    }
}
