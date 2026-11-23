import Foundation
import Testing
@testable import ShinAppleKit

/// 学习注记（注音、讲解笔记）与生词领域模型测试。
/// 全部测试夹具均为原创虚构文本，不含任何真实歌词或个人数据。
@Suite("学习模型与向后兼容编解码")
struct StudyModelsTests {

    @Test("旧版不含 pronunciation 与 studyNote 的 LyricDocument JSON 可无损解码")
    func legacyLyricDocumentDecodesWithoutStudyFields() throws {
        let docId = UUID()
        let timedLineId = UUID()
        let untimedLineId = UUID()
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "id": "\(docId.uuidString)",
          "revision": 3,
          "sourceLanguage": "ja",
          "sourceFormat": "lrc",
          "sourceOffsetMs": 150,
          "originalText": "[00:01.00]青い紙飛行機が飛ぶ",
          "originalFilename": "fictional-study.lrc",
          "metadata": {
            "ti": ["纸飞机测试曲"]
          },
          "lines": [
            {
              "id": "\(timedLineId.uuidString)",
              "startMs": 1000,
              "text": "青い紙飛行機が飛ぶ",
              "translations": {
                "zh-Hans": {
                  "text": "蓝色纸飞机在飞翔",
                  "source": "manual",
                  "needsReview": false
                }
              }
            },
            {
              "id": "\(untimedLineId.uuidString)",
              "text": "未打轴的虚构尾注"
            }
          ],
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """

        let decoded = try JSONDecoder().decode(LyricDocument.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == docId)
        #expect(decoded.revision == 3)
        #expect(decoded.sourceLanguage == "ja")
        #expect(decoded.lines.count == 2)

        #expect(decoded.lines[0].id == timedLineId)
        #expect(decoded.lines[0].startMs == 1_000)
        #expect(decoded.lines[0].translations["zh-Hans"]?.text == "蓝色纸飞机在飞翔")
        #expect(decoded.lines[0].pronunciation == nil)
        #expect(decoded.lines[0].studyNote == nil)

        #expect(decoded.lines[1].id == untimedLineId)
        #expect(decoded.lines[1].startMs == nil)
        #expect(decoded.lines[1].translations.isEmpty)
        #expect(decoded.lines[1].pronunciation == nil)
        #expect(decoded.lines[1].studyNote == nil)
    }

    @Test("未设置 pronunciation 与 studyNote 的 LyricLine 编码时不写入多余键")
    func lyricLineOmitsNilStudyFieldsWhenEncoded() throws {
        let line = LyricLine(startMs: 2_500, text: "テスト用の虚構行")
        let data = try JSONEncoder().encode(line)
        let jsonObject = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(jsonObject["pronunciation"] == nil)
        #expect(jsonObject["studyNote"] == nil)
    }

    @Test("新版含注音与学习笔记的 LyricDocument 编解码往返一致")
    func modernLyricDocumentRoundTrip() throws {
        let pronunciation = LinePronunciation(
            style: .romaji,
            text: "aoi kamihikouki ga tobu",
            source: .ai(model: "local-study-model-v1"),
            needsReview: true
        )
        let studyNote = LineStudyNote(
            grammarSummary: "「が」在此提示自然现象或动作主语。",
            singingTips: "句尾「飛ぶ」轻收气，避免重读。",
            culturalNote: "纸飞机常用于象征朴素的童年愿望。",
            source: .manual(),
            needsReview: false,
            updatedAt: "2026-05-01T10:30:00Z"
        )
        let importedPronunciation = LinePronunciation(
            style: .furigana,
            text: "しろい くも の うえ",
            source: .imported(),
            needsReview: false
        )

        let document = LyricDocument(
            revision: 2,
            sourceLanguage: "ja",
            sourceFormat: .lrc,
            sourceOffsetMs: -100,
            metadata: ["ti": ["虚构学习示例曲"]],
            lines: [
                LyricLine(
                    startMs: 1_200,
                    text: "青い紙飛行機が飛ぶ",
                    translations: [
                        "zh-Hans": Translation(text: "蓝色纸飞机在飞翔", source: .manual, needsReview: false)
                    ],
                    pronunciation: pronunciation,
                    studyNote: studyNote
                ),
                LyricLine(
                    startMs: 4_800,
                    text: "白い雲の上",
                    pronunciation: importedPronunciation,
                    studyNote: nil
                ),
                LyricLine(
                    startMs: nil,
                    text: "静かな余白"
                )
            ],
            createdAt: "2026-05-01T10:00:00Z",
            updatedAt: "2026-05-01T10:30:00Z"
        )

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(LyricDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.lines[0].pronunciation?.source == .ai(model: "local-study-model-v1"))
        #expect(decoded.lines[0].studyNote?.singingTips == "句尾「飛ぶ」轻收气，避免重读。")
        #expect(decoded.lines[1].pronunciation?.source == .imported())
        #expect(decoded.lines[1].studyNote == nil)
        #expect(decoded.lines[2].pronunciation == nil)
    }

    @Test("PronunciationStyle 与 StudyAnnotationSource 属性完整")
    func pronunciationStyleAndSourceMetadata() {
        #expect(PronunciationStyle.allCases == [.romaji, .furigana, .ipa, .hangulRomanization, .custom])
        for style in PronunciationStyle.allCases {
            #expect(!style.displayName.isEmpty)
        }
        #expect(StudyAnnotationSource.manual() == StudyAnnotationSource(kind: .manual, model: nil))
        #expect(StudyAnnotationSource.ai(model: "demo-llm") == StudyAnnotationSource(kind: .ai, model: "demo-llm"))
        #expect(StudyAnnotationSource.imported() == StudyAnnotationSource(kind: .imported, model: nil))
    }

    @Test("VocabularyEntry 编解码往返与默认值一致")
    func vocabularyEntryRoundTripAndDefaults() throws {
        let entry = VocabularyEntry(
            id: UUID(),
            surface: "紙飛行機",
            lemma: "紙飛行機",
            reading: "かみひこうき",
            language: "ja",
            partOfSpeech: "名詞",
            generalMeaning: "纸飞机",
            examples: [
                VocabularyExample(text: "窓から紙飛行機を飛ばす。", translation: "从窗边放飞纸飞机。"),
                VocabularyExample(text: "机の上の紙飛行機。")
            ],
            userNote: "常见合成名词，注意连浊现象。",
            mastery: .reviewing,
            createdAt: "2026-06-01T08:00:00Z",
            updatedAt: "2026-06-02T09:15:00Z"
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VocabularyEntry.self, from: encoded)
        #expect(decoded == entry)

        let minimal = VocabularyEntry(surface: "星明かり")
        #expect(minimal.lemma == "星明かり")
        #expect(minimal.generalMeaning.isEmpty)
        #expect(minimal.examples.isEmpty)
        #expect(minimal.mastery == .learning)
        #expect(minimal.createdAt == minimal.updatedAt)
        #expect(LyricTimestamp.date(from: minimal.createdAt) != nil)

        for level in VocabularyMastery.allCases {
            #expect(!level.displayName.isEmpty)
        }
    }

    @Test("VocabularyOccurrence 编解码往返与语境快照一致")
    func vocabularyOccurrenceRoundTrip() throws {
        let entryId = UUID()
        let documentId = UUID()
        let lineId = UUID()
        let occurrence = VocabularyOccurrence(
            id: UUID(),
            entryId: entryId,
            lyricDocumentId: documentId,
            lineId: lineId,
            utf16Location: 2,
            utf16Length: 4,
            surfaceInLine: "紙飛行機",
            contextualMeaning: "比喻承载心意的纸飞机",
            lineTextSnapshot: "青い紙飛行機が飛ぶ",
            lineTranslationSnapshot: "蓝色纸飞机在飞翔",
            startMsSnapshot: 1_200,
            trackKeyHint: "music-script:persistent:AABBCCDDEEFF0011",
            trackTitleHint: "虚构测试曲",
            artistHint: "虚构演示歌手",
            createdAt: "2026-06-01T08:05:00Z"
        )

        let encoded = try JSONEncoder().encode(occurrence)
        let decoded = try JSONDecoder().decode(VocabularyOccurrence.self, from: encoded)
        #expect(decoded == occurrence)

        let minimal = VocabularyOccurrence(
            entryId: entryId,
            surfaceInLine: "飛ぶ",
            lineTextSnapshot: "青い紙飛行機が飛ぶ"
        )
        let minimalData = try JSONEncoder().encode(minimal)
        let decodedMinimal = try JSONDecoder().decode(VocabularyOccurrence.self, from: minimalData)
        #expect(decodedMinimal == minimal)
        #expect(decodedMinimal.utf16Location == 0)
        #expect(decodedMinimal.utf16Length == 0)
        #expect(decodedMinimal.lyricDocumentId == nil)
        #expect(decodedMinimal.lineId == nil)
        #expect(LyricTimestamp.date(from: decodedMinimal.createdAt) != nil)
    }

    @Test("LocalDictionaryLookupResult 值语义相等比较正常")
    func localDictionaryLookupResultEquality() {
        let first = LocalDictionaryLookupResult(
            query: "running",
            lemma: "run",
            partOfSpeech: "Verb",
            detectedLanguage: "en",
            systemDefinition: "Move at a speed faster than a walk."
        )
        let second = LocalDictionaryLookupResult(
            query: "running",
            lemma: "run",
            partOfSpeech: "Verb",
            detectedLanguage: "en",
            systemDefinition: "Move at a speed faster than a walk."
        )
        let minimal = LocalDictionaryLookupResult(query: "unknownword")
        #expect(first == second)
        #expect(first != minimal)
        #expect(minimal.lemma == nil)
    }
}
