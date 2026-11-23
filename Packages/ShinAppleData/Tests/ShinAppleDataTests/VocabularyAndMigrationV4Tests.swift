import Foundation
import GRDB
import Testing
import ShinAppleKit
@testable import ShinAppleData

// v4 数据库迁移与生词本持久化测试。
// 全部使用原创虚构文本与临时库，覆盖：
// - v3 → v4 迁移保留原有歌词、绑定与设置；
// - 生词本 CRUD、排序、同词元去重合并、同位置出处幂等更新；
// - 删除歌词文档后保留历史生词快照（lyricDocumentId 置空）；
// - hasAnyContent 对生词本数据的感知。

@Suite("SQLite v4 迁移与生词本 CRUD")
struct VocabularyAndMigrationV4Tests {

    private func makeV3Store(
        _ directory: String,
        document: LyricDocument,
        binding: SongBinding
    ) throws -> GRDBLyricsStore {
        let path = TestEnv.storePath(in: directory)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Schema.v3Migrator().migrate(pool)
        let docRow = try LyricDocumentRow(from: document)
        let bindRow = SongBindingRow(from: binding)
        try pool.write { db in
            var writableDoc = docRow
            try writableDoc.save(db)
            var writableBind = bindRow
            try writableBind.save(db)
            var setting = SettingRow(key: "v3.migrated.key", value: "preserved")
            try setting.save(db)
        }
        try pool.close()
        return try GRDBLyricsStore(path: path)
    }

    @Test("v3 → v4 迁移：保留原有歌词、绑定与设置，并创建生词本表与索引")
    func v3ToV4MigrationPreservesExistingData() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }

        let doc = Fixture.documentA()
        let binding = SongBinding(
            persistentID: "0123456789ABCDEF",
            lyricDocumentId: doc.id,
            userDelayMs: 250,
            titleHint: "迁移测试曲目"
        )
        let store = try makeV3Store(dir, document: doc, binding: binding)

        #expect(try await store.allDocuments() == [doc])
        #expect(try await store.allBindings() == [binding])
        #expect(try await store.allDocumentSummaries().count == 1)
        #expect(try await store.settingValue(forKey: "v3.migrated.key") == "preserved")

        let entry = VocabularyEntry(
            surface: "紙飛行機",
            lemma: "紙飛行機",
            language: "ja",
            generalMeaning: "纸飞机",
            createdAt: Fixture.fixedTimestamp,
            updatedAt: Fixture.fixedTimestamp
        )
        let occurrence = VocabularyOccurrence(
            entryId: entry.id,
            lyricDocumentId: doc.id,
            lineId: doc.lines[0].id,
            utf16Location: 0,
            utf16Length: 4,
            surfaceInLine: "紙飛行機",
            contextualMeaning: "歌词中的纸飞机",
            lineTextSnapshot: doc.lines[0].text,
            createdAt: Fixture.fixedTimestamp
        )
        let saved = try await store.saveVocabulary(entry: entry, occurrence: occurrence)
        #expect(saved.id == entry.id)
        #expect(try await store.allVocabularyEntries() == [saved])
        #expect(try await store.vocabularyOccurrences(forDocumentId: doc.id).count == 1)

        // 验证 v4 索引名称全部存在。
        let pool = store.relocationSourcePool
        let indexNames = try await pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        }
        #expect(indexNames.contains("vocabularyEntry.on.lemma"))
        #expect(indexNames.contains("vocabularyEntry.on.updatedAt"))
        #expect(indexNames.contains("vocabularyOccurrence.on.entryId"))
        #expect(indexNames.contains("vocabularyOccurrence.on.documentAndLine"))
    }

    @Test("生词本 CRUD 与排序：updatedAt 降序、id 升序、更新与级联删除")
    func vocabularyCrudOrderingAndCascadeDelete() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let doc = Fixture.documentA()
        try await store.save(document: doc, binding: Fixture.binding(Fixture.trackA, to: doc))

        let olderTime = "2026-05-01T00:00:00Z"
        let newerTime = "2026-05-02T00:00:00Z"
        let lowUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highUUID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))

        let eOlder = VocabularyEntry(
            id: lowUUID, surface: "星明かり", language: "ja",
            generalMeaning: "星光", createdAt: olderTime, updatedAt: olderTime
        )
        let eTieHigh = VocabularyEntry(
            id: highUUID, surface: "風", language: "ja",
            generalMeaning: "风", createdAt: newerTime, updatedAt: newerTime
        )
        let eTieLow = VocabularyEntry(
            id: try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111")),
            surface: "雲", language: "ja",
            generalMeaning: "云", createdAt: newerTime, updatedAt: newerTime
        )
        _ = try await store.saveVocabulary(entry: eOlder, occurrence: nil)
        _ = try await store.saveVocabulary(entry: eTieHigh, occurrence: nil)
        _ = try await store.saveVocabulary(entry: eTieLow, occurrence: nil)

        let sorted = try await store.allVocabularyEntries()
        #expect(sorted.map(\.id) == [eTieLow.id, eTieHigh.id, eOlder.id])

        // 更新掌握程度与笔记。
        var edited = eOlder
        edited.mastery = .mastered
        edited.userNote = "已掌握该词"
        edited.updatedAt = "2026-05-03T00:00:00Z"
        try await store.updateVocabularyEntry(edited)
        let afterUpdate = try await store.allVocabularyEntries()
        #expect(afterUpdate.first?.id == eOlder.id)
        #expect(afterUpdate.first?.mastery == .mastered)

        let missingEntry = VocabularyEntry(surface: "不存在")
        await #expect(throws: ShinAppleDataError.documentNotFound(missingEntry.id)) {
            try await store.updateVocabularyEntry(missingEntry)
        }

        // 添加出处后单条删除出处（父词条保留），再级联删除词条。
        let occA = VocabularyOccurrence(
            entryId: eOlder.id, lyricDocumentId: doc.id, lineId: doc.lines[0].id,
            utf16Location: 0, utf16Length: 3, surfaceInLine: "星明かり",
            lineTextSnapshot: doc.lines[0].text, createdAt: olderTime
        )
        let occB = VocabularyOccurrence(
            entryId: eOlder.id, lyricDocumentId: doc.id, lineId: doc.lines[1].id,
            utf16Location: 1, utf16Length: 3, surfaceInLine: "星明かり",
            lineTextSnapshot: doc.lines[1].text, createdAt: newerTime
        )
        _ = try await store.saveVocabulary(entry: edited, occurrence: occA)
        _ = try await store.saveVocabulary(entry: edited, occurrence: occB)
        #expect(try await store.vocabularyOccurrences(forEntryId: eOlder.id).count == 2)

        try await store.deleteVocabularyOccurrence(id: occA.id)
        try await store.deleteVocabularyOccurrence(id: occA.id) // 幂等
        #expect(try await store.vocabularyOccurrences(forEntryId: eOlder.id).map(\.id) == [occB.id])

        try await store.deleteVocabularyEntry(id: eOlder.id)
        try await store.deleteVocabularyEntry(id: eOlder.id) // 幂等
        #expect(try await store.vocabularyOccurrences(forEntryId: eOlder.id).isEmpty)
        #expect(try await store.allVocabularyOccurrences().isEmpty)
    }

    @Test("同词元去重合并：保留原 id 与 createdAt，合并非空字段、例句且不降级掌握度")
    func deduplicatesAndMergesEntryByNormalizedLanguageAndLemma() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let t1 = "2026-06-01T08:00:00Z"
        let t2 = "2026-06-02T09:00:00Z"
        let ex1 = VocabularyExample(text: "We run fast.", translation: "我们跑得快。")
        let ex2 = VocabularyExample(text: "Run toward light.", translation: "奔向光明。")

        let first = VocabularyEntry(
            surface: "running",
            lemma: "run",
            language: "en",
            generalMeaning: "跑",
            examples: [ex1],
            mastery: .reviewing,
            createdAt: t1,
            updatedAt: t1
        )
        let savedFirst = try await store.saveVocabulary(entry: first, occurrence: nil)

        // 语言大小写/空白归一化、lemma 大小写归一化，且默认 .learning 不应覆盖 .reviewing。
        let incoming = VocabularyEntry(
            surface: "ran",
            lemma: " Run ",
            reading: "/rʌn/",
            language: " EN ",
            partOfSpeech: "Verb",
            generalMeaning: "奔跑；运行",
            examples: [ex1, ex2],
            userNote: "注意不规则过去式",
            mastery: .learning,
            createdAt: t2,
            updatedAt: t2
        )
        let occurrence = VocabularyOccurrence(
            entryId: incoming.id,
            surfaceInLine: "ran",
            contextualMeaning: "在句中意为奔跑",
            lineTextSnapshot: "They ran under stars.",
            createdAt: t2
        )
        let merged = try await store.saveVocabulary(entry: incoming, occurrence: occurrence)

        #expect(merged.id == savedFirst.id)
        #expect(merged.createdAt == t1)
        #expect(merged.updatedAt == t2)
        #expect(merged.surface == "running")
        #expect(merged.reading == "/rʌn/")
        #expect(merged.partOfSpeech == "Verb")
        #expect(merged.generalMeaning == "奔跑；运行")
        #expect(merged.examples == [ex1, ex2])
        #expect(merged.userNote == "注意不规则过去式")
        #expect(merged.mastery == .reviewing)

        let storedOccurrences = try await store.vocabularyOccurrences(forEntryId: savedFirst.id)
        #expect(storedOccurrences.count == 1)
        #expect(storedOccurrences[0].entryId == savedFirst.id)

        // 不同语言（如 language == nil）不错误合并。
        let unknownLang = VocabularyEntry(surface: "run", lemma: "run", language: nil, generalMeaning: "未指定语言")
        _ = try await store.saveVocabulary(entry: unknownLang, occurrence: nil)
        #expect(try await store.allVocabularyEntries().count == 2)
    }

    @Test("同位置出处幂等更新：同词条与 UTF-16 范围更新释义，不同偏移保留多条出处")
    func occurrenceAtSamePositionUpdatesIdempotently() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let doc = Fixture.documentA()
        try await store.save(document: doc, binding: Fixture.binding(Fixture.trackA, to: doc))
        let lineId = doc.lines[0].id

        let entry = VocabularyEntry(
            surface: "テスト", lemma: "テスト", language: "ja",
            generalMeaning: "测试", createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let occ1 = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: doc.id, lineId: lineId,
            utf16Location: 3, utf16Length: 2, surfaceInLine: "テスト",
            contextualMeaning: "初始语境", lineTextSnapshot: doc.lines[0].text,
            createdAt: Fixture.fixedTimestamp
        )
        let savedEntry = try await store.saveVocabulary(entry: entry, occurrence: occ1)

        // 同位置再次保存：幂等更新 contextualMeaning 与快照，不增加条数。
        let occ1Updated = VocabularyOccurrence(
            entryId: UUID(), lyricDocumentId: doc.id, lineId: lineId,
            utf16Location: 3, utf16Length: 2, surfaceInLine: "テスト",
            contextualMeaning: "修订后语境", lineTextSnapshot: doc.lines[0].text,
            lineTranslationSnapshot: "更新后的行译文", startMsSnapshot: 1_000,
            createdAt: "2026-06-02T00:00:00Z"
        )
        _ = try await store.saveVocabulary(entry: entry, occurrence: occ1Updated)

        // 同一行不同位置（重复词语）：保留为第二条独立出处。
        let occ2 = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: doc.id, lineId: lineId,
            utf16Location: 10, utf16Length: 2, surfaceInLine: "テスト",
            contextualMeaning: "句末再出现", lineTextSnapshot: doc.lines[0].text,
            createdAt: Fixture.fixedTimestamp
        )
        _ = try await store.saveVocabulary(entry: entry, occurrence: occ2)

        // 空 documentId/lineId 组合同样按 NULL 安全去重。
        let detached = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: nil, lineId: nil,
            utf16Location: 0, utf16Length: 2, surfaceInLine: "テスト",
            contextualMeaning: "离线句一", lineTextSnapshot: "テスト文",
            createdAt: Fixture.fixedTimestamp
        )
        let detachedUpdated = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: nil, lineId: nil,
            utf16Location: 0, utf16Length: 2, surfaceInLine: "テスト",
            contextualMeaning: "离线句二", lineTextSnapshot: "テスト文",
            createdAt: "2026-06-03T00:00:00Z"
        )
        _ = try await store.saveVocabulary(entry: entry, occurrence: detached)
        _ = try await store.saveVocabulary(entry: entry, occurrence: detachedUpdated)

        let allOccs = try await store.vocabularyOccurrences(forEntryId: savedEntry.id)
        #expect(allOccs.count == 3)
        let updatedFirst = try #require(allOccs.first { $0.id == occ1.id })
        #expect(updatedFirst.contextualMeaning == "修订后语境")
        #expect(updatedFirst.lineTranslationSnapshot == "更新后的行译文")
        #expect(updatedFirst.startMsSnapshot == 1_000)
        #expect(updatedFirst.createdAt == Fixture.fixedTimestamp)

        let detachedMatch = try #require(allOccs.first { $0.lyricDocumentId == nil })
        #expect(detachedMatch.contextualMeaning == "离线句二")
    }

    @Test("删除歌词文档后保留历史生词快照，并将 lyricDocumentId 置空")
    func deletingLyricDocumentNullifiesOccurrenceLinkAndKeepsSnapshot() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let doc = Fixture.documentA()
        let binding = Fixture.binding(Fixture.trackA, to: doc)
        try await store.save(document: doc, binding: binding)

        let entry = VocabularyEntry(
            surface: "第一句", lemma: "第一句", language: "zh-Hans",
            generalMeaning: "首句", createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let occurrence = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: doc.id, lineId: doc.lines[0].id,
            utf16Location: 0, utf16Length: 3, surfaceInLine: "第一句",
            contextualMeaning: "保留语境", lineTextSnapshot: "第一句测试文本",
            lineTranslationSnapshot: "第一句测试译文", startMsSnapshot: 1_000,
            trackKeyHint: binding.trackKey, trackTitleHint: "测试曲目甲", artistHint: "测试艺人",
            createdAt: Fixture.fixedTimestamp
        )
        let savedEntry = try await store.saveVocabulary(entry: entry, occurrence: occurrence)

        try await store.deleteDocument(id: doc.id, deletingAffectedBindings: true)

        #expect(try await store.document(id: doc.id) == nil)
        #expect(try await store.vocabularyOccurrences(forDocumentId: doc.id).isEmpty)
        let remaining = try await store.vocabularyOccurrences(forEntryId: savedEntry.id)
        #expect(remaining.count == 1)
        #expect(remaining[0].lyricDocumentId == nil)
        #expect(remaining[0].lineTextSnapshot == "第一句测试文本")
        #expect(remaining[0].lineTranslationSnapshot == "第一句测试译文")
        #expect(remaining[0].trackTitleHint == "测试曲目甲")
        #expect(remaining[0].contextualMeaning == "保留语境")
    }

    @Test("hasAnyContent 在仅有生词数据时返回 true")
    func hasAnyContentCountsVocabularyEntries() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        #expect(await store.hasAnyContent() == false)
        let entry = VocabularyEntry(surface: "空库测试词", language: "zh-Hans")
        let saved = try await store.saveVocabulary(entry: entry, occurrence: nil)
        #expect(await store.hasAnyContent() == true)
        try await store.deleteVocabularyEntry(id: saved.id)
        #expect(await store.hasAnyContent() == false)
    }
}
