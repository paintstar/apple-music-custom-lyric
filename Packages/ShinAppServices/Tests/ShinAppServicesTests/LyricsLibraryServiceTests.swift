import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 本地歌词库管理服务测试：
// - libraryOverview 统计与提示；
// - 删除流程：受影响绑定清单 → 确认后单事务删除，不留悬空引用；
// - reassociate：换绑保留延迟、原文档保留、非法输入类型化拒绝；
// - 备份包装：export → parse → preview → import 全链路；
// - exportLRC：延迟解析规则（绑定延迟 / 显式覆盖 / 无绑定 0）。

@Suite("本地歌词库管理")
struct LyricsLibraryServiceTests {

    @Test("libraryOverview：行数/打轴统计/文件名/标题提示/绑定数与曲目提示")
    func overviewStatistics() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let docA = LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            originalFilename: "概览测试.lrc",
            metadata: ["ti": ["概览测试曲目"]],
            lines: [
                LyricLine(startMs: 1_000, text: "第一句测试文本"),
                LyricLine(startMs: nil, text: "未打轴测试文本")
            ]
        )
        let docB = LyricDocument(
            sourceFormat: .text,
            originalFilename: "纯文本概览.txt",
            lines: [LyricLine(startMs: nil, text: "纯文本第一行测试")]
        )
        try await store.save(
            document: docA,
            binding: SongBinding(
                track: Fixture.trackA, lyricDocumentId: docA.id,
                userDelayMs: 300, titleHint: "概览曲目甲"
            )
        )
        try await store.save(
            document: docB,
            binding: SongBinding(track: Fixture.trackB, lyricDocumentId: docB.id)
        )
        let service = LyricsLibraryService(store: store)
        let items = try await service.libraryOverview()
        #expect(items.count == 2)
        let itemA = try #require(items.first { $0.documentId == docA.id })
        #expect(itemA.originalFilename == "概览测试.lrc")
        #expect(itemA.titleHint == "概览测试曲目")
        #expect(itemA.lineCount == 2)
        #expect(itemA.timedLineCount == 1)
        #expect(itemA.untimedLineCount == 1)
        #expect(itemA.updatedAt == docA.updatedAt)
        #expect(itemA.bindingCount == 1)
        #expect(itemA.trackHints == ["概览曲目甲"])
        #expect(itemA.bindings.first?.userDelayMs == 300)
        let itemB = try #require(items.first { $0.documentId == docB.id })
        #expect(itemB.timedLineCount == 0)
        #expect(itemB.untimedLineCount == 1)
        #expect(itemB.titleHint == nil)
        #expect(itemB.trackHints.isEmpty)

        // 空库 → 空列表。
        let (empty, emptyDir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(emptyDir) }
        #expect(try await LyricsLibraryService(store: empty).libraryOverview().isEmpty)
    }

    @Test("删除流程：预览受影响绑定；确认后单事务删除文档与全部绑定，无悬空引用")
    func deletionFlowAtomic() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let docA = LyricDocument(
            sourceFormat: .lrc,
            lines: [LyricLine(startMs: 1_000, text: "第一句测试文本")]
        )
        let docB = LyricDocument(
            sourceFormat: .text,
            lines: [LyricLine(startMs: nil, text: "纯文本第一行测试")]
        )
        try await store.save(
            document: docA,
            binding: SongBinding(
                track: Fixture.trackA, lyricDocumentId: docA.id, userDelayMs: 300, titleHint: "提示甲"
            )
        )
        // 同一文档追加第二条绑定：revision 乐观并发要求 stored + 1。
        var docASecond = docA
        docASecond.revision = 2
        try await store.save(
            document: docASecond,
            binding: SongBinding(
                track: Fixture.trackB, lyricDocumentId: docA.id, userDelayMs: -150, titleHint: "提示乙"
            )
        )
        try await store.save(
            document: docB,
            binding: SongBinding(track: Fixture.trackC, lyricDocumentId: docB.id, titleHint: "提示丙")
        )
        let service = LyricsLibraryService(store: store)

        // 第一步：预览受影响绑定（复用 bindings(referencing:)）。
        let affected = try await service.affectedBindings(forDeletionOf: docA.id)
        #expect(affected.map(\.trackKey) == [Fixture.trackA, Fixture.trackB].map { SongBinding.trackKey(for: $0) })

        // 取消路径：不调用删除 → 库完全不变。
        #expect(try await store.document(id: docA.id)?.id == docA.id)
        #expect(try await store.allBindings().count == 3)

        // 第二步：确认删除 → 原子删除文档与全部绑定。
        let deleted = try await service.deleteDocument(id: docA.id)
        #expect(deleted.count == 2)
        #expect(try await store.document(id: docA.id) == nil)
        #expect(try await store.bindings(referencing: docA.id).isEmpty)

        // 不留悬空引用：每条剩余绑定的目标文档都存在。
        let remainingBindings = try await store.allBindings()
        #expect(remainingBindings.map(\.trackKey) == [SongBinding.trackKey(for: Fixture.trackC)])
        let remainingDocuments = try await store.allDocuments()
        #expect(remainingDocuments.map(\.id) == [docB.id])
        for binding in remainingBindings {
            #expect(remainingDocuments.contains { $0.id == binding.lyricDocumentId })
        }
    }

    @Test("删除不存在的文档抛 documentNotFound")
    func deleteMissingDocument() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = LyricsLibraryService(store: store)
        let missing = UUID()
        await #expect(throws: LyricsLibraryError.documentNotFound(missing)) {
            try await service.affectedBindings(forDeletionOf: missing)
        }
        await #expect(throws: LyricsLibraryError.documentNotFound(missing)) {
            try await service.deleteDocument(id: missing)
        }
    }

    @Test("reassociate：换绑保留延迟与提示，原文档保留，其他绑定不受影响")
    func reassociationKeepsOriginalDocument() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let docA = LyricDocument(
            sourceFormat: .lrc,
            lines: [LyricLine(startMs: 1_000, text: "第一句测试文本")]
        )
        let docB = LyricDocument(
            sourceFormat: .lrc,
            lines: [LyricLine(startMs: 5_000, text: "另一份测试文本")]
        )
        try await store.save(
            document: docA,
            binding: SongBinding(
                track: Fixture.trackA, lyricDocumentId: docA.id,
                userDelayMs: 450, titleHint: "提示甲", artistHint: "歌手甲", durationHintMs: 180_000
            )
        )
        try await store.save(
            document: docB,
            binding: SongBinding(track: Fixture.trackB, lyricDocumentId: docB.id, titleHint: "提示乙")
        )
        let service = LyricsLibraryService(store: store)
        let trackAKey = SongBinding.trackKey(for: Fixture.trackA)

        let rebound = try await service.reassociate(trackKey: trackAKey, toDocumentId: docB.id)
        #expect(rebound.lyricDocumentId == docB.id)
        #expect(rebound.userDelayMs == 450)
        #expect(rebound.titleHint == "提示甲")
        #expect(rebound.artistHint == "歌手甲")
        #expect(rebound.durationHintMs == 180_000)
        #expect(rebound.track == Fixture.trackA)

        // 原文档保留（仅失去绑定，不被删除）。
        #expect(try await store.document(id: docA.id) == docA)
        #expect(try await store.bindings(referencing: docA.id).isEmpty)
        #expect(try await store.bindings(referencing: docB.id).count == 2)

        // 其他曲目绑定不受影响。
        let bindingB = try await store.binding(for: Fixture.trackB)
        #expect(bindingB?.lyricDocumentId == docB.id)
        #expect(bindingB?.userDelayMs == 0)
    }

    @Test("reassociate：无既有绑定的新曲目、非法 trackKey、目标文档不存在")
    func reassociationEdgeCases() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = LyricDocument(
            sourceFormat: .lrc,
            lines: [LyricLine(startMs: 1_000, text: "第一句测试文本")]
        )
        try await store.save(
            document: doc,
            binding: SongBinding(track: Fixture.trackA, lyricDocumentId: doc.id)
        )
        let service = LyricsLibraryService(store: store)

        // 从项目命名空间构造的全新 trackKey：新建默认绑定（delay 0）。
        let newKey = "apple-music:catalog:gb:7000099"
        let created = try await service.reassociate(trackKey: newKey, toDocumentId: doc.id)
        #expect(created.userDelayMs == 0)
        #expect(created.track?.storefront == "gb")
        #expect(created.track?.catalogSongId == "7000099")

        // v2 脚本命名空间的 trackKey 同样可重新关联。
        let scriptKey = "music-script:persistent:ABCDEF0123456789"
        let scriptCreated = try await service.reassociate(trackKey: scriptKey, toDocumentId: doc.id)
        #expect(scriptCreated.track == nil)
        #expect(scriptCreated.persistentID == "ABCDEF0123456789")

        // 非法 trackKey → 类型化拒绝。
        await #expect(throws: LyricsLibraryError.invalidTrackKey("song-12345")) {
            try await service.reassociate(trackKey: "song-12345", toDocumentId: doc.id)
        }
        await #expect(throws: LyricsLibraryError.invalidTrackKey("apple-music:library:1")) {
            try await service.reassociate(trackKey: "apple-music:library:1", toDocumentId: doc.id)
        }
        // 目标文档不存在 → documentNotFound。
        let missing = UUID()
        await #expect(throws: LyricsLibraryError.documentNotFound(missing)) {
            try await service.reassociate(trackKey: newKey, toDocumentId: missing)
        }
    }

    @Test("备份包装：export → parse → conflictPreview → import 全链路生效")
    func backupWrappers() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            originalFilename: "备份包装测试.lrc",
            lines: [LyricLine(startMs: 1_000, text: "第一句测试文本")]
        )
        try await store.save(
            document: document,
            binding: SongBinding(track: Fixture.trackA, lyricDocumentId: document.id, userDelayMs: 300)
        )
        let service = LyricsLibraryService(store: store)
        let data = try await service.exportBackup()

        // 全新空库走一遍确认导入流程。
        let (fresh, freshDir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(freshDir) }
        let freshService = LyricsLibraryService(store: fresh)
        let parsed = try freshService.parseBackup(data)
        let preview = try await freshService.backupConflictPreview(for: parsed)
        #expect(preview.documentsToAdd.map(\.id) == [document.id])
        #expect(preview.documentReplacements.isEmpty)
        #expect(preview.bindingsToAdd.count == 1)
        try await freshService.importBackup(parsed)
        #expect(try await fresh.document(id: document.id) == document)
        #expect(try await fresh.binding(for: Fixture.trackA)?.userDelayMs == 300)

        // 原库再导出一次：内容一致（时间参数固定时字节确定）。
        let dataAgain = try await service.exportBackup()
        #expect(data == dataAgain)
    }
}
