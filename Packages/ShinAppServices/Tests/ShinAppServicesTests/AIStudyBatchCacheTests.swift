import Foundation
import os
import Testing
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
@testable import ShinAppServices

extension AIStudyWorkflowTests {
    @Test("41 行重开与重新打开数据库复用 5 批；时间轴无影响，文本、语言和模型参与匹配")
    func translationBatchesReuseAfterReopening() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let document = try await seedBatchDocument(in: store)
        let task = AIStudyBatchTaskKind.translation(targetLanguage: "zh-Hans")
        let firstClient = MockAIStudyClient()
        let requestedPresets = OSAllocatedUnfairLock(initialState: [AIProviderPreset]())
        let service = AIStudyWorkflowService(
            store: store, aiClient: firstClient,
            configurationProvider: { AIConfiguration(preset: .openAI, modelName: "mock-model") },
            configuredAPIKeyProvider: { preset in
                requestedPresets.withLock { $0.append(preset) }
                return nil
            }
        )
        let first = try await service.generatePreview(for: document, task: task)
        #expect(firstClient.translationBatchCalls.map(\.count) == [10, 10, 10, 10, 1])
        #expect(first.count == 41)
        #expect(first.allSatisfy { !$0.generatedText.isEmpty })
        #expect(try await service.cachedPreview(for: document, task: task) == first)
        #expect(try await service.generatePreview(for: document, task: task) == first)
        #expect(firstClient.translationBatchCalls.count == 5)
        #expect(requestedPresets.withLock { $0 } == [.openAI])

        let reopened = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let secondClient = MockAIStudyClient()
        let reopenedService = AIStudyWorkflowService(
            store: reopened, aiClient: secondClient,
            configurationProvider: { AIConfiguration(preset: .openAI, modelName: "mock-model") },
            apiKeyProvider: {
                Issue.record("本地缓存命中不应读取 API 密钥")
                return nil
            }
        )
        let reloaded = try #require(await reopened.document(id: document.id))
        #expect(try await reopenedService.cachedPreview(for: reloaded, task: task) == first)
        #expect(try await reopenedService.generatePreview(for: reloaded, task: task) == first)
        #expect(secondClient.translationBatchCalls.isEmpty)

        var changed = reloaded
        changed.lines[15].startMs = 123
        #expect(try await reopenedService.cachedPreview(for: changed, task: task) == first)
        changed.lines[15].text = "第十六行新的原创测试文本"
        let changedService = StudyTestHelper.makeService(store: reopened, client: secondClient)
        let latest = try await changedService.generatePreview(for: changed, task: task)
        #expect(secondClient.translationBatchCalls == [Array(changed.lines[10..<20]).map(\.id)])
        #expect(latest[15].generatedText == "译-第十六行新的原创测试文本")

        _ = try await changedService.generatePreview(for: changed, task: .translation(targetLanguage: "en"))
        #expect(secondClient.translationBatchCalls.count == 6)
        let differentModel = StudyTestHelper.makeService(store: reopened, client: secondClient, modelName: "another-model")
        _ = try await differentModel.generatePreview(for: changed, task: task)
        #expect(secondClient.translationBatchCalls.count == 11)
    }

    @Test("应用部分结果后恢复原稀疏批次；显式刷新生成行后恢复最新值")
    func partialApplicationAndRefreshKeepCachedCandidates() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let task = AIStudyBatchTaskKind.translation(targetLanguage: "zh-Hans")
        let document = try await seedBatchDocument(in: store, withManualTranslation: true)
        let client = MockAIStudyClient()
        let service = StudyTestHelper.makeService(store: store, client: client)
        let first = try await service.generatePreview(for: document, task: task)
        #expect(client.translationBatchCalls.map(\.count) == [9, 10, 10, 10, 1])
        let applied = try await service.applyPreviewToStore(
            documentId: document.id, expectedRevision: document.revision,
            task: task, modelName: nil, items: [first[1]]
        )
        #expect(applied.lines[1].translations["zh-Hans"]?.text == first[1].generatedText)

        let reopened = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let reopenedClient = MockAIStudyClient()
        let reopenedService = StudyTestHelper.makeService(store: reopened, client: reopenedClient)
        let cached = try await reopenedService.cachedPreview(for: applied, task: task)
        #expect(cached[0].existingText == "人工保留译文")
        #expect(cached[0].generatedText.isEmpty)
        #expect(cached[1].existingText == first[1].generatedText)
        #expect(cached[1].generatedText.isEmpty)
        #expect(cached.dropFirst(2).map(\.generatedText) == first.dropFirst(2).map(\.generatedText))
        #expect(try await reopenedService.generatePreview(for: applied, task: task) == cached)
        #expect(reopenedClient.translationBatchCalls.isEmpty)

        let refreshedID = document.lines[2].id
        reopenedClient.translationHandler = { lines, _, _, _ in
            lines.map { AITranslationLineItem(lineId: $0.id, translation: "重新生成的测试译文") }
        }
        _ = try await reopenedService.generatePreview(
            for: applied, task: task,
            request: .regenerate(lineIds: [refreshedID], completedBatches: AIStudyPreviewCache())
        )
        let latest = try await service.cachedPreview(for: applied, task: task)
        #expect(latest[2].generatedText == "重新生成的测试译文")
        #expect(latest.dropFirst(3).map(\.generatedText) == cached.dropFirst(3).map(\.generatedText))
        #expect(try await reopenedService.generatePreview(for: applied, task: task) == latest)
        #expect(reopenedClient.translationBatchCalls == [[refreshedID]])
    }

    @Test("同库两个预览并发生成同组的不同候选，双方结果都能恢复")
    func concurrentPreviewsKeepBothCandidates() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let document = try await seedBatchDocument(in: store)
        let peer = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let firstClient = MockAIStudyClient()
        let secondClient = MockAIStudyClient()
        let firstService = StudyTestHelper.makeService(store: store, client: firstClient)
        let secondService = StudyTestHelper.makeService(store: peer, client: secondClient)
        let task = AIStudyBatchTaskKind.translation(targetLanguage: "zh-Hans")
        let firstID = document.lines[0].id
        let secondID = document.lines[1].id
        async let first = firstService.generatePreview(
            for: document, task: task,
            request: .regenerate(lineIds: [firstID], completedBatches: AIStudyPreviewCache())
        )
        async let second = secondService.generatePreview(
            for: document, task: task,
            request: .regenerate(lineIds: [secondID], completedBatches: AIStudyPreviewCache())
        )
        _ = try await (first, second)

        let reused = try await firstService.cachedPreview(for: document, task: task)
        #expect(reused.filter { !$0.generatedText.isEmpty }.map(\.lineId) == [firstID, secondID])
        #expect(firstClient.translationBatchCalls == [[firstID]])
        #expect(secondClient.translationBatchCalls == [[secondID]])
    }

    @Test("首批生成途中清空后，本次预览仍显示所有结果，但所有批次都不写回")
    func clearDuringGenerationKeepsPreviewWithoutSaving() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let document = try await seedBatchDocument(in: store)
        let peer = try TestEnv.openStore(in: directory)
        let client = MockAIStudyClient()
        client.translationHandler = { lines, _, _, _ in
            if lines.first?.id == document.lines[0].id {
                try await peer.clearAIStudyCache()
            }
            return lines.map { AITranslationLineItem(lineId: $0.id, translation: "译-" + $0.text) }
        }
        let service = StudyTestHelper.makeService(store: store, client: client)
        let task = AIStudyBatchTaskKind.translation(targetLanguage: "zh-Hans")

        let preview = try await service.generatePreview(for: document, task: task)
        #expect(preview.allSatisfy { !$0.generatedText.isEmpty })
        let cached = try await service.cachedPreview(for: document, task: task)
        #expect(cached.allSatisfy { $0.generatedText.isEmpty })

        client.translationHandler = nil
        #expect(try await service.generatePreview(for: document, task: task) == preview)
        #expect(try await service.cachedPreview(for: document, task: task) == preview)
    }

    @Test("批次失败和部分返回时，仅复用完整成功的批次")
    func retryOnlyIncompleteBatches() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let document = try await seedBatchDocument(in: store)
        let task = AIStudyBatchTaskKind.translation(targetLanguage: "zh-Hans")
        let client = MockAIStudyClient()
        let service = StudyTestHelper.makeService(store: store, client: client)
        let failureLine = document.lines[10].id
        client.translationHandler = { lines, _, _, _ in
            if lines.first?.id == failureLine { throw AIProviderError.invalidConfiguration("模拟失败") }
            return lines.map { AITranslationLineItem(lineId: $0.id, translation: "译-" + $0.text) }
        }
        await #expect(throws: AIStudyWorkflowError.self) {
            try await service.generatePreview(for: document, task: task)
        }
        let local = try await service.cachedPreview(for: document, task: task)
        #expect(local.filter { !$0.generatedText.isEmpty }.count == 10)

        client.translationHandler = { lines, _, _, _ in
            let output = lines.first?.id == failureLine ? Array(lines.dropLast()) : lines
            return output.map { AITranslationLineItem(lineId: $0.id, translation: "译-" + $0.text) }
        }
        let partial = try await service.generatePreview(for: document, task: task)
        #expect(partial.filter { !$0.generatedText.isEmpty }.count == 40)
        #expect(client.translationBatchCalls.map(\.count) == [10, 10, 10, 10, 10, 1])

        client.translationHandler = nil
        let completed = try await service.generatePreview(for: document, task: task)
        #expect(completed.filter { !$0.generatedText.isEmpty }.count == 41)
        #expect(client.translationBatchCalls.count == 7)
        #expect(client.translationBatchCalls.last == Array(document.lines[10..<20]).map(\.id))
    }

    @Test("补齐保留人工、待复核和其他形式；显式重新生成仅发送选中行")
    func fillMissingAndRegenerateSelected() async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let document = try await StudyTestHelper.seedStudyDocument(in: store)
        let client = MockAIStudyClient()
        let service = StudyTestHelper.makeService(store: store, client: client)
        let task = AIStudyBatchTaskKind.pronunciation(.furigana)
        let preview = try await service.generatePreview(for: document, task: task)
        let lineIDs = [document.lines[0].id, document.lines[1].id, document.lines[3].id]
        #expect(client.pronunciationBatchCalls == [[lineIDs[2]]])
        #expect(preview[0].existingIsManual && preview[0].existingUsesDifferentStyle)
        #expect(preview[0].existingText == "manual-ro")
        #expect(preview[1].existingNeedsReview && preview[1].existingUsesDifferentStyle)
        #expect(preview[0].generatedText.isEmpty && preview[1].generatedText.isEmpty)
        _ = try await service.generatePreview(for: document, task: .pronunciation(.romaji))
        #expect(client.pronunciationBatchCalls == [[lineIDs[2]], [lineIDs[2]]])
        let translation = try await service.generatePreview(for: document, task: .translation(targetLanguage: "zh-Hans"))
        #expect(client.translationBatchCalls == [[lineIDs[1]]])
        #expect(translation[0].existingText == "人工译文")
        #expect(translation[2].existingText == "导入译文")

        let selection: Set<UUID> = [lineIDs[0], lineIDs[2]]
        let run = AIStudyBatchRequest.regenerate(lineIds: selection, completedBatches: AIStudyPreviewCache())
        let refreshed = try await service.generatePreview(for: document, task: task, request: run)
        #expect(client.pronunciationBatchCalls.last == [lineIDs[0], lineIDs[2]])
        #expect(refreshed[0].isSelected == false)
        #expect(refreshed[0].generatedText == "ro-测试虚构歌词第一句")
        #expect(refreshed[1].generatedText.isEmpty)
        _ = try await service.generatePreview(
            for: document, task: task,
            request: .regenerate(lineIds: selection, completedBatches: AIStudyPreviewCache())
        )
        #expect(client.pronunciationBatchCalls.count == 4)
        #expect(try await store.document(id: document.id) == document)
    }

    @Test("导入草稿在当前流程复用，确认入库且未清空缓存才持久化", arguments: [false, true])
    func draftCacheOnlyPersistsAfterImport(clearBeforeImport: Bool) async throws {
        let (store, directory) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(directory) }
        let importService = ImportWorkflowService(store: store)
        try await importService.openImportSession(target: Fixture.targetA())
        _ = try await importService.ingest(fileData: Data(Fixture.lrcText.utf8), filename: nil)
        let draft = try #require(await importService.currentDraftDocumentForStudy())
        let client = MockAIStudyClient()
        let cache = AIStudyPreviewCache()
        let task = AIStudyBatchTaskKind.pronunciation(.romaji)
        func makeDraftService() -> AIStudyWorkflowService {
            AIStudyWorkflowService(
                store: store, aiClient: client,
                configurationProvider: { AIConfiguration(preset: .openAI, modelName: "mock-model") },
                draftCache: cache
            )
        }
        let generated = try await makeDraftService().generatePreview(for: draft, task: task)
        #expect(client.pronunciationBatchCalls.count == 1)
        if clearBeforeImport { try await store.clearAIStudyCache() }
        #expect(try await makeDraftService().cachedPreview(for: draft, task: task) == generated)
        let persistedService = StudyTestHelper.makeService(store: store, client: client)
        let confirmation = try await importService.confirmImport()
        let stored = confirmation.document
        let beforePromotion = try await persistedService.cachedPreview(for: stored, task: task)
        #expect(beforePromotion.allSatisfy { $0.generatedText.isEmpty })
        await cache.persist(in: store, for: stored.id)
        let afterPromotion = try await persistedService.cachedPreview(for: stored, task: task)
        #expect(afterPromotion == (clearBeforeImport ? beforePromotion : generated))
        #expect(client.pronunciationBatchCalls.count == 1)
    }

    private func seedBatchDocument(
        in store: GRDBLyricsStore, withManualTranslation: Bool = false
    ) async throws -> LyricDocument {
        var lines = (0..<41).map { index in
            LyricLine(startMs: index * 2_000, text: "虚构的星灯测试句 \(index + 1)")
        }
        if withManualTranslation {
            lines[0].translations["zh-Hans"] = Translation(
                text: "人工保留译文", source: .manual, needsReview: true
            )
        }
        let document = LyricDocument(sourceLanguage: "ja", sourceFormat: .lrc, lines: lines)
        try await store.save(document: document, binding: SongBinding(track: Fixture.trackA, lyricDocumentId: document.id))
        return document
    }

    @Test("41 行生成到第二批时取消，重试跳过完整的首批")
    func generatePreviewCancellationStopsRemainingBatches() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let doc = try await seedBatchDocument(in: store)
        let client = MockAIStudyClient()
        let service = StudyTestHelper.makeService(store: store, client: client)
        let taskKind = AIStudyBatchTaskKind.translation(targetLanguage: "zh-Hans")
        let secondBatchStartID = doc.lines[10].id

        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        client.translationHandler = { lines, _, _, _ in
            if lines.first?.id == secondBatchStartID {
                startedContinuation.yield()
                try await Task.sleep(for: .seconds(1))
            }
            return lines.map { AITranslationLineItem(lineId: $0.id, translation: "译-" + $0.text) }
        }

        let task = Task { try await service.generatePreview(for: doc, task: taskKind) }
        var iterator = startedStream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("取消后应当抛出 AIStudyWorkflowError.cancelled")
        } catch let error as AIStudyWorkflowError {
            #expect(error == .cancelled)
        }
        #expect(client.translationBatchCalls.map(\.count) == [10, 10])

        let retryClient = MockAIStudyClient()
        let retryService = StudyTestHelper.makeService(store: store, client: retryClient)
        let before = try await retryService.cachedPreview(for: doc, task: taskKind)
        #expect(before.filter { !$0.generatedText.isEmpty }.count == 10)
        let preview = try await retryService.generatePreview(for: doc, task: taskKind)
        #expect(preview.allSatisfy { !$0.generatedText.isEmpty })
        #expect(retryClient.translationBatchCalls.map(\.count) == [10, 10, 10, 1])
        #expect(retryClient.translationBatchCalls.first?.first == secondBatchStartID)
    }
}
