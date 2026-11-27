import Foundation
import ShinAIProvider
import ShinAppleKit
import Testing
@testable import ShinAppServices

extension SpyAIStudyClient {
    func followUpLine(
        _ request: AILineFollowUpRequest, configuration: AIConfiguration, apiKey: String?
    ) async throws -> String {
        if let followUpHandler { return try await followUpHandler() }
        return "虚构回答"
    }
}

extension LyricsStudyServiceTests {
    @Test("整句解析缓存跨库重开可读，按实际上下文与模型匹配")
    func reusesCachedLineExplanation() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let previous = LyricLine(startMs: 1_000, text: "纸船藏进旧书")
        let target = LyricLine(startMs: 4_000, text: "慢慢把风装进口袋")
        let document = LyricDocument(sourceLanguage: "zh", sourceFormat: .lrc, lines: [previous, target])
        try await store.save(document: document, binding: SongBinding(track: Fixture.trackA, lyricDocumentId: document.id))

        let firstClient = SpyAIStudyClient()
        let firstService = Self.makeService(store: store, aiClient: firstClient)
        let expected = try await firstService.explainLineWithAI(document: document, lineId: target.id)
        #expect(firstClient.lineCalls.count == 1)

        let reopened = try TestEnv.openStore(in: dir)
        let secondClient = SpyAIStudyClient()
        let reopenedService = Self.makeService(store: reopened, aiClient: secondClient, apiKey: nil)
        var moved = document
        moved.lines[1].startMs = 7_000
        #expect(try await reopenedService.explainLineWithAI(document: moved, lineId: target.id) == expected)
        #expect(secondClient.lineCalls.isEmpty)

        var edited = moved
        edited.lines[0].text = "我把风筝留给旧书"
        _ = try await reopenedService.explainLineWithAI(document: edited, lineId: target.id)
        #expect(secondClient.lineCalls.count == 1)
        #expect(secondClient.lineCalls.last?.context.previousLine == edited.lines[0].text)

        let changedModel = AIConfiguration(preset: .openAI, modelName: "another-mock-model")
        _ = try await reopenedService.explainLineWithAI(
            document: document, lineId: target.id, configuration: changedModel
        )
        #expect(secondClient.lineCalls.count == 2)

        secondClient.lineHandler = { _, _, _, _ in
            AILineExplanation(grammarSummary: "重新解析得到不同的说明", keyExpressions: [])
        }
        let refreshed = try await reopenedService.explainLineWithAI(
            document: document, lineId: target.id, useCache: false
        )
        #expect(refreshed != expected)
        #expect(secondClient.lineCalls.count == 3)
        #expect(try await firstService.explainLineWithAI(document: document, lineId: target.id) == refreshed)
        #expect(firstClient.lineCalls.count == 1)
    }

    @Test("整句解析途中清空缓存，仍返回本次结果，下一次重新请求")
    func clearDuringLineExplanationKeepsResultWithoutSaving() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await Fixture.seedOldDocument(in: store)
        let line = document.lines[0]
        let peer = try TestEnv.openStore(in: dir)
        let client = SpyAIStudyClient()
        let expected = AILineExplanation(grammarSummary: "原创的整句模拟解析")
        client.lineHandler = { _, _, _, _ in
            try await peer.clearAIStudyCache()
            return expected
        }
        let service = Self.makeService(store: store, aiClient: client)
        #expect(try await service.explainLineWithAI(document: document, lineId: line.id) == expected)

        client.lineHandler = { _, _, _, _ in expected }
        #expect(try await service.explainLineWithAI(document: document, lineId: line.id) == expected)
        #expect(client.lineCalls.count == 2)
        #expect(try await service.explainLineWithAI(document: document, lineId: line.id) == expected)
        #expect(client.lineCalls.count == 2)
    }

    @Test("整句追问返回期间邻句被编辑时丢弃回答")
    func rejectsFollowUpAfterNeighborChanges() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let previous = LyricLine(startMs: 1_000, text: "晚上我走向旧城")
        let line = LyricLine(startMs: 2_000, text: "路灯把影子拉长")
        let document = LyricDocument(sourceLanguage: "zh", sourceFormat: .lrc, lines: [previous, line])
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)

        let client = SpyAIStudyClient()
        client.followUpHandler = {
            var edited = document
            edited.lines[0].text = "清晨我走向小站"
            edited.revision += 1
            try await store.updateDocument(edited)
            return "这一条回答已经过时。"
        }
        let service = Self.makeService(store: store, aiClient: client)
        await #expect(throws: AIStudyWorkflowError.cancelled) {
            try await service.followUpLineWithAI(
                document: document, lineId: line.id, analysis: nil, history: [], question: "用到了什么修辞？"
            )
        }
    }
}
