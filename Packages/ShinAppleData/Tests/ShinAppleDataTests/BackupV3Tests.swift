import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppleData

// Backup v3 升级测试：
// - v1 / v2 历史备份文件向后兼容解析与导入；
// - v3 含逐行注音（pronunciation）、整句笔记（studyNote）与生词本快照导出恢复往返；
// - 冲突预览新增/替换生词条与出处；
// - 导入时对本地不存在的 lyricDocumentId 自动置 nil 保护快照；
// - v3 拒绝矩阵（重复生词 id、悬空 entryId、非法时间戳、超限数组、未知键 warning）。

@Suite("Backup v3 与向后兼容")
struct BackupV3Tests {

    @Test("v1 与 v2 历史备份向后兼容解析并完整导入")
    func backwardCompatibleWithV1AndV2Backups() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let docV1Id = UUID()
        let lineV1Id = UUID()
        let v1JSON = Data("""
        {
          "schemaVersion": 1,
          "exportedAt": "\(Fixture.fixedTimestamp)",
          "documents": [{
            "schemaVersion": 1, "id": "\(docV1Id)", "revision": 1,
            "sourceFormat": "text", "sourceOffsetMs": 0, "metadata": {},
            "lines": [{"id": "\(lineV1Id)", "startMs": null, "text": "旧版一行", "translations": {}}],
            "createdAt": "\(Fixture.fixedTimestamp)", "updatedAt": "\(Fixture.fixedTimestamp)"
          }],
          "bindings": [{
            "trackKey": "apple-music:catalog:us:111111",
            "track": {"storefront": "us", "catalogSongId": "111111"},
            "lyricDocumentId": "\(docV1Id)", "userDelayMs": 0,
            "updatedAt": "\(Fixture.fixedTimestamp)"
          }],
          "settings": {}
        }
        """.utf8)
        let parsedV1 = try store.parseBackup(v1JSON)
        #expect(parsedV1.warnings.isEmpty)
        #expect(parsedV1.file.schemaVersion == 1)
        #expect(parsedV1.file.vocabularyEntries == nil)
        try await store.importBackup(parsedV1)

        let docV2Id = UUID()
        let lineV2Id = UUID()
        let pid = "0011223344556677"
        let v2JSON = Data("""
        {
          "schemaVersion": 2,
          "exportedAt": "\(Fixture.fixedTimestamp)",
          "documents": [{
            "schemaVersion": 1, "id": "\(docV2Id)", "revision": 2,
            "sourceFormat": "lrc", "sourceOffsetMs": 100, "metadata": {},
            "lines": [{"id": "\(lineV2Id)", "startMs": 1200, "text": "v2 脚本曲目", "translations": {}}],
            "createdAt": "\(Fixture.fixedTimestamp)", "updatedAt": "\(Fixture.fixedTimestamp)"
          }],
          "bindings": [{
            "trackKey": "\(SongBinding.trackKey(persistentID: pid))",
            "persistentId": "\(pid)",
            "lyricDocumentId": "\(docV2Id)", "userDelayMs": -50,
            "updatedAt": "\(Fixture.fixedTimestamp)"
          }],
          "settings": {}
        }
        """.utf8)
        let parsedV2 = try store.parseBackup(v2JSON)
        #expect(parsedV2.warnings.isEmpty)
        #expect(parsedV2.file.schemaVersion == 2)
        try await store.importBackup(parsedV2)

        #expect(try await store.document(id: docV1Id)?.lines.first?.pronunciation == nil)
        #expect(try await store.binding(forTrackKey: SongBinding.trackKey(persistentID: pid))?.userDelayMs == -50)
    }

    @Test("v3 含注音、学习笔记与生词本导出恢复往返逐字段一致且字节确定")
    func v3StudyAndVocabularyRoundTrip() async throws {
        let dirA = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirA) }
        let dirB = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dirB) }

        let storeA = try TestEnv.makeStore(dirA)
        let doc = makeStudyDocument()
        let binding = SongBinding(
            persistentID: "AABBCCDDEEFF0011",
            lyricDocumentId: doc.id,
            userDelayMs: 120,
            titleHint: "学习示例曲"
        )
        try await storeA.save(document: doc, binding: binding)

        let entry = VocabularyEntry(
            surface: "紙飛行機", lemma: "紙飛行機", reading: "かみひこうき",
            language: "ja", partOfSpeech: "名詞", generalMeaning: "纸飞机",
            examples: [VocabularyExample(text: "青い紙飛行機が飛ぶ", translation: "蓝色纸飞机在飞翔")],
            userNote: "注意连浊",
            mastery: .reviewing,
            createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let linkedOcc = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: doc.id, lineId: doc.lines[0].id,
            utf16Location: 2, utf16Length: 4, surfaceInLine: "紙飛行機",
            contextualMeaning: "承载愿望的纸飞机", lineTextSnapshot: doc.lines[0].text,
            lineTranslationSnapshot: "蓝色纸飞机在飞翔", startMsSnapshot: 1_000,
            trackKeyHint: binding.trackKey, trackTitleHint: "学习示例曲", artistHint: "虚构歌手",
            createdAt: Fixture.fixedTimestamp
        )
        let detachedOcc = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: nil, lineId: nil,
            utf16Location: 0, utf16Length: 4, surfaceInLine: "紙飛行機",
            contextualMeaning: "已删文档保留快照", lineTextSnapshot: "白い紙飛行機",
            createdAt: Fixture.fixedTimestamp
        )
        _ = try await storeA.saveVocabulary(entry: entry, occurrence: linkedOcc)
        _ = try await storeA.saveVocabulary(entry: entry, occurrence: detachedOcc)

        let exportData = try await storeA.exportBackup(at: Fixture.fixedDate)
        let exported = try JSONDecoder().decode(BackupFile.self, from: exportData)
        #expect(exported.schemaVersion == 3)
        #expect(exported.vocabularyEntries == [entry])
        #expect(exported.vocabularyOccurrences?.count == 2)

        let storeB = try TestEnv.makeStore(dirB)
        let parsed = try storeB.parseBackup(exportData)
        #expect(parsed.warnings.isEmpty)

        let preview = try await storeB.backupConflictPreview(for: parsed)
        #expect(!preview.isEmpty)
        #expect(preview.documentsToAdd == [doc])
        #expect(preview.vocabularyEntriesToAdd == [entry])
        #expect(preview.vocabularyOccurrencesToAdd.count == 2)

        try await storeB.importBackup(parsed)
        #expect(try await storeB.document(id: doc.id) == doc)
        #expect(try await storeB.allVocabularyEntries() == [entry])
        #expect(try await storeB.allVocabularyOccurrences().count == 2)
        #expect(try await storeB.backupConflictPreview(for: parsed).isEmpty)

        let exportB = try await storeB.exportBackup(at: Fixture.fixedDate)
        #expect(exportB == exportData)
    }

    @Test("v3 冲突预览：识别生词条与出处的替换项")
    func v3ConflictPreviewDetectsReplacements() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let doc = makeStudyDocument()
        try await store.save(document: doc, binding: Fixture.binding(Fixture.trackA, to: doc))
        let entry1 = VocabularyEntry(
            surface: "紙飛行機", language: "ja", generalMeaning: "纸飞机",
            createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let occ1 = VocabularyOccurrence(
            entryId: entry1.id, lyricDocumentId: doc.id, lineId: doc.lines[0].id,
            utf16Location: 2, utf16Length: 4, surfaceInLine: "紙飛行機",
            contextualMeaning: "旧语境", lineTextSnapshot: doc.lines[0].text,
            createdAt: Fixture.fixedTimestamp
        )
        _ = try await store.saveVocabulary(entry: entry1, occurrence: occ1)

        var updatedEntry1 = entry1
        updatedEntry1.userNote = "新增笔记"
        var updatedOcc1 = occ1
        updatedOcc1.contextualMeaning = "新语境"
        let entry2 = VocabularyEntry(
            surface: "雲", language: "ja", generalMeaning: "云",
            createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let backup = BackupFile(
            exportedAt: Fixture.fixedTimestamp,
            documents: [doc],
            bindings: [BackupBinding(from: Fixture.binding(Fixture.trackA, to: doc))],
            settings: [:],
            vocabularyEntries: [updatedEntry1, entry2],
            vocabularyOccurrences: [updatedOcc1]
        )
        let data = try JSONEncoder().encode(backup)
        let parsed = try store.parseBackup(data)
        let preview = try await store.backupConflictPreview(for: parsed)

        #expect(preview.vocabularyEntriesToAdd == [entry2])
        #expect(preview.vocabularyEntriesToReplace == [
            BackupVocabularyEntryReplacement(existing: entry1, incoming: updatedEntry1)
        ])
        #expect(preview.vocabularyOccurrencesToAdd.isEmpty)
        #expect(preview.vocabularyOccurrencesToReplace == [
            BackupVocabularyOccurrenceReplacement(existing: occ1, incoming: updatedOcc1)
        ])
    }

    @Test("v3 导入外键保护：occurrence.lyricDocumentId 在本地不存在时置 nil 保留快照")
    func importNullifiesMissingOccurrenceDocumentReference() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)

        let entry = VocabularyEntry(
            surface: "星", language: "ja", generalMeaning: "星辰",
            createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let missingDocId = UUID()
        let occurrence = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: missingDocId, lineId: UUID(),
            utf16Location: 0, utf16Length: 1, surfaceInLine: "星",
            contextualMeaning: "闪烁的星", lineTextSnapshot: "星が光る",
            trackTitleHint: "已删歌词的歌曲", createdAt: Fixture.fixedTimestamp
        )
        let backup = BackupFile(
            exportedAt: Fixture.fixedTimestamp, documents: [], bindings: [], settings: [:],
            vocabularyEntries: [entry], vocabularyOccurrences: [occurrence]
        )
        let data = try JSONEncoder().encode(backup)
        let parsed = try store.parseBackup(data)
        try await store.importBackup(parsed)

        let restored = try await store.allVocabularyOccurrences()
        #expect(restored.count == 1)
        #expect(restored[0].id == occurrence.id)
        #expect(restored[0].lyricDocumentId == nil)
        #expect(restored[0].lineTextSnapshot == "星が光る")
        #expect(restored[0].trackTitleHint == "已删歌词的歌曲")
    }

    @Test("v3 拒绝矩阵：重复 id 与悬空 entryId 拒绝且原库不变")
    func v3RejectionMatrixDuplicatesAndDangling() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let baseData = try makeBaseV3BackupData()

        // 1) 重复 vocabularyEntry.id
        let dupEntryData = try patchJSON(baseData) { root in
            var entries = root["vocabularyEntries"] as? [[String: Any]] ?? []
            if let first = entries.first { entries.append(first) }
            root["vocabularyEntries"] = entries
        }
        #expect(firstBackupRejection(dupEntryData, store) != nil)
        #expect(try await store.currentSnapshot() == before)

        // 2) 重复 vocabularyOccurrence.id
        let dupOccData = try patchJSON(baseData) { root in
            var occs = root["vocabularyOccurrences"] as? [[String: Any]] ?? []
            if let first = occs.first { occs.append(first) }
            root["vocabularyOccurrences"] = occs
        }
        #expect(firstBackupRejection(dupOccData, store) != nil)
        #expect(try await store.currentSnapshot() == before)

        // 3) occurrence 引用不存在的 entryId
        let danglingEntryData = try patchJSON(baseData) { root in
            var occs = root["vocabularyOccurrences"] as? [[String: Any]] ?? []
            if !occs.isEmpty { occs[0]["entryId"] = UUID().uuidString }
            root["vocabularyOccurrences"] = occs
        }
        #expect(firstBackupRejection(danglingEntryData, store) != nil)
        #expect(try await store.currentSnapshot() == before)
    }

    @Test("v3 拒绝矩阵与未知键 warning：非法时间戳、超限数组与未知键提示")
    func v3RejectsBadTimestampsAndLimits() async throws {
        let dir = try TestEnv.makeTempDirectory()
        defer { TestEnv.cleanup(dir) }
        let store = try TestEnv.makeStore(dir)
        let before = try await seedBackupFixture(store)
        let baseData = try makeBaseV3BackupData()

        // 1) 非法时间戳（生词条与 studyNote）
        let badEntryTime = try patchJSON(baseData) { root in
            var entries = root["vocabularyEntries"] as? [[String: Any]] ?? []
            if !entries.isEmpty { entries[0]["updatedAt"] = "不是时间" }
            root["vocabularyEntries"] = entries
        }
        await expectBackupRejection(
            badEntryTime, from: store,
            equals: .invalidTimestamp(path: "root.vocabularyEntries[0].updatedAt", value: "不是时间"),
            librarySnapshot: before
        )

        let badNoteTime = try patchJSON(baseData) { root in
            var docs = root["documents"] as? [[String: Any]] ?? []
            var lines = docs[0]["lines"] as? [[String: Any]] ?? []
            var note = lines[0]["studyNote"] as? [String: Any] ?? [:]
            note["updatedAt"] = "bad-date"
            lines[0]["studyNote"] = note
            docs[0]["lines"] = lines
            root["documents"] = docs
        }
        await expectBackupRejection(
            badNoteTime, from: store,
            equals: .invalidTimestamp(path: "root.documents[0].lines[0].studyNote.updatedAt", value: "bad-date"),
            librarySnapshot: before
        )

        // 2) 超限数组（maxVocabularyEntries = 0）
        let tinyLimits = BackupConfiguration(limits: BackupLimits(
            maxBytes: 2 * 1024 * 1024, maxDocuments: 100, maxBindings: 100,
            maxTotalLines: 100, maxSettingsEntries: 10, maxDepth: 32,
            maxUnknownArrayLength: 100, maxVocabularyEntries: 0, maxVocabularyOccurrences: 100
        ))
        await expectBackupRejection(
            baseData, from: store, configuration: tinyLimits,
            equals: .oversizedArray(path: "root.vocabularyEntries", count: 1, limit: 0),
            librarySnapshot: before
        )

        // 3) pronunciation / vocabularyEntry 未知键产生 warning 但不阻碍合法字段导入
        let withUnknownKey = try patchJSON(baseData) { root in
            var entries = root["vocabularyEntries"] as? [[String: Any]] ?? []
            entries[0]["futureField"] = "x"
            root["vocabularyEntries"] = entries
            var docs = root["documents"] as? [[String: Any]] ?? []
            var lines = docs[0]["lines"] as? [[String: Any]] ?? []
            var pron = lines[0]["pronunciation"] as? [String: Any] ?? [:]
            pron["extraPronField"] = "y"
            lines[0]["pronunciation"] = pron
            docs[0]["lines"] = lines
            root["documents"] = docs
        }
        let parsedWarning = try store.parseBackup(withUnknownKey)
        #expect(parsedWarning.warnings.contains(.unknownKey(path: "root.vocabularyEntries[0]", key: "futureField")))
        #expect(parsedWarning.warnings.contains(
            .unknownKey(path: "root.documents[0].lines[0].pronunciation", key: "extraPronField")
        ))
    }

    private func makeBaseV3BackupData() throws -> Data {
        let doc = makeStudyDocument()
        let entry = VocabularyEntry(
            surface: "風", language: "ja", generalMeaning: "风",
            createdAt: Fixture.fixedTimestamp, updatedAt: Fixture.fixedTimestamp
        )
        let occ = VocabularyOccurrence(
            entryId: entry.id, lyricDocumentId: doc.id, lineId: doc.lines[0].id,
            utf16Location: 0, utf16Length: 1, surfaceInLine: "風",
            lineTextSnapshot: doc.lines[0].text, createdAt: Fixture.fixedTimestamp
        )
        let baseBackup = BackupFile(
            exportedAt: Fixture.fixedTimestamp, documents: [doc], bindings: [], settings: [:],
            vocabularyEntries: [entry], vocabularyOccurrences: [occ]
        )
        return try JSONEncoder().encode(baseBackup)
    }

    private func makeStudyDocument() -> LyricDocument {
        let pronunciation = LinePronunciation(
            style: .romaji,
            text: "aoi kamihikouki ga tobu",
            source: .ai(model: "local-study-v1"),
            needsReview: true
        )
        let studyNote = LineStudyNote(
            grammarSummary: "「が」在此提示主语。",
            singingTips: "句尾轻收。",
            culturalNote: "纸飞机意象示例。",
            source: .manual(),
            needsReview: false,
            updatedAt: Fixture.fixedTimestamp
        )
        return LyricDocument(
            revision: 2,
            sourceLanguage: "ja",
            sourceFormat: .lrc,
            sourceOffsetMs: 0,
            originalFilename: "study-fixture.lrc",
            metadata: ["ti": ["学习示例曲"]],
            lines: [
                LyricLine(
                    startMs: 1_000,
                    text: "青い紙飛行機が飛ぶ",
                    translations: [
                        "zh-Hans": Translation(text: "蓝色纸飞机在飞翔", source: .manual, needsReview: false)
                    ],
                    pronunciation: pronunciation,
                    studyNote: studyNote
                )
            ],
            createdAt: Fixture.fixedTimestamp,
            updatedAt: Fixture.fixedTimestamp
        )
    }

    private func patchJSON(_ data: Data, mutate: (inout [String: Any]) -> Void) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Data()
        }
        mutate(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
