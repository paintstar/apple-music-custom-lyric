import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 双语导入会话/预览与重算竞争测试。
// 策略层纯函数与共用夹具见 BilingualImportMapperTests.swift；
// 夹具全部为原创虚构文本（「测试原文/译文」系列）。

// MARK: - 会话与预览（导入工作流集成）

@Suite("双语导入会话与预览")
struct BilingualImportSessionTests {

    @Test("off：预览无双语信息；确认落库文档与解析产物一致（现有路径不变）")
    func offImportMatchesCurrentBehavior() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())

        let preview = try await service.ingest(
            fileData: Data(BilingualFixture.pairedLrcText.utf8), filename: "成对测试.lrc"
        )
        #expect(preview.bilingual == nil)
        #expect(preview.pairedTimestampsAvailable)
        #expect(await service.activeBilingualMode() == .off)

        let confirmation = try await service.confirmImport()
        #expect(confirmation.document.lines.count == 4)
        #expect(confirmation.document.lines.allSatisfy { $0.translations.isEmpty })
        let stored = try await store.document(id: confirmation.document.id)
        #expect(stored?.lines.count == 4)
        #expect(stored?.lines.allSatisfy { $0.translations.isEmpty } == true)
    }

    @Test("成对模式：预览统计正确；确认后译文落库（source = imported）")
    func pairedModePreviewStatsAndPersistedTranslations() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(
            fileData: Data(BilingualFixture.pairedLrcText.utf8), filename: "成对测试.lrc"
        )

        let preview = await service.setBilingualMode(.pairedTimestamps)
        let info = preview?.bilingual
        #expect(info?.mode == .pairedTimestamps)
        #expect(info?.originalLineCount == 2)
        #expect(info?.translatedLineCount == 2)
        #expect(info?.warnings.isEmpty == true)
        #expect(info?.pairRows.count == 2)
        #expect(info?.pairRows.first == BilingualPairRow(
            originalText: "测试原文甲", translationText: "测试译文甲"
        ))

        let confirmation = try await service.confirmImport()
        let stored = try await store.document(id: confirmation.document.id)
        #expect(stored?.lines.count == 2)
        #expect(stored?.lines[0].translations[BilingualImportMapper.translationLanguageKey] == Translation(
            text: "测试译文甲", source: .imported, needsReview: false
        ))
    }

    @Test("分隔符模式：预览统计正确；未含分隔符的行原样保留")
    func inlineModePreviewStats() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(
            fileData: Data(BilingualFixture.separatorLinesLrcText.utf8), filename: "分隔测试.lrc"
        )

        let preview = await service.setBilingualMode(.inlineSeparator(.doubleSlash))
        let info = preview?.bilingual
        #expect(info?.mode == .inlineSeparator(.doubleSlash))
        #expect(info?.originalLineCount == 4)
        #expect(info?.translatedLineCount == 1)
        #expect(info?.warnings.isEmpty == true)
        #expect(info?.pairRows[1].translationText == nil)

        // 切回 off：双语信息消失，预览统计回到解析产物本身。
        let offPreview = await service.setBilingualMode(.off)
        #expect(offPreview?.bilingual == nil)
        #expect(offPreview?.totalLineCount == 4)
    }

    @Test("成对可用性：LRC 有组=true；纯文本/无组=false（UI 置灰依据）")
    func pairedAvailabilityInPreview() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())

        let plainPreview = try await service.ingest(
            fileData: Data(BilingualFixture.plainText.utf8), filename: "纯文本测试.txt"
        )
        #expect(plainPreview.pairedTimestampsAvailable == false)
        let plainPaired = await service.setBilingualMode(.pairedTimestamps)
        #expect(plainPaired?.bilingual?.warnings.count == 1)
        #expect(plainPaired?.bilingual?.translatedLineCount == 0)

        _ = try await service.ingest(
            fileData: Data(BilingualFixture.noGroupLrcText.utf8), filename: "无组测试.lrc"
        )
        let noGroupPreview = try await service.currentPreview()
        #expect(noGroupPreview?.pairedTimestampsAvailable == false)
    }

    @Test("重新 ingest：双语模式重置为 off，旧映射结果作废")
    func reingestResetsBilingualState() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(
            fileData: Data(BilingualFixture.pairedLrcText.utf8), filename: "成对测试.lrc"
        )
        _ = await service.setBilingualMode(.pairedTimestamps)
        #expect(await service.activeBilingualMode() == .pairedTimestamps)

        _ = try await service.ingest(
            fileData: Data(BilingualFixture.plainText.utf8), filename: "纯文本测试.txt"
        )
        #expect(await service.activeBilingualMode() == .off)
        let preview = await service.currentPreview()
        #expect(preview?.bilingual == nil)
    }
}

// MARK: - 重算竞争（generation 防旧覆盖）

@Suite("双语导入重算竞争")
struct BilingualRecomputeRaceTests {

    /// 测试闸门：慢任务在「映射完成后、提交判定前」挂起，直到测试放行。
    /// 不阻塞协作线程池（挂起走 continuation）。
    private final class SubmitGate: @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        /// 慢任务调用：通知已到达闸门，然后挂起等待放行。
        func waitAtGate() async {
            entered.signal()
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                    lock.unlock()
                }
            }
        }

        /// 测试线程等待慢任务到达闸门（带超时，失败不悬挂测试）。
        func waitEntered(timeout: TimeInterval = 10) -> Bool {
            entered.wait(timeout: .now() + timeout) == .success
        }

        /// 放行（幂等；放行后到达闸门的调用直接通过）。
        func open() {
            lock.lock()
            released = true
            let continuation = releaseContinuation
            releaseContinuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    @Test("慢的旧策略重算不得覆盖新模式结果（generation 防旧覆盖）")
    func staleRecomputeDoesNotOverwriteNewerMode() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(
            fileData: Data(BilingualFixture.raceLrcText.utf8), filename: "竞争测试.lrc"
        )

        let gate = SubmitGate()
        await service.setBilingualRecomputePauseForTesting { mode in
            if mode == .pairedTimestamps {
                await gate.waitAtGate()
            }
        }

        // 慢任务：成对模式（映射完成后被闸门拦住，尚未提交）。
        let slowTask = Task { await service.setBilingualMode(.pairedTimestamps) }
        guard gate.waitEntered() else {
            gate.open()
            Issue.record("慢任务未在超时内到达提交闸门")
            return
        }

        // 快任务：// 分隔符模式，先于慢任务完整提交。
        let fastPreview = await service.setBilingualMode(.inlineSeparator(.doubleSlash))
        #expect(fastPreview?.bilingual?.mode == .inlineSeparator(.doubleSlash))
        #expect(fastPreview?.bilingual?.translatedLineCount == 2)

        gate.open()
        let slowResult = await slowTask.value
        // 慢结果被代序号判定丢弃：不提交、不返回预览。
        #expect(slowResult == nil)

        // 最终状态 = 后提交的分隔符模式（译文来自分隔符切分，不是成对行）。
        #expect(await service.activeBilingualMode() == .inlineSeparator(.doubleSlash))
        let finalPreview = await service.currentPreview()
        #expect(finalPreview?.bilingual?.mode == .inlineSeparator(.doubleSlash))
        #expect(finalPreview?.bilingual?.translatedLineCount == 2)
        #expect(finalPreview?.bilingual?.pairRows.first?.translationText == "分隔译文测试甲")

        // 确认落库的是最终模式的文档。
        let confirmation = try await service.confirmImport()
        #expect(confirmation.document.lines.count == 4)
        #expect(
            confirmation.document.lines[0]
                .translations[BilingualImportMapper.translationLanguageKey]?.text == "分隔译文测试甲"
        )
        let stored = try await store.document(id: confirmation.document.id)
        #expect(
            stored?.lines[0].translations[BilingualImportMapper.translationLanguageKey]?.text == "分隔译文测试甲"
        )
    }
}
