import Foundation
import os
import Testing
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
@testable import ShinAppServices

// AI 学习工作流、编辑器注音/笔记批量写入及导入预览合入单测。
// 夹具全部为原创虚构文本，通过 MockAIStudyClient 注入行为，不访问真实网络。

final class MockAIStudyClient: AIStudyProviding, @unchecked Sendable {
    typealias PronunciationHandler = @Sendable (
        [LyricLine], PronunciationStyle, String?, AIConfiguration, String?
    ) async throws -> [AIPronunciationLineItem]
    typealias TranslationHandler = @Sendable (
        [LyricLine], String?, AIConfiguration, String?
    ) async throws -> [AITranslationLineItem]

    private struct State {
        var pronunciationBatches: [[UUID]] = []
        var translationBatches: [[UUID]] = []
        var capturedTargetLanguages: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var pronunciationHandler: PronunciationHandler?
    var translationHandler: TranslationHandler?

    var pronunciationBatchCalls: [[UUID]] { state.withLock { $0.pronunciationBatches } }
    var translationBatchCalls: [[UUID]] { state.withLock { $0.translationBatches } }
    var capturedTargetLanguages: [String] { state.withLock { $0.capturedTargetLanguages } }

    func testConnection(configuration: AIConfiguration, apiKey: String?) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: configuration.modelName, replyPreview: "ok")
    }

    func explainWord(
        _ word: String, inLine lineText: String, sourceLanguage: String?, configuration: AIConfiguration, apiKey: String?
    ) async throws -> AIWordExplanation {
        AIWordExplanation(surface: word, lemma: word, contextualMeaning: "测试语境", generalMeaning: "测试通用")
    }

    func explainLine(
        _ lineText: String, context: AILineContext, configuration: AIConfiguration, apiKey: String?
    ) async throws -> AILineExplanation {
        AILineExplanation(grammarSummary: "测试句法")
    }

    func generatePronunciations(
        for lines: [LyricLine], style: PronunciationStyle, sourceLanguage: String?,
        configuration: AIConfiguration, apiKey: String?
    ) async throws -> [AIPronunciationLineItem] {
        state.withLock { $0.pronunciationBatches.append(lines.map(\.id)) }
        if let pronunciationHandler {
            return try await pronunciationHandler(lines, style, sourceLanguage, configuration, apiKey)
        }
        return lines.map { AIPronunciationLineItem(lineId: $0.id, pronunciation: "ro-\($0.text)") }
    }

    func generateTranslations(
        for lines: [LyricLine], sourceLanguage: String?, configuration: AIConfiguration, apiKey: String?
    ) async throws -> [AITranslationLineItem] {
        state.withLock {
            $0.translationBatches.append(lines.map(\.id))
            $0.capturedTargetLanguages.append(configuration.preferredTargetLanguage)
        }
        if let translationHandler {
            return try await translationHandler(lines, sourceLanguage, configuration, apiKey)
        }
        return lines.map { AITranslationLineItem(lineId: $0.id, translation: "译-\($0.text)") }
    }

    func extractKeyStudyPoints(
        from lines: [LyricLine], sourceLanguage: String?, configuration: AIConfiguration, apiKey: String?
    ) async throws -> [AIKeyStudyPoint] { [] }
}

enum StudyTestHelper {
    static func makeService(
        store: GRDBLyricsStore, client: MockAIStudyClient, modelName: String = "mock-model"
    ) -> AIStudyWorkflowService {
        AIStudyWorkflowService(
            store: store,
            aiClient: client,
            configurationProvider: { AIConfiguration(preset: .openAI, modelName: modelName, preferredTargetLanguage: "zh-Hans") },
            apiKeyProvider: { "mock-key-for-tests" }
        )
    }

    static func seedStudyDocument(
        in store: GRDBLyricsStore, boundToTrack: CatalogIdentity? = Fixture.trackA
    ) async throws -> LyricDocument {
        let line1 = LyricLine(
            startMs: 1_000,
            text: "测试虚构歌词第一句",
            translations: ["zh-Hans": Translation(text: "人工译文", source: .manual, needsReview: false)],
            pronunciation: LinePronunciation(style: .romaji, text: "manual-ro", source: .manual(), needsReview: false),
            studyNote: LineStudyNote(grammarSummary: "初始文法笔记", source: .manual(), needsReview: false)
        )
        let line2 = LyricLine(
            startMs: 3_000,
            text: "测试虚构歌词第二句",
            pronunciation: LinePronunciation(style: .romaji, text: "old-ai-ro", source: .ai(model: "old"), needsReview: true)
        )
        let line3 = LyricLine(startMs: 5_000, text: "   ")
        let line4 = LyricLine(
            startMs: 7_000,
            text: "测试虚构歌词第三句",
            translations: ["zh-Hans": Translation(text: "导入译文", source: .imported, needsReview: false)]
        )
        let doc = LyricDocument(sourceLanguage: "ja", sourceFormat: .lrc, lines: [line1, line2, line3, line4])
        if let boundToTrack {
            try await store.save(document: doc, binding: SongBinding(track: boundToTrack, lyricDocumentId: doc.id))
        } else {
            try await store.save(document: doc, binding: SongBinding(track: Fixture.trackC, lyricDocumentId: doc.id))
            try await store.deleteBinding(for: Fixture.trackC)
        }
        return doc
    }
}

@Suite("编辑器学习标注与批处理")
struct LyricsEditingStudyTests {

    @Test("改原文同步标待复核：译文、注音与学习笔记均置 needsReview = true")
    func setLineTextMarksPronunciationAndStudyNoteNeedsReview() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = try await StudyTestHelper.seedStudyDocument(in: store)
        let editor = LyricsEditingService(store: store)
        _ = try await editor.openEditor(documentId: doc.id)

        let line1Id = doc.lines[0].id
        let line4Id = doc.lines[3].id
        let snapshot = try await editor.setLineText(lineId: line1Id, text: "修改后的虚构歌词第一句")
        let edited = snapshot.line(id: line1Id)
        #expect(edited?.translations["zh-Hans"]?.needsReview == true)
        #expect(edited?.pronunciation?.needsReview == true)
        #expect(edited?.studyNote?.needsReview == true)
        #expect(snapshot.needsReviewLineCount == 2)

        // 同文本 no-op 不改变状态、不产生历史。
        let noop = try await editor.setLineText(lineId: line4Id, text: "测试虚构歌词第三句")
        #expect(noop.line(id: line4Id)?.translations["zh-Hans"]?.needsReview == false)

        let undone = try await editor.undo()
        #expect(undone.line(id: line1Id)?.pronunciation?.needsReview == false)
        #expect(undone.line(id: line1Id)?.studyNote?.needsReview == false)
    }

    @Test("单行注音与学习笔记编辑：支持空串清除、同值 no-op、撤销与重做")
    func setPronunciationAndStudyNoteUndoRedo() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = try await StudyTestHelper.seedStudyDocument(in: store)
        let editor = LyricsEditingService(store: store)
        _ = try await editor.openEditor(documentId: doc.id)

        let line2Id = doc.lines[1].id
        let line4Id = doc.lines[3].id

        _ = try await editor.setPronunciation(lineId: line4Id, style: .romaji, text: "  dai san ku  ")
        let afterSet = try await editor.setPronunciation(lineId: line4Id, style: nil, text: "dai san ku")
        #expect(afterSet.line(id: line4Id)?.pronunciation == LinePronunciation(
            style: .romaji, text: "dai san ku", source: .manual(), needsReview: false
        ))
        #expect(afterSet.canUndo == true)

        // line2 原先 needsReview=true，写入同文本会清除 needsReview 并转为 manual；再设同值则 no-op。
        let clearedReview = try await editor.setPronunciation(lineId: line2Id, style: nil, text: "old-ai-ro")
        #expect(clearedReview.line(id: line2Id)?.pronunciation?.needsReview == false)
        #expect(clearedReview.line(id: line2Id)?.pronunciation?.source == .manual())
        let noop = try await editor.setPronunciation(lineId: line2Id, style: .romaji, text: "old-ai-ro")
        #expect(noop == clearedReview)

        // 空/换行清除为 nil，并可撤销/重做。
        let cleared = try await editor.setPronunciation(lineId: line4Id, style: nil, text: " \n ")
        #expect(cleared.line(id: line4Id)?.pronunciation == nil)
        #expect(try await editor.undo().line(id: line4Id)?.pronunciation?.text == "dai san ku")
        #expect(try await editor.redo().line(id: line4Id)?.pronunciation == nil)

        let note = LineStudyNote(grammarSummary: "新文法要点", singingTips: "弱起", source: .ai(model: "m"))
        let withNote = try await editor.setLineStudyNote(lineId: line4Id, note: note)
        #expect(withNote.line(id: line4Id)?.studyNote == note)
        #expect(withNote.studyNoteLineCount == 2)
        let withoutNote = try await editor.setLineStudyNote(lineId: line4Id, note: nil)
        #expect(withoutNote.line(id: line4Id)?.studyNote == nil)
        #expect(try await editor.undo().line(id: line4Id)?.studyNote == note)
    }

    @Test("批量注音与批量译文：按 lineId 写入草稿且纳入单次撤销/重做")
    func batchApplyPronunciationsAndTranslationsSingleUndo() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = try await StudyTestHelper.seedStudyDocument(in: store)
        let editor = LyricsEditingService(store: store)
        _ = try await editor.openEditor(documentId: doc.id)

        let line2Id = doc.lines[1].id
        let line4Id = doc.lines[3].id
        let batchPron = try await editor.applyBatchPronunciations([
            line2Id: LinePronunciation(style: .furigana, text: "だいにく", source: .ai(model: "m")),
            line4Id: LinePronunciation(style: .furigana, text: "だいさんく", source: .ai(model: "m")),
            UUID(): LinePronunciation(style: .furigana, text: "忽略未知行", source: .ai(model: "m"))
        ])
        #expect(batchPron.line(id: line2Id)?.pronunciation?.text == "だいにく")
        #expect(batchPron.line(id: line4Id)?.pronunciation?.text == "だいさんく")
        #expect(batchPron.pronunciationLineCount == 3)

        // 一次撤销即回退整批注音。
        let undoneBatch = try await editor.undo()
        #expect(undoneBatch.line(id: line2Id)?.pronunciation?.text == "old-ai-ro")
        #expect(undoneBatch.line(id: line4Id)?.pronunciation == nil)
        #expect(undoneBatch.canUndo == false)

        _ = try await editor.redo()
        let batchTrans = try await editor.applyBatchTranslations([
            line2Id: Translation(text: "AI 译文二", source: .imported, needsReview: false),
            line4Id: Translation(text: "AI 译文三", source: .imported, needsReview: false)
        ], language: "zh-Hans")
        #expect(batchTrans.line(id: line2Id)?.translations["zh-Hans"]?.text == "AI 译文二")
        #expect(batchTrans.line(id: line4Id)?.translations["zh-Hans"]?.text == "AI 译文三")

        let undoneTrans = try await editor.undo()
        #expect(undoneTrans.line(id: line2Id)?.translations["zh-Hans"] == nil)
        #expect(undoneTrans.line(id: line4Id)?.translations["zh-Hans"]?.text == "导入译文")
    }
}

@Suite("AI 学习批处理工作流")
struct AIStudyWorkflowTests {

    @Test("生成预览：过滤空白行、分批回传进度、按 lineId 乱序/遗漏对齐并保护 .manual")
    func generatePreviewAlignmentAndManualProtection() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = try await StudyTestHelper.seedStudyDocument(in: store)
        let client = MockAIStudyClient()

        // 第 1 批（2 行）乱序返回且附带未知 ID；第 2 批（1 行）遗漏返回空数组。
        client.pronunciationHandler = { lines, _, _, _, _ in
            guard lines.count == 2 else { return [] }
            return [
                AIPronunciationLineItem(lineId: UUID(), pronunciation: "unknown-line"),
                AIPronunciationLineItem(lineId: lines[1].id, pronunciation: "  gen-line2  "),
                AIPronunciationLineItem(lineId: lines[0].id, pronunciation: "gen-line1")
            ]
        }

        let service = StudyTestHelper.makeService(store: store, client: client)
        let progressLock = OSAllocatedUnfairLock(initialState: [AIStudyBatchProgress]())
        let lineIDs = Set(doc.lines.map(\.id))
        let preview = try await service.generatePreview(
            for: doc, task: .pronunciation(.romaji), songTitle: "测试歌名", artist: "测试歌手", batchSize: 2,
            request: .regenerate(lineIds: lineIDs, completedBatches: AIStudyPreviewCache())
        ) { progress in
            progressLock.withLock { $0.append(progress) }
        }

        #expect(AIStudyWorkflowService.defaultBatchSize == 10)
        #expect(client.pronunciationBatchCalls.count == 2)
        #expect(preview.map(\.lineId) == [doc.lines[0].id, doc.lines[1].id, doc.lines[3].id])
        let reportedProgress = progressLock.withLock { $0 }
        #expect(reportedProgress == [
            AIStudyBatchProgress(completedBatches: 0, totalBatches: 2, completedLines: 0, totalLines: 3),
            AIStudyBatchProgress(completedBatches: 1, totalBatches: 2, completedLines: 2, totalLines: 3),
            AIStudyBatchProgress(completedBatches: 2, totalBatches: 2, completedLines: 3, totalLines: 3)
        ])
        #expect(reportedProgress.map(\.currentBatchNumber) == [1, 2, 2])
        #expect(reportedProgress[0].fractionCompleted == 0)
        #expect(abs(reportedProgress[1].fractionCompleted - (2.0 / 3.0)) < 0.0001)
        #expect(reportedProgress[2].fractionCompleted == 1)

        // line1 为 .manual 默认不选中；line2 为 .ai 默认选中；line4 遗漏无结果不选中。
        #expect(preview[0].existingIsManual == true)
        #expect(preview[0].existingText == "manual-ro")
        #expect(preview[0].generatedText == "gen-line1")
        #expect(preview[0].isSelected == false)
        #expect(preview[1].existingIsManual == false)
        #expect(preview[1].generatedText == "gen-line2")
        #expect(preview[1].isSelected == true)
        #expect(preview[2].generatedText.isEmpty)
        #expect(preview[2].isSelected == false)

        // 翻译模式同样保护 .manual 译文，非 .manual（如 .imported）默认允许更新。
        let transPreview = try await service.generatePreview(
            for: doc, task: .translation(targetLanguage: "zh-Hans"), batchSize: 10,
            request: .regenerate(lineIds: lineIDs, completedBatches: AIStudyPreviewCache())
        )
        #expect(client.capturedTargetLanguages == ["zh-Hans"])
        #expect(transPreview[0].existingIsManual == true)
        #expect(transPreview[0].isSelected == false)
        #expect(transPreview[1].existingText == nil)
        #expect(transPreview[1].isSelected == true)
        #expect(transPreview[2].existingIsManual == false)
        #expect(transPreview[2].existingText == "导入译文")
        #expect(transPreview[2].isSelected == true)
    }

    @Test("原子提交与乐观并发：核对 expectedRevision，冲突拒绝覆盖；成功写入清除 needsReview")
    func applyPreviewToStoreRevisionConflictAndCommit() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = try await StudyTestHelper.seedStudyDocument(in: store)
        let client = MockAIStudyClient()
        let service = StudyTestHelper.makeService(store: store, client: client)

        let preview = try await service.generatePreview(
            for: doc, task: .pronunciation(.romaji),
            request: .regenerate(lineIds: [doc.lines[1].id], completedBatches: AIStudyPreviewCache())
        )

        var concurrent = doc
        concurrent.revision = 2
        concurrent.lines[0].text = "并发保存的新原文"
        try await store.save(document: concurrent, binding: SongBinding(track: Fixture.trackA, lyricDocumentId: doc.id))

        do {
            _ = try await service.applyPreviewToStore(
                documentId: doc.id, expectedRevision: 1, task: .pronunciation(.romaji), modelName: "mock-model", items: preview
            )
            Issue.record("revision 不一致时应当抛出 revisionConflict")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .revisionConflict(documentId: doc.id, storedRevision: 2, expectedRevision: 1))
        }
        #expect(try await store.document(id: doc.id)?.lines[0].text == "并发保存的新原文")

        let staleLine = AIStudyPreviewLine(
            lineId: doc.lines[0].id, originalText: doc.lines[0].text, generatedText: "过期预览"
        )
        await #expect(throws: AIStudyWorkflowError.self) {
            try await service.applyPreviewToStore(
                documentId: doc.id, expectedRevision: 2, task: .pronunciation(.romaji),
                modelName: "mock-model", items: [staleLine]
            )
        }

        let updated = try await service.applyPreviewToStore(
            documentId: doc.id, expectedRevision: 2, task: .pronunciation(.romaji), modelName: "mock-model", items: preview
        )
        #expect(updated.revision == 3)
        #expect(updated.lines[0].pronunciation?.text == "manual-ro")
        #expect(updated.lines[1].pronunciation == LinePronunciation(
            style: .romaji, text: "ro-测试虚构歌词第二句", source: .ai(model: "mock-model"), needsReview: false
        ))
        #expect(try await store.document(id: doc.id) == updated)

        // 无绑定文档同样可通过 updateDocument 路径原子落库。
        let unboundDoc = try await StudyTestHelper.seedStudyDocument(in: store, boundToTrack: nil)
        let unboundPreview = try await service.generatePreview(
            for: unboundDoc, task: .translation(targetLanguage: "zh-Hans"), songTitle: nil, artist: nil
        )
        let committedUnbound = try await service.applyPreviewToStore(
            documentId: unboundDoc.id, expectedRevision: 1, task: .translation(targetLanguage: "zh-Hans"),
            modelName: nil, items: unboundPreview
        )
        #expect(committedUnbound.revision == 2)
        #expect(committedUnbound.lines[0].translations["zh-Hans"]?.text == "人工译文")
        #expect(committedUnbound.lines[1].translations["zh-Hans"]?.text == "译-测试虚构歌词第二句")
    }

    @Test("导入工作流：预览期合入 AI 注音与译文并落盘；切换双语或重选文件重置缓存")
    func importWorkflowPreviewStudyAnnotationsLifecycle() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let importService = ImportWorkflowService(store: store)
        let client = MockAIStudyClient()
        let aiService = StudyTestHelper.makeService(store: store, client: client)

        #expect(await importService.currentDraftDocumentForStudy() == nil)
        try await importService.openImportSession(target: Fixture.targetA())
        _ = try await importService.ingest(
            fileData: Data(BilingualFixture.pairedLrcText.utf8), filename: "双语导入测试.lrc"
        )
        _ = await importService.setBilingualMode(.pairedTimestamps)

        guard let draft = await importService.currentDraftDocumentForStudy() else {
            Issue.record("已 ingest 且处于 open 状态应返回预览草稿")
            return
        }
        let pronItems = try await aiService.generatePreview(
            for: draft, task: .pronunciation(.romaji), songTitle: nil, artist: nil
        )
        let mergedPron = AIStudyWorkflowService.mergedPronunciations(
            in: draft, items: pronItems, style: .romaji, modelName: "mock-model"
        )
        let previewWithPron = await importService.applyStudyAnnotations(
            pronunciations: mergedPron, translations: [:], language: "zh-Hans"
        )
        #expect(previewWithPron?.pronunciationLineCount == 2)
        #expect(previewWithPron?.aiTranslationLineCount == 0)

        // 切换双语模式会重置此前合入的 AI 注解缓存。
        let switchedPreview = await importService.setBilingualMode(.off)
        #expect(switchedPreview?.pronunciationLineCount == 0)
        #expect(switchedPreview?.aiTranslationLineCount == 0)

        let freshDraft = await importService.currentDraftDocumentForStudy()!
        let freshPronItems = try await aiService.generatePreview(
            for: freshDraft, task: .pronunciation(.furigana), songTitle: nil, artist: nil
        )
        let freshTransItems = try await aiService.generatePreview(
            for: freshDraft, task: .translation(targetLanguage: "zh-Hans"), songTitle: nil, artist: nil
        )
        let freshPron = AIStudyWorkflowService.mergedPronunciations(
            in: freshDraft, items: freshPronItems, style: .furigana, modelName: "mock-model"
        )
        let freshTrans = AIStudyWorkflowService.mergedTranslations(
            in: freshDraft, items: freshTransItems, language: "zh-Hans"
        )
        _ = await importService.applyStudyAnnotations(pronunciations: freshPron, translations: [:], language: "zh-Hans")
        let finalPreview = await importService.applyStudyAnnotations(
            pronunciations: [:], translations: freshTrans, language: "zh-Hans"
        )
        #expect(finalPreview?.pronunciationLineCount == 4)
        #expect(finalPreview?.aiTranslationLineCount == 4)

        let confirmation = try await importService.confirmImport()
        let stored = try await store.document(id: confirmation.document.id)
        #expect(stored?.lines.count == 4)
        #expect(stored?.lines.allSatisfy { $0.pronunciation?.style == .furigana } == true)
        #expect(stored?.lines[0].translations["zh-Hans"]?.text == "译-测试原文甲")
    }
}
