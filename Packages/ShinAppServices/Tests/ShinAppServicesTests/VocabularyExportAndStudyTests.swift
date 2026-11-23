import Foundation
import os
import Testing
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
@testable import ShinAppServices

// Phase 3.1 单测：生词本多格式导出（Anki TSV / CSV / Markdown）与歌词学习协同服务。
// 全部使用原创虚构文本与注入 Mock，不访问真实网络。

// MARK: - 测试双工与辅助

private final class SpyLocalDictionaryProvider: LocalDictionaryLookupProviding, @unchecked Sendable {
    struct Call: Equatable, Sendable { let query: String; let contextLine: String? }
    private let state = OSAllocatedUnfairLock(initialState: [Call]())
    var resultProvider: @Sendable (String, String?) -> LocalDictionaryLookupResult

    init(resultProvider: @escaping @Sendable (String, String?) -> LocalDictionaryLookupResult = { query, _ in
        LocalDictionaryLookupResult(
            query: query, lemma: query.lowercased(), partOfSpeech: "动词",
            detectedLanguage: "en", systemDefinition: "虚构词典释义"
        )
    }) { self.resultProvider = resultProvider }

    var calls: [Call] { state.withLock { $0 } }
    func lookup(_ query: String, contextLine: String?) -> LocalDictionaryLookupResult {
        state.withLock { $0.append(Call(query: query, contextLine: contextLine)) }
        return resultProvider(query, contextLine)
    }
}

private final class SpyAIStudyClient: AIStudyProviding, @unchecked Sendable {
    struct WordCall: Equatable, Sendable {
        let word: String; let lineText: String; let sourceLanguage: String?; let apiKey: String?
    }
    struct LineCall: Equatable, Sendable {
        let lineText: String; let context: AILineContext; let apiKey: String?
    }
    private struct State { var wordCalls: [WordCall] = []; var lineCalls: [LineCall] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var wordHandler: (@Sendable (String, String, String?, AIConfiguration, String?) async throws -> AIWordExplanation)?
    var lineHandler: (@Sendable (String, AILineContext, AIConfiguration, String?) async throws -> AILineExplanation)?
    var wordCalls: [WordCall] { state.withLock { $0.wordCalls } }
    var lineCalls: [LineCall] { state.withLock { $0.lineCalls } }

    func testConnection(configuration: AIConfiguration, apiKey: String?) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: configuration.modelName, replyPreview: "ok")
    }

    func explainWord(
        _ word: String, inLine lineText: String, sourceLanguage: String?,
        configuration: AIConfiguration, apiKey: String?
    ) async throws -> AIWordExplanation {
        state.withLock {
            $0.wordCalls.append(WordCall(word: word, lineText: lineText, sourceLanguage: sourceLanguage, apiKey: apiKey))
        }
        if let wordHandler { return try await wordHandler(word, lineText, sourceLanguage, configuration, apiKey) }
        return AIWordExplanation(
            surface: word, lemma: word.lowercased(), reading: "test-reading", partOfSpeech: "名词",
            contextualMeaning: "测试语境义", generalMeaning: "测试通用义",
            examples: [VocabularyExample(text: "测试例句。", translation: "测试例句译文。")]
        )
    }

    func explainLine(
        _ lineText: String, context: AILineContext, configuration: AIConfiguration, apiKey: String?
    ) async throws -> AILineExplanation {
        state.withLock { $0.lineCalls.append(LineCall(lineText: lineText, context: context, apiKey: apiKey)) }
        if let lineHandler { return try await lineHandler(lineText, context, configuration, apiKey) }
        return AILineExplanation(
            grammarSummary: "测试句法要点", keyExpressions: ["测试搭配"],
            singingTips: "句尾轻收。", culturalNote: "虚构文化意象说明。"
        )
    }

    func generatePronunciations(
        for lines: [LyricLine], style: PronunciationStyle, sourceLanguage: String?,
        configuration: AIConfiguration, apiKey: String?
    ) async throws -> [AIPronunciationLineItem] { [] }
    func generateTranslations(
        for lines: [LyricLine], sourceLanguage: String?, configuration: AIConfiguration, apiKey: String?
    ) async throws -> [AITranslationLineItem] { [] }
    func extractKeyStudyPoints(
        from lines: [LyricLine], sourceLanguage: String?, configuration: AIConfiguration, apiKey: String?
    ) async throws -> [AIKeyStudyPoint] { [] }
}

private enum ExportFixture {
    static func sampleDataset() -> (entries: [VocabularyEntry], occurrencesByEntryId: [UUID: [VocabularyOccurrence]]) {
        let entry1 = VocabularyEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            surface: "駆け抜ける", lemma: "駆け抜ける", reading: "かけぬける", language: "ja", partOfSpeech: "动词",
            generalMeaning: "疾驰穿过，\"全力\"冲刺\n跨越阻碍",
            examples: [VocabularyExample(text: "朝焼けの道を駆け抜ける。", translation: "穿过朝霞映照的街道。")],
            userNote: "第一行笔记, 带逗号\n第二行\t带制表符与\"引号\"",
            mastery: .reviewing, createdAt: "2026-03-01T10:00:00Z", updatedAt: "2026-03-02T12:00:00Z"
        )
        let occ1 = VocabularyOccurrence(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, entryId: entry1.id,
            utf16Location: 2, utf16Length: 5, surfaceInLine: "駆け抜ける", contextualMeaning: "形容逆风前行，突破\"迷雾\"",
            lineTextSnapshot: "風の街を\t駆け抜ける, 迷わずに\n明日へ", lineTranslationSnapshot: "穿过风之街，毫不犹豫奔向明日",
            startMsSnapshot: 65_400, trackTitleHint: "虚构曲目 Alpha", artistHint: "虚构歌手 A", createdAt: "2026-03-02T11:00:00Z"
        )
        let entry2 = VocabularyEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            surface: "sparkling", lemma: "sparkle", reading: "ˈspɑːrklɪŋ", language: "en", partOfSpeech: "形容词",
            generalMeaning: "闪耀的，充满活力的", mastery: .mastered,
            createdAt: "2026-03-01T08:00:00Z", updatedAt: "2026-03-01T09:00:00Z"
        )
        let occ2 = VocabularyOccurrence(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, entryId: entry2.id,
            surfaceInLine: "sparkling", contextualMeaning: "映照星光的", lineTextSnapshot: "Under the sparkling sky",
            startMsSnapshot: 3_662_000, trackTitleHint: "虚构曲目 Beta", artistHint: "虚构歌手 B", createdAt: "2026-03-01T09:00:00Z"
        )
        return ([entry1, entry2], [entry1.id: [occ1], entry2.id: [occ2]])
    }

    static func parseCSV(_ input: String) -> [[String]] {
        var rows: [[String]] = []; var row: [String] = []; var field = ""; var inQuotes = false
        let chars = Array(input); var index = 0
        while index < chars.count {
            let char = chars[index]
            if inQuotes {
                if char == "\"", index + 1 < chars.count, chars[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else if char == "\"" { inQuotes = false } else { field.append(char) }
            } else if char == "\"" { inQuotes = true
            } else if char == "," { row.append(field); field = ""
            } else if char == "\n" { row.append(field); rows.append(row); row = []; field = ""
            } else if char != "\r" { field.append(char) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: - VocabularyExportService 测试

@Suite("生词本多格式导出")
struct VocabularyExportServiceTests {

    @Test("格式元数据与空列表导出保持稳定契约")
    func formatMetadataAndEmptyExport() {
        #expect(VocabularyExportFormat.allCases == [.ankiTSV, .csv, .markdown])
        #expect(VocabularyExportFormat.ankiTSV.displayName == "Anki 制卡 (.tsv)")
        #expect(VocabularyExportFormat.ankiTSV.fileExtension == "tsv")
        #expect(VocabularyExportFormat.csv.displayName == "CSV 表格 (.csv)")
        #expect(VocabularyExportFormat.csv.fileExtension == "csv")
        #expect(VocabularyExportFormat.markdown.displayName == "Markdown 笔记 (.md)")
        #expect(VocabularyExportFormat.markdown.fileExtension == "md")

        #expect(VocabularyExportService.export(entries: [], occurrencesByEntryId: [:], format: .ankiTSV).isEmpty)
        let parsedCSV = ExportFixture.parseCSV(
            VocabularyExportService.export(entries: [], occurrencesByEntryId: [:], format: .csv)
        )
        #expect(parsedCSV.count == 1)
        #expect(parsedCSV[0].first == "词语")
        let emptyMD = VocabularyExportService.export(entries: [], occurrencesByEntryId: [:], format: .markdown)
        #expect(emptyMD.contains("# 生词本导出"))
        #expect(emptyMD.contains("暂无生词记录"))
    }

    @Test("Anki TSV：确定性排序、制表符/换行/引号转义与正背面结构")
    func exportAnkiTSVEscapingAndStructure() {
        let (entries, occs) = ExportFixture.sampleDataset()
        let forward = VocabularyExportService.export(entries: entries, occurrencesByEntryId: occs, format: .ankiTSV)
        let reversed = VocabularyExportService.export(
            entries: entries.reversed(), occurrencesByEntryId: occs, format: .ankiTSV
        )
        #expect(forward == reversed)

        let rows = forward.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(rows.count == 2)
        for row in rows {
            #expect(row.split(separator: "\t", omittingEmptySubsequences: false).count == 2)
        }
        let cols = rows[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(cols[0].contains("駆け抜ける [かけぬける]"))
        #expect(cols[0].contains("[01:05]"))
        #expect(cols[0].contains("<br>"))
        #expect(cols[1].contains("[动词]"))
        #expect(cols[1].contains("\"\"全力\"\""))
        #expect(cols[1].contains("虚构曲目 Alpha - 虚构歌手 A [01:05]"))
        #expect(cols[1].contains("第一行笔记, 带逗号<br>第二行 带制表符与\"\"引号\"\""))
    }

    @Test("CSV：UTF-8 表头、确定性排序与 RFC 4180 双引号无损转义")
    func exportCSVWithRFC4180Escaping() {
        let (entries, occs) = ExportFixture.sampleDataset()
        let forward = VocabularyExportService.export(entries: entries, occurrencesByEntryId: occs, format: .csv)
        let reversed = VocabularyExportService.export(
            entries: entries.reversed(), occurrencesByEntryId: occs, format: .csv
        )
        #expect(forward == reversed)
        #expect(forward.contains("\"\"全力\"\""))
        #expect(forward.contains("\"第一行笔记, 带逗号\n第二行\t带制表符与\"\"引号\"\"\""))

        let rows = ExportFixture.parseCSV(forward)
        #expect(rows.count == 3)
        #expect(rows[0] == ["词语", "原型", "读音", "语种", "词性", "掌握度", "通用释义", "语境释义", "例句", "个人笔记", "歌词原句", "曲目出处"])
        #expect(rows[1][0] == "駆け抜ける")
        #expect(rows[1][5] == "复习中")
        #expect(rows[1][6] == "疾驰穿过，\"全力\"冲刺\n跨越阻碍")
        #expect(rows[1][9] == "第一行笔记, 带逗号\n第二行\t带制表符与\"引号\"")
        #expect(rows[1][10].contains("[01:05]"))
        #expect(rows[2][0] == "sparkling")
        #expect(rows[2][1] == "sparkle")
        #expect(rows[2][5] == "已掌握")
        #expect(rows[2][11] == "虚构曲目 Beta - 虚构歌手 B [61:02]")
    }

    @Test("Markdown：分层标题、掌握度标签、笔记与 mm:ss 原声时间戳")
    func exportMarkdownHierarchyAndTimestamps() {
        let (entries, occs) = ExportFixture.sampleDataset()
        let forward = VocabularyExportService.export(entries: entries, occurrencesByEntryId: occs, format: .markdown)
        let reversed = VocabularyExportService.export(
            entries: entries.reversed(), occurrencesByEntryId: occs, format: .markdown
        )
        #expect(forward == reversed)
        #expect(forward.contains("# 生词本导出"))
        #expect(forward.contains("## 駆け抜ける"))
        #expect(forward.contains("- **读音**：かけぬける"))
        #expect(forward.contains("- **词性**：动词"))
        #expect(forward.contains("- **掌握度**：`复习中`"))
        #expect(forward.contains("### 通用释义"))
        #expect(forward.contains("### 个人笔记"))
        #expect(forward.contains("### 关联歌曲原声"))
        #expect(forward.contains("[01:05] 虚构曲目 Alpha - 虚构歌手 A"))
        #expect(forward.contains("## sparkling"))
        #expect(forward.contains("- **原型**：sparkle"))
        #expect(forward.contains("- **掌握度**：`已掌握`"))
        #expect(forward.contains("[61:02] 虚构曲目 Beta - 虚构歌手 B"))
    }
}

// MARK: - LyricsStudyService 测试

@Suite("歌词学习协同服务")
struct LyricsStudyServiceTests {

    private static func makeService(
        store: GRDBLyricsStore,
        dictionary: any LocalDictionaryLookupProviding = LocalDictionaryService(),
        aiClient: any AIStudyProviding = SpyAIStudyClient(),
        apiKey: String? = "test-api-key"
    ) -> LyricsStudyService {
        LyricsStudyService(
            store: store, localDictionary: dictionary, aiClient: aiClient,
            configurationProvider: {
                AIConfiguration(preset: .openAI, modelName: "mock-study-model", preferredTargetLanguage: "zh-Hans")
            },
            apiKeyProvider: { apiKey }
        )
    }

    @Test("lookupLocalWord：纯本机零网络离线查词")
    func lookupLocalWordOffline() throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let service = Self.makeService(store: store)
        let result = service.lookupLocalWord("running", contextLine: "She was running along the quiet river.")
        #expect(result.query == "running")
        #expect(result.detectedLanguage == "en")
        #expect(result.lemma == "run")
        #expect(result.partOfSpeech == "动词")

        let spyDict = SpyLocalDictionaryProvider()
        let spyService = Self.makeService(store: store, dictionary: spyDict)
        let custom = spyService.lookupLocalWord("walking", contextLine: "Test line")
        #expect(custom.lemma == "walking")
        #expect(spyDict.calls == [.init(query: "walking", contextLine: "Test line")])
    }

    @Test("explainWordWithAI：传递语境信息与本地语种提示，并映射错误与取消")
    func explainWordWithAIContextAndErrorMapping() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let spyDict = SpyLocalDictionaryProvider { query, _ in
            LocalDictionaryLookupResult(query: query, lemma: "飛ぶ", partOfSpeech: "动词", detectedLanguage: "ja")
        }
        let spyAI = SpyAIStudyClient()
        let service = Self.makeService(store: store, dictionary: spyDict, aiClient: spyAI, apiKey: "secret-key")

        let explanation = try await service.explainWordWithAI(
            surface: "  飛んで  ", lineText: "空を飛んでいく", lineTranslation: "向天空飞去",
            songTitle: "虚构飞翔", artist: "测试艺人"
        )
        #expect(explanation.surface == "飛んで")
        let captured = try #require(spyAI.wordCalls.first)
        #expect(captured.word == "飛んで")
        #expect(captured.sourceLanguage == "ja")
        #expect(captured.apiKey == "secret-key")
        #expect(captured.lineText.contains("空を飛んでいく"))
        #expect(captured.lineText.contains("向天空飞去"))
        #expect(captured.lineText.contains("虚构飞翔 - 测试艺人"))

        do {
            _ = try await service.explainWordWithAI(
                surface: "   ", lineText: "任意句", lineTranslation: nil, songTitle: nil, artist: nil
            )
            Issue.record("空白查询词应抛出 providerError")
        } catch let error as AIStudyWorkflowError {
            guard case .providerError(.invalidConfiguration) = error else {
                Issue.record("预期 invalidConfiguration，实际为 \(error)"); return
            }
        }
        #expect(spyAI.wordCalls.count == 1)

        spyAI.wordHandler = { _, _, _, _, _ in throw AIProviderError.httpError(statusCode: 401, message: "invalid") }
        do {
            _ = try await service.explainWordWithAI(
                surface: "空", lineText: "空を飛ぶ", lineTranslation: nil, songTitle: nil, artist: nil
            )
            Issue.record("应映射 AIProviderError")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .providerError(.httpError(statusCode: 401, message: "invalid")))
        }

        spyAI.wordHandler = { _, _, _, _, _ in throw CancellationError() }
        do {
            _ = try await service.explainWordWithAI(
                surface: "空", lineText: "空を飛ぶ", lineTranslation: nil, songTitle: nil, artist: nil
            )
            Issue.record("应映射 CancellationError")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .cancelled)
        }
    }

    @Test("explainLineWithAI：跳过空白行精准提取前后非空邻行并处理边界与错误")
    func explainLineWithAIExtractsNeighbors() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let line1 = LyricLine(startMs: 1_000, text: "第一句虚构原文")
        let blankBefore = LyricLine(startMs: 2_000, text: "   \n ")
        let targetLine = LyricLine(startMs: 3_000, text: "  目标句虚构原文  ")
        let blankAfter = LyricLine(startMs: 4_000, text: "")
        let line5 = LyricLine(startMs: 5_000, text: "第三句虚构原文")
        let document = LyricDocument(
            sourceLanguage: "ja", sourceFormat: .lrc,
            lines: [line1, blankBefore, targetLine, blankAfter, line5]
        )

        let spyAI = SpyAIStudyClient()
        let service = Self.makeService(store: store, aiClient: spyAI)

        let result = try await service.explainLineWithAI(
            document: document, lineId: targetLine.id, songTitle: "虚构曲目", artist: "虚构艺人"
        )
        #expect(result.grammarSummary == "测试句法要点")
        let call = try #require(spyAI.lineCalls.first)
        #expect(call.lineText == "目标句虚构原文")
        #expect(call.context == AILineContext(
            previousLine: "第一句虚构原文", nextLine: "第三句虚构原文", sourceLanguage: "ja"
        ))

        _ = try await service.explainLineWithAI(document: document, lineId: line1.id, songTitle: nil, artist: nil)
        #expect(spyAI.lineCalls.last?.context.previousLine == nil)
        #expect(spyAI.lineCalls.last?.context.nextLine == "目标句虚构原文")

        _ = try await service.explainLineWithAI(document: document, lineId: line5.id, songTitle: nil, artist: nil)
        #expect(spyAI.lineCalls.last?.context.previousLine == "目标句虚构原文")
        #expect(spyAI.lineCalls.last?.context.nextLine == nil)

        let missingId = UUID()
        do {
            _ = try await service.explainLineWithAI(document: document, lineId: missingId, songTitle: nil, artist: nil)
            Issue.record("未知 lineId 应抛出 lineNotFound")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .editingError(.lineNotFound(lineId: missingId)))
        }
    }

    @Test("saveWord：同词条不同歌词位置自动归并并保留多条原声出处")
    func saveWordMergesOccurrencesAcrossPositions() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let line1 = LyricLine(startMs: 2_000, text: "She was running fast")
        let line2 = LyricLine(startMs: 6_000, text: "Then she ran home")
        let doc = LyricDocument(sourceLanguage: "en", sourceFormat: .lrc, lines: [line1, line2])
        try await store.save(document: doc, binding: SongBinding(track: Fixture.trackA, lyricDocumentId: doc.id))

        let service = Self.makeService(store: store)
        let firstEntry = VocabularyEntry(
            surface: "running", lemma: "run", language: "en", partOfSpeech: "动词", generalMeaning: "奔跑",
            examples: [VocabularyExample(text: "Run every morning.", translation: "每天早晨跑步。")],
            mastery: .learning, createdAt: "2026-03-01T10:00:00Z", updatedAt: "2026-03-01T10:00:00Z"
        )
        let firstOcc = VocabularyOccurrence(
            entryId: firstEntry.id, lyricDocumentId: doc.id, lineId: line1.id, utf16Location: 8, utf16Length: 7,
            surfaceInLine: "running", contextualMeaning: "正在奔跑", lineTextSnapshot: line1.text,
            startMsSnapshot: line1.startMs, trackTitleHint: "虚构曲目甲", artistHint: "虚构歌手甲",
            createdAt: "2026-03-01T10:00:00Z"
        )
        let savedFirst = try await service.saveWord(entry: firstEntry, occurrence: firstOcc)

        let secondEntry = VocabularyEntry(
            surface: "ran", lemma: "run", reading: "ræn", language: "EN", generalMeaning: "跑；移动",
            examples: [
                VocabularyExample(text: "Run every morning.", translation: "每天早晨跑步。"),
                VocabularyExample(text: "She ran to the station.", translation: "她跑向车站。")
            ],
            userNote: "注意过去式变形", mastery: .reviewing,
            createdAt: "2026-03-02T10:00:00Z", updatedAt: "2026-03-02T10:00:00Z"
        )
        let secondOcc = VocabularyOccurrence(
            entryId: secondEntry.id, lyricDocumentId: doc.id, lineId: line2.id, utf16Location: 9, utf16Length: 3,
            surfaceInLine: "ran", contextualMeaning: "跑过（过去式）", lineTextSnapshot: line2.text,
            startMsSnapshot: line2.startMs, trackTitleHint: "虚构曲目甲", artistHint: "虚构歌手甲",
            createdAt: "2026-03-02T10:00:00Z"
        )
        let savedMerged = try await service.saveWord(entry: secondEntry, occurrence: secondOcc)

        #expect(savedMerged.id == savedFirst.id)
        #expect(savedMerged.reading == "ræn")
        #expect(savedMerged.userNote == "注意过去式变形")
        #expect(savedMerged.mastery == .reviewing)
        #expect(savedMerged.examples.count == 2)
        #expect(try await store.allVocabularyEntries().count == 1)

        let occurrences = try await store.vocabularyOccurrences(forEntryId: savedMerged.id)
        #expect(occurrences.count == 2)
        #expect(Set(occurrences.map(\.surfaceInLine)) == ["running", "ran"])

        let missingDocId = UUID()
        let invalidOcc = VocabularyOccurrence(
            entryId: savedMerged.id, lyricDocumentId: missingDocId, lineId: line1.id,
            surfaceInLine: "run", lineTextSnapshot: "missing"
        )
        do {
            _ = try await service.saveWord(entry: savedMerged, occurrence: invalidOcc)
            Issue.record("不存在的 lyricDocumentId 应抛出 documentNotFound")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .documentNotFound(missingDocId))
        }
    }

    @Test("saveLineStudyNote：乐观并发校验、清除 needsReview、递增 revision 并原子落库")
    func saveLineStudyNoteRevisionAndPersistence() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let line1 = LyricLine(startMs: 1_000, text: "测试第一句")
        let line2 = LyricLine(startMs: 3_000, text: "测试第二句")
        let boundDoc = LyricDocument(sourceLanguage: "ja", sourceFormat: .lrc, lines: [line1, line2])
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: boundDoc.id, userDelayMs: 300)
        try await store.save(document: boundDoc, binding: binding)

        let service = Self.makeService(store: store)
        let incomingNote = LineStudyNote(
            grammarSummary: "句法重点说明", singingTips: "注意断句", culturalNote: "虚构背景意象",
            source: .ai(model: "mock-study-model"), needsReview: true
        )

        let saved = try await service.saveLineStudyNote(
            documentId: boundDoc.id, expectedRevision: 1, lineId: line2.id, note: incomingNote
        )
        #expect(saved.revision == 2)
        #expect(saved.lines[1].studyNote?.grammarSummary == "句法重点说明")
        #expect(saved.lines[1].studyNote?.needsReview == false)
        #expect(try await store.document(id: boundDoc.id) == saved)
        #expect(try await store.binding(for: Fixture.trackA)?.userDelayMs == 300)

        let staleNote = LineStudyNote(grammarSummary: "应被拒绝的旧版本覆盖", source: .manual())
        do {
            _ = try await service.saveLineStudyNote(
                documentId: boundDoc.id, expectedRevision: 1, lineId: line2.id, note: staleNote
            )
            Issue.record("revision 不一致时应当抛出 revisionConflict")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .revisionConflict(documentId: boundDoc.id, storedRevision: 2, expectedRevision: 1))
        }
        #expect(try await store.document(id: boundDoc.id)?.lines[1].studyNote?.grammarSummary == "句法重点说明")

        let unboundLine = LyricLine(startMs: 1_000, text: "无绑定歌词行")
        let unboundDoc = LyricDocument(sourceLanguage: "en", sourceFormat: .lrc, lines: [unboundLine])
        try await store.save(document: unboundDoc, binding: SongBinding(track: Fixture.trackB, lyricDocumentId: unboundDoc.id))
        try await store.deleteBinding(for: Fixture.trackB)

        let savedUnbound = try await service.saveLineStudyNote(
            documentId: unboundDoc.id, expectedRevision: 1, lineId: unboundLine.id,
            note: LineStudyNote(grammarSummary: "无绑定整句笔记", source: .manual(), needsReview: true)
        )
        #expect(savedUnbound.revision == 2)
        #expect(savedUnbound.lines[0].studyNote?.needsReview == false)
        #expect(try await store.document(id: unboundDoc.id) == savedUnbound)
    }
}
