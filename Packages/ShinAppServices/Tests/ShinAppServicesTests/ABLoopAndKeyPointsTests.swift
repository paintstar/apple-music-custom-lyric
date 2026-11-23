import Foundation
import os
import Testing
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
import ShinLyricsEngine
@testable import ShinAppServices

// Phase 4.1 单测：协调器句段查询、AB 循环状态机与全曲重点词汇提炼/批量入库。
// 全部使用原创虚构文本与注入 Mock，不访问真实网络。

private final class KeyPointsMockAIClient: AIStudyProviding, @unchecked Sendable {
    struct CapturedCall: Equatable, Sendable {
        let lineIds: [UUID]
        let sourceLanguage: String?
        let targetLanguage: String
        let apiKey: String?
    }

    typealias KeyPointsHandler = @Sendable (
        [LyricLine], String?, AIConfiguration, String?
    ) async throws -> [AIKeyStudyPoint]

    private let callsLock = OSAllocatedUnfairLock(initialState: [CapturedCall]())
    var keyPointsHandler: KeyPointsHandler?
    var capturedCalls: [CapturedCall] { callsLock.withLock { $0 } }

    func testConnection(configuration: AIConfiguration, apiKey: String?) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: configuration.modelName, replyPreview: "ok")
    }

    func explainWord(
        _ word: String, inLine lineText: String, sourceLanguage: String?,
        configuration: AIConfiguration, apiKey: String?
    ) async throws -> AIWordExplanation {
        AIWordExplanation(surface: word, lemma: word, contextualMeaning: "语境", generalMeaning: "通用")
    }

    func explainLine(
        _ lineText: String, context: AILineContext, configuration: AIConfiguration, apiKey: String?
    ) async throws -> AILineExplanation {
        AILineExplanation(grammarSummary: "句法")
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
    ) async throws -> [AIKeyStudyPoint] {
        callsLock.withLock {
            $0.append(CapturedCall(
                lineIds: lines.map(\.id),
                sourceLanguage: sourceLanguage,
                targetLanguage: configuration.preferredTargetLanguage,
                apiKey: apiKey
            ))
        }
        if let keyPointsHandler {
            return try await keyPointsHandler(lines, sourceLanguage, configuration, apiKey)
        }
        return []
    }
}

// MARK: - 协调器区间与 AB 循环状态机

@Suite("协调器区间查询与 AB 循环状态机")
struct PlaybackABLoopTests {

    private static let loopDocId = UUID()
    private static let loopLineA = UUID()
    private static let loopLineB = UUID()
    private static let loopTarget = LyricsABLoopTarget(
        documentId: loopDocId,
        trackKey: SongBinding.trackKey(for: Fixture.trackA),
        trackEpoch: 3,
        startLineId: loopLineA,
        endLineId: loopLineB,
        startLineText: "虚构起点",
        endLineText: "虚构终点"
    )
    private static let loopSegment = LyricsPlaybackSegment(startMs: 2_000, endMs: 5_000)

    private static func snapshot(
        track: CatalogIdentity = Fixture.trackA,
        epoch: Int = 3,
        positionMs: Int64?,
        durationMs: Int64? = 30_000,
        status: PlayerStatus = .playing
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            trackEpoch: epoch, track: track, positionMs: positionMs,
            durationMs: durationMs, status: status
        )
    }

    @Test("PlaybackLyricsCoordinator.playbackSegment 随当前延迟与曲目切换实时更新")
    func coordinatorPlaybackSegmentReflectsDelayAndTrackSwitch() async {
        let doc = LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            lines: [
                LyricLine(startMs: 1_000, text: "第一句虚构歌词"),
                LyricLine(startMs: 4_000, text: "第二句虚构歌词"),
                LyricLine(startMs: 8_000, text: "第三句虚构歌词")
            ]
        )
        let coordinator = PlaybackLyricsCoordinator(onDisplayChange: { _ in })
        coordinator.update(snapshot: Self.snapshot(epoch: 1, positionMs: 1_500, durationMs: 20_000))
        coordinator.applyLyrics(
            trackKey: SongBinding.trackKey(for: Fixture.trackA),
            trackEpoch: 1,
            document: doc,
            userDelayMs: 500
        )

        #expect(
            coordinator.playbackSegment(fromLineId: doc.lines[0].id, toLineId: doc.lines[1].id)
                == LyricsPlaybackSegment(startMs: 1_300, endMs: 8_300)
        )
        #expect(
            coordinator.playbackSegment(fromLineId: doc.lines[2].id, toLineId: doc.lines[2].id)
                == LyricsPlaybackSegment(startMs: 8_300, endMs: 20_000)
        )

        await coordinator.setDelay(0).value
        #expect(
            coordinator.playbackSegment(fromLineId: doc.lines[0].id, toLineId: doc.lines[1].id)
                == LyricsPlaybackSegment(startMs: 800, endMs: 7_800)
        )

        coordinator.update(snapshot: Self.snapshot(track: Fixture.trackB, epoch: 2, positionMs: 0))
        #expect(coordinator.playbackSegment(fromLineId: doc.lines[0].id, toLineId: doc.lines[1].id) == nil)
    }

    @Test("AB 循环状态机：到达/越过 endMs 触发一次回跳，冷却内不重发，冷却后再次触发")
    func evaluatorTriggersSeekOnceAndRespectsCooldown() {
        let provider: (UUID, UUID) -> LyricsPlaybackSegment? = { _, _ in Self.loopSegment }
        var evaluator = LyricsABLoopEvaluator(seekCooldownMs: 900)

        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 5_000),
            currentDocumentId: Self.loopDocId,
            segmentProvider: provider,
            nowMonotonicMs: 1_000
        ) == .none)

        evaluator.setPendingAnchor(Self.loopLineA)
        #expect(evaluator.pendingAnchorLineId == Self.loopLineA)
        evaluator.activate(Self.loopTarget)
        #expect(evaluator.pendingAnchorLineId == nil)

        // 区间内（含早于 startMs）不触发
        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 1_500),
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 1_100
        ) == .none)
        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 4_999),
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 1_200
        ) == .none)

        // 到达 endMs 触发一次 seekTo(startMs)
        let firstSnap = Self.snapshot(positionMs: 5_000)
        #expect(evaluator.evaluate(
            snapshot: firstSnap,
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 2_000
        ) == .seekTo(ms: 2_000, expectedSnapshot: firstSnap))
        #expect(evaluator.lastSeekTriggerMonotonicMs == 2_000)

        // 冷却窗口内重复到达/越过 endMs 不重触发
        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 5_150),
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 2_400
        ) == .none)
        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 5_300),
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 2_899
        ) == .none)

        // 冷却期结束后下一轮再次越界 → 再次触发回跳
        let secondSnap = Self.snapshot(positionMs: 5_020)
        #expect(evaluator.evaluate(
            snapshot: secondSnap,
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 2_900
        ) == .seekTo(ms: 2_000, expectedSnapshot: secondSnap))
        #expect(evaluator.lastSeekTriggerMonotonicMs == 2_900)
    }

    @Test("AB 循环状态机：暂停/未知位置/区间无效不触发；切歌/epoch/换文档自动返回 .clear")
    func evaluatorPausesSafelyAndClearsOnContextChange() {
        let provider: (UUID, UUID) -> LyricsPlaybackSegment? = { _, _ in Self.loopSegment }
        var evaluator = LyricsABLoopEvaluator()
        evaluator.activate(Self.loopTarget)

        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 5_500, status: .paused),
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 1_000
        ) == .none)
        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: nil, status: .playing),
            currentDocumentId: Self.loopDocId, segmentProvider: provider, nowMonotonicMs: 1_100
        ) == .none)
        #expect(evaluator.evaluate(
            snapshot: Self.snapshot(positionMs: 5_500, status: .playing),
            currentDocumentId: Self.loopDocId, segmentProvider: { _, _ in nil }, nowMonotonicMs: 1_200
        ) == .none)
        #expect(evaluator.activeTarget == Self.loopTarget)

        let clearCases: [(PlaybackSnapshot, UUID?)] = [
            (Self.snapshot(track: Fixture.trackB, epoch: 3, positionMs: 5_500), Self.loopDocId),
            (Self.snapshot(track: Fixture.trackA, epoch: 4, positionMs: 5_500), Self.loopDocId),
            (Self.snapshot(track: Fixture.trackA, epoch: 3, positionMs: 5_500), UUID()),
            (Self.snapshot(track: Fixture.trackA, epoch: 3, positionMs: 5_500), nil)
        ]
        for (snap, docId) in clearCases {
            var caseEvaluator = LyricsABLoopEvaluator()
            caseEvaluator.activate(Self.loopTarget)
            #expect(caseEvaluator.evaluate(
                snapshot: snap, currentDocumentId: docId, segmentProvider: provider, nowMonotonicMs: 2_000
            ) == .clear)
            #expect(caseEvaluator.activeTarget == nil)
        }
    }
}

// MARK: - 全曲重点词汇提炼与批量入库

@Suite("全曲重点词汇提炼与批量入库")
struct AIKeyStudyPointsTests {

    private static func makeService(
        store: GRDBLyricsStore,
        client: KeyPointsMockAIClient
    ) -> AIStudyWorkflowService {
        AIStudyWorkflowService(
            store: store,
            aiClient: client,
            configurationProvider: {
                AIConfiguration(preset: .openAI, modelName: "mock-model", preferredTargetLanguage: "zh-Hans")
            },
            apiKeyProvider: { "mock-key-for-tests" }
        )
    }

    @Test("extractKeyStudyPoints：过滤空白行并映射提供商错误与取消")
    func extractKeyStudyPointsFiltersBlankLinesAndMapsErrors() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let line1 = LyricLine(startMs: 1_000, text: "🎵青い紙飛行機が飛ぶ")
        let blankLine = LyricLine(startMs: 2_500, text: "  \n\t ")
        let line2 = LyricLine(startMs: 4_000, text: "風を越えて駆け抜ける")
        let doc = LyricDocument(sourceLanguage: "ja", sourceFormat: .lrc, lines: [line1, blankLine, line2])
        let expected = AIKeyStudyPoint(
            lineId: line1.id, surface: "青い", lemma: "青い", reading: "あおい",
            partOfSpeech: "形容词", contextualMeaning: "澄澈蔚蓝的", generalMeaning: "蓝色的"
        )
        let client = KeyPointsMockAIClient()
        client.keyPointsHandler = { _, _, _, _ in [expected] }

        let service = Self.makeService(store: store, client: client)
        let result = try await service.extractKeyStudyPoints(for: doc, songTitle: "虚构曲目", artist: "虚构歌手")
        #expect(result == [expected])
        #expect(client.capturedCalls == [.init(
            lineIds: [line1.id, line2.id], sourceLanguage: "ja",
            targetLanguage: "zh-Hans", apiKey: "mock-key-for-tests"
        )])

        let emptyDoc = LyricDocument(sourceFormat: .lrc, lines: [LyricLine(startMs: 1_000, text: "   ")])
        do {
            _ = try await service.extractKeyStudyPoints(for: emptyDoc)
            Issue.record("全空白歌词应当抛出 emptyLyrics")
        } catch let error as AIStudyWorkflowError { #expect(error == .emptyLyrics) }

        client.keyPointsHandler = { _, _, _, _ in throw AIProviderError.httpError(statusCode: 429, message: "limit") }
        do {
            _ = try await service.extractKeyStudyPoints(for: doc)
            Issue.record("应当映射 AIProviderError")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .providerError(.httpError(statusCode: 429, message: "limit")))
        }

        client.keyPointsHandler = { _, _, _, _ in throw CancellationError() }
        do {
            _ = try await service.extractKeyStudyPoints(for: doc)
            Issue.record("应当映射 CancellationError")
        } catch let error as AIStudyWorkflowError { #expect(error == .cancelled) }
    }

    @Test("saveKeyStudyPoints：提取行快照、UTF-16 词段偏移并按词元归并入库")
    func saveKeyStudyPointsMergesAndStoresRanges() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        // "🎵" 占 2 个 UTF-16 码元，验证 UTF-16 偏移与同词元跨行归并
        let line1 = LyricLine(
            startMs: 1_200,
            text: "🎵She was running fast",
            translations: ["zh-Hans": Translation(text: "她正飞快奔跑", source: .manual)]
        )
        let line2 = LyricLine(
            startMs: 4_800,
            text: "Then she ran far away",
            translations: ["zh-Hans": Translation(text: "随后她跑向远方", source: .imported)]
        )
        let line3 = LyricLine(
            startMs: 8_000,
            text: "Quiet river flows",
            translations: ["en": Translation(text: "静谧河流淌", source: .imported)]
        )
        let doc = LyricDocument(sourceLanguage: "en", sourceFormat: .lrc, lines: [line1, line2, line3])
        let trackKey = SongBinding.trackKey(for: Fixture.trackA)
        try await store.save(document: doc, binding: SongBinding(track: Fixture.trackA, lyricDocumentId: doc.id))

        let points = [
            AIKeyStudyPoint(
                lineId: line1.id, surface: "running", lemma: "run", reading: "ˈrʌnɪŋ",
                partOfSpeech: "动词", contextualMeaning: "正在奔跑", generalMeaning: "奔跑"
            ),
            AIKeyStudyPoint(
                lineId: line2.id, surface: "Ran", lemma: "run", reading: "ræn",
                partOfSpeech: "动词", contextualMeaning: "跑向远方", generalMeaning: "跑；移动"
            ),
            AIKeyStudyPoint(
                lineId: line3.id, surface: "flowing", lemma: "flow",
                contextualMeaning: "缓缓流淌", generalMeaning: "流动"
            ),
            AIKeyStudyPoint(
                lineId: nil, surface: "far away", lemma: "far away",
                contextualMeaning: "在遥远之处", generalMeaning: "遥远地"
            ),
            AIKeyStudyPoint(lineId: line1.id, surface: "   ", lemma: "", contextualMeaning: "无效", generalMeaning: "无效")
        ]

        let service = Self.makeService(store: store, client: KeyPointsMockAIClient())
        let savedCount = try await service.saveKeyStudyPoints(
            points, in: doc, trackKeyHint: trackKey, trackTitleHint: "虚构曲目甲", artistHint: "虚构歌手甲"
        )
        #expect(savedCount == 4)

        let entries = try await store.allVocabularyEntries()
        #expect(entries.count == 3)

        let runEntry = try #require(entries.first { $0.lemma == "run" })
        let runOccs = try await store.vocabularyOccurrences(forEntryId: runEntry.id)
        #expect(runOccs.count == 2)

        let occRunning = try #require(runOccs.first { $0.lineId == line1.id })
        #expect(occRunning.utf16Location == 10)
        #expect(occRunning.utf16Length == 7)
        #expect(occRunning.lineTextSnapshot == line1.text)
        #expect(occRunning.lineTranslationSnapshot == "她正飞快奔跑")
        #expect(occRunning.startMsSnapshot == 1_200)
        #expect(occRunning.trackKeyHint == trackKey)

        let occRan = try #require(runOccs.first { $0.lineId == line2.id })
        #expect(occRan.utf16Location == 9)
        #expect(occRan.utf16Length == 3)
        #expect(occRan.surfaceInLine == "ran")
        #expect(occRan.startMsSnapshot == 4_800)

        let flowEntry = try #require(entries.first { $0.lemma == "flow" })
        let flowOcc = try #require(try await store.vocabularyOccurrences(forEntryId: flowEntry.id).first)
        #expect(flowOcc.utf16Location == 0)
        #expect(flowOcc.utf16Length == 0)
        #expect(flowOcc.lineTranslationSnapshot == "静谧河流淌")

        let farEntry = try #require(entries.first { $0.lemma == "far away" })
        let farOcc = try #require(try await store.vocabularyOccurrences(forEntryId: farEntry.id).first)
        #expect(farOcc.lineId == nil)
        #expect(farOcc.utf16Location == 0)
        #expect(farOcc.utf16Length == 0)
        #expect(farOcc.lineTextSnapshot.isEmpty)
    }

    @Test("saveKeyStudyPoints：空列表返回 0，未入库文档映射 documentNotFound")
    func saveKeyStudyPointsEmptyAndMissingDocument() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }

        let unsavedDoc = LyricDocument(
            sourceLanguage: "ja", sourceFormat: .lrc,
            lines: [LyricLine(startMs: 1_000, text: "未入库测试行")]
        )
        let service = Self.makeService(store: store, client: KeyPointsMockAIClient())

        #expect(try await service.saveKeyStudyPoints(
            [], in: unsavedDoc, trackKeyHint: nil, trackTitleHint: nil, artistHint: nil
        ) == 0)

        let point = AIKeyStudyPoint(
            lineId: unsavedDoc.lines[0].id, surface: "未入库", lemma: "未入库",
            contextualMeaning: "语境", generalMeaning: "通用"
        )
        do {
            _ = try await service.saveKeyStudyPoints(
                [point], in: unsavedDoc, trackKeyHint: nil, trackTitleHint: nil, artistHint: nil
            )
            Issue.record("文档不存在时应抛出 documentNotFound")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .documentNotFound(unsavedDoc.id))
        }
    }
}
