import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 备份恢复闭环测试：
// 「清空测试数据库后导入备份可恢复闭环」——
// 库 A 预置完整数据（原文/译文/待复核/未打轴行/offset/元信息/多绑定/高 revision）
// → 导出 JSON → 全新空库（等价于清空后重建）→ 解析 → 冲突预览 → 确认导入
// → 逐字段对比原文、译文、时间、offset、绑定、revision、schema。

@Suite("备份恢复闭环")
struct BackupRestoreRoundTripTests {

    /// 源库夹具：两份文档 + 三条绑定 + 一个白名单外设置键。
    private struct SourceFixture {
        let timedDoc: LyricDocument
        /// 库中最终版本（revision 6，比 timedDoc 多一条绑定）。
        let timedDocFinal: LyricDocument
        let textDoc: LyricDocument
    }

    private static func seedSource(_ store: GRDBLyricsStore) async throws -> SourceFixture {
        let timedDoc = LyricDocument(
            revision: 5,
            sourceLanguage: "ja",
            sourceFormat: .lrc,
            sourceOffsetMs: -320,
            originalText: "[00:01]第一句测试文本\n[61:02.300]超分钟测试文本\n未打轴补记测试文本\n",
            originalFilename: "闭环测试甲.lrc",
            metadata: [
                "ti": ["闭环测试曲目甲"],
                "ar": ["测试歌手甲", "测试歌手乙"],
                "al": ["虚构专辑测试"]
            ],
            lines: [
                LyricLine(
                    startMs: 1_000,
                    text: "第一句测试文本",
                    translations: [
                        "zh-Hans": Translation(text: "第一句测试译文", source: .manual, needsReview: false),
                        "zh-Hant": Translation(text: "第一句測試譯文", source: .imported, needsReview: true)
                    ]
                ),
                LyricLine(startMs: 3_662_300, text: "超分钟测试文本"),
                LyricLine(startMs: nil, text: "未打轴补记测试文本"),
                LyricLine(startMs: 6_000, text: "")
            ]
        )
        let textDoc = LyricDocument(
            sourceFormat: .text,
            originalFilename: "闭环测试乙.txt",
            lines: [
                LyricLine(startMs: nil, text: "纯文本第一行测试"),
                LyricLine(startMs: nil, text: "纯文本第二行测试")
            ]
        )
        try await store.save(
            document: timedDoc,
            binding: SongBinding(
                track: Fixture.trackA,
                lyricDocumentId: timedDoc.id,
                userDelayMs: 300,
                titleHint: "闭环曲目甲",
                artistHint: "测试歌手甲",
                durationHintMs: 183_000
            )
        )
        var timedDocFinal = timedDoc
        timedDocFinal.revision = 6
        try await store.save(
            document: timedDocFinal,
            binding: SongBinding(
                track: Fixture.trackB,
                lyricDocumentId: timedDoc.id,
                userDelayMs: -150,
                titleHint: "闭环曲目乙"
            )
        )
        try await store.save(
            document: textDoc,
            binding: SongBinding(track: Fixture.trackC, lyricDocumentId: textDoc.id)
        )
        // 白名单外设置键：导出时被过滤，不进备份。
        try await store.setSettingValue("本地临时值", forKey: "device.only.key")
        return SourceFixture(
            timedDoc: timedDoc, timedDocFinal: timedDocFinal, textDoc: textDoc
        )
    }

    @Test("导出 → 全新空库导入 → 原文/译文/时间/offset/绑定/revision/schema 逐字段一致")
    func fullRoundTripRestoresEveryField() async throws {
        // 1) 源库：完整数据。
        let (source, sourceDir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(sourceDir) }
        let fixture = try await Self.seedSource(source)

        // 2) 导出 → 3) 全新空库（清空等价物）→ 解析 → 预览。
        let backupData = try await source.exportBackup()
        let (restored, restoredDir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(restoredDir) }
        #expect(try await restored.allDocuments().isEmpty)
        #expect(try await restored.allBindings().isEmpty)

        let service = LyricsLibraryService(store: restored)
        let parsed = try service.parseBackup(backupData)
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.file.schemaVersion == BackupFile.currentSchemaVersion)

        let preview = try await service.backupConflictPreview(for: parsed)
        #expect(preview.documentsToAdd.map(\.id).sorted() == [fixture.timedDoc.id, fixture.textDoc.id].sorted())
        #expect(preview.documentReplacements.isEmpty)
        #expect(preview.bindingsToAdd.count == 3)
        #expect(preview.bindingReplacements.isEmpty)

        // 4) 确认导入 → 5) 逐字段对比。
        try await service.importBackup(parsed)
        try await assertRestoredDocuments(fixture, in: restored)
        try await assertRestoredBindings(fixture, in: restored)

        // 再导出字节与源库一致（导出确定性 → 恢复完整性的最强证据）。
        let exportedAgain = try await restored.exportBackup()
        #expect(exportedAgain == backupData)
    }

    /// 文档逐字段（含 revision / schema / offset / 原文 / 元信息 / 行与译文）。
    private func assertRestoredDocuments(
        _ fixture: SourceFixture, in restored: GRDBLyricsStore
    ) async throws {
        let restoredTimed = try #require(await restored.document(id: fixture.timedDoc.id))
        #expect(restoredTimed.schemaVersion == LyricDocument.currentSchemaVersion)
        // 值类型全等兜底：与库中最终版本（revision 6）逐字段一致。
        #expect(restoredTimed == fixture.timedDocFinal)
        #expect(restoredTimed.revision == 6)
        #expect(restoredTimed.sourceOffsetMs == -320)
        #expect(restoredTimed.originalText == fixture.timedDoc.originalText)
        #expect(restoredTimed.originalFilename == "闭环测试甲.lrc")
        #expect(restoredTimed.metadata == fixture.timedDoc.metadata)
        #expect(restoredTimed.lines.count == 4)
        #expect(restoredTimed.lines.map(\.startMs) == fixture.timedDoc.lines.map(\.startMs))
        #expect(restoredTimed.lines[0].translations["zh-Hans"]?.text == "第一句测试译文")
        #expect(restoredTimed.lines[0].translations["zh-Hans"]?.needsReview == false)
        #expect(restoredTimed.lines[0].translations["zh-Hant"]?.needsReview == true)
        #expect(restoredTimed.lines[2].startMs == nil)
        #expect(restoredTimed.lines[3].text == "")

        let restoredText = try #require(await restored.document(id: fixture.textDoc.id))
        #expect(restoredText == fixture.textDoc)
        #expect(restoredText.lines.allSatisfy { $0.startMs == nil })
    }

    /// 绑定逐字段（含 userDelayMs 与提示）与设置白名单行为。
    private func assertRestoredBindings(
        _ fixture: SourceFixture, in restored: GRDBLyricsStore
    ) async throws {
        let bindings = try await restored.allBindings()
        #expect(bindings.count == 3)
        #expect(bindings.map(\.trackKey) == bindings.map(\.trackKey).sorted())
        let bindingA = try #require(await restored.binding(for: Fixture.trackA))
        #expect(bindingA.lyricDocumentId == fixture.timedDoc.id)
        #expect(bindingA.userDelayMs == 300)
        #expect(bindingA.titleHint == "闭环曲目甲")
        #expect(bindingA.artistHint == "测试歌手甲")
        #expect(bindingA.durationHintMs == 183_000)
        let bindingB = try #require(await restored.binding(for: Fixture.trackB))
        #expect(bindingB.lyricDocumentId == fixture.timedDoc.id)
        #expect(bindingB.userDelayMs == -150)
        // 设置：白名单外键不进备份、不进恢复库。
        #expect(try await restored.settingValue(forKey: "device.only.key") == nil)
    }

    @Test("恢复后的库可用：LRC 导出与编辑器保存继续工作（闭环可用性）")
    func restoredLibraryRemainsUsable() async throws {
        let (source, sourceDir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(sourceDir) }
        let document = LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            originalFilename: "可用性测试.lrc",
            lines: [
                LyricLine(startMs: 1_000, text: "第一句测试文本"),
                LyricLine(startMs: 3_662_300, text: "超分钟测试文本")
            ]
        )
        try await source.save(
            document: document,
            binding: SongBinding(track: Fixture.trackA, lyricDocumentId: document.id, userDelayMs: 500)
        )
        let backupData = try await source.exportBackup()

        let (restored, restoredDir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(restoredDir) }
        let service = LyricsLibraryService(store: restored)
        let parsed = try service.parseBackup(backupData)
        try await service.importBackup(parsed)

        // 恢复库的 LRC 导出：appliedOffset 恢复绑定延迟并正确应用一次。
        let applied = try await service.exportLRC(documentId: document.id, mode: .appliedOffset)
        #expect(applied.text.contains("[61:02.60]超分钟测试文本")) // 3_662_300 − 200 + 500
        #expect(applied.text.contains("[00:01.30]第一句测试文本"))

        // 概览与受影响绑定查询正常。
        let overview = try await service.libraryOverview()
        #expect(overview.count == 1)
        #expect(overview.first?.bindingCount == 1)
        #expect(try await service.affectedBindings(forDeletionOf: document.id).count == 1)
    }
}
