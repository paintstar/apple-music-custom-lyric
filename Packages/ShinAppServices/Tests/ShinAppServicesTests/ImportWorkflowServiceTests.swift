import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 导入会话状态机测试：预览、确认、取消与并发失效。
// 全部使用临时目录的真实 GRDB 库；切歌模拟使用 ShinAppleKit 的
// MockPlaybackController（ManualClock，无真实定时器）。

@Suite("导入会话状态机")
struct ImportWorkflowServiceTests {

    // MARK: - 导入目标固定

    @Test("会话目标不随播放变化：切歌后目标不变，确认仍绑定打开会话时的歌曲")
    func targetStaysFixedWhilePlaybackChanges() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        let controller = MockPlaybackController()
        controller.setMockQueue([
            MockTrack(identity: Fixture.trackA, title: "测试曲目甲", durationMs: 200_000),
            MockTrack(identity: Fixture.trackB, title: "测试曲目乙", durationMs: 200_000)
        ])

        try await service.openImportSession(target: Fixture.targetA())
        try await controller.next() // 播放已切到 B
        #expect(controller.snapshot().track == Fixture.trackB)

        let fixedTarget = await service.sessionTarget()
        #expect(fixedTarget == Fixture.targetA())

        _ = try await service.ingest(fileData: Fixture.lrcData, filename: "测试歌词.lrc")
        let confirmation = try await service.confirmImport()

        // 绑定到打开会话时选定的 A，而不是当前播放的 B。
        #expect(confirmation.binding.track == Fixture.trackA)
        let boundA = try await store.document(for: Fixture.trackA)
        #expect(boundA?.id == confirmation.document.id)
        let boundB = try await store.binding(for: Fixture.trackB)
        #expect(boundB == nil)
    }

    // MARK: - 预览

    @Test("预览统计、元信息与 offset 说明正确；诊断为空且可导入")
    func previewStatsAndMetadata() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())

        let preview = try await service.ingest(fileData: Fixture.lrcData, filename: "测试歌词.lrc")
        #expect(preview.isImportable)
        #expect(preview.totalLineCount == 4)
        #expect(preview.timedLineCount == 3)
        #expect(preview.untimedLineCount == 1)
        #expect(preview.sourceOffsetMs == 200)
        #expect(preview.filename == "测试歌词.lrc")
        #expect(preview.firstMetadataValue(for: "ti") == "测试曲目甲")
        #expect(preview.firstMetadataValue(for: "ar") == "测试歌手甲")
        #expect(preview.firstMetadataValue(for: "al") == "虚构专辑测试")
        #expect(preview.diagnostics.isEmpty)
        #expect(!ImportPreview.sourceOffsetNote.isEmpty)
    }

    @Test("警告诊断（乱序时间戳）可保存并进入预览")
    func warningDiagnosticsAreVisible() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())

        let data = Data("[00:05.000]乱序后句测试文本\n[00:02.000]乱序前句测试文本\n".utf8)
        let preview = try await service.ingest(fileData: data, filename: nil)
        #expect(preview.isImportable)
        #expect(preview.diagnostics.count == 1)
        #expect(preview.diagnostics.first?.severity == .warning)
        #expect(preview.diagnostics.first?.line == 2)
        // 稳定排序后按时间排列。
        let stored = await service.currentPreview()
        #expect(stored?.timedLineCount == 2)
    }

    // MARK: - 可恢复错误

    @Test("解析错误可恢复：会话保持打开，允许重选文件后成功确认")
    func parseErrorsKeepSessionOpenForRetry() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())

        // 1) 无法解码：类型化错误，会话保持打开。
        await expectImportError(.parseFailure(.undecodableUTF8(byteOffset: 1))) {
            _ = try await service.ingest(fileData: Fixture.undecodableData, filename: "坏字节.lrc")
        }
        #expect(await service.sessionTarget() == Fixture.targetA())
        #expect(await service.currentPreview() == nil)

        // 2) 空文件：类型化错误，会话保持打开。
        await expectImportError(.parseFailure(.emptyInput)) {
            _ = try await service.ingest(fileData: Data("  \n ".utf8), filename: nil)
        }

        // 3) 超过大小上限：类型化错误，会话保持打开。
        await expectImportError(
            .parseFailure(.inputTooLarge(limitBytes: 2 * 1024 * 1024, actualBytes: 2 * 1024 * 1024 + 1))
        ) {
            _ = try await service.ingest(fileData: Fixture.oversizedData, filename: nil)
        }

        // 4) 含 error 诊断的 LRC：可拿到预览但不可确认。
        let errorPreview = try await service.ingest(fileData: Fixture.errorLrcData, filename: nil)
        #expect(!errorPreview.isImportable)
        #expect(errorPreview.diagnostics.contains { $0.severity == .error })
        await expectImportError(.previewHasErrors) {
            _ = try await service.confirmImport()
        }

        // 5) 重选合法文件后直接成功。
        let goodPreview = try await service.ingest(fileData: Fixture.lrcData, filename: "重选.lrc")
        #expect(goodPreview.isImportable)
        let confirmation = try await service.confirmImport()
        #expect(try await store.document(for: Fixture.trackA)?.id == confirmation.document.id)
    }

    // MARK: - 会话生命周期

    @Test("重复打开会话被拒绝")
    func doubleOpenRejected() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        await expectImportError(.sessionAlreadyOpen) {
            try await service.openImportSession(
                target: ImportSessionTarget(track: Fixture.trackB)
            )
        }
        #expect(await service.sessionTarget() == Fixture.targetA())
    }

    @Test("取消无副作用：库不变、状态清空、可再次打开")
    func cancelHasNoSideEffects() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        let before = try await store.currentSnapshot()
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)

        await service.cancel()
        await service.cancel() // 幂等

        #expect(await service.sessionTarget() == nil)
        #expect(await service.currentPreview() == nil)
        #expect(try await store.currentSnapshot() == before, "取消不得写库")
        await expectImportError(.noOpenSession) {
            _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        }
        await expectImportError(.noOpenSession) {
            _ = try await service.confirmImport()
        }
        // 取消后可以开新会话。
        try await service.openImportSession(
            target: ImportSessionTarget(track: Fixture.trackB)
        )
        #expect(await service.sessionTarget()?.trackKey == SongBinding.trackKey(for: Fixture.trackB))
    }

    @Test("确认前不覆盖现有文档：预览阶段旧文档与绑定原样保留")
    func existingDocumentUntouchedBeforeConfirm() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let oldDocument = try await Fixture.seedOldDocument(in: store)
        let before = try await store.currentSnapshot()

        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)

        // 确认卡数据：已有绑定与旧文档可见。
        let existing = try await service.existingBindingInfo()
        #expect(existing?.binding.lyricDocumentId == oldDocument.id)
        #expect(existing?.document?.id == oldDocument.id)
        #expect(existing?.otherBindings.isEmpty == true)

        // 确认前：库完全未变。
        #expect(try await store.currentSnapshot() == before)
        #expect(try await store.document(for: Fixture.trackA)?.id == oldDocument.id)
    }

    @Test("重导入预览与确认：绑定替换为新文档、旧文档保留")
    func reimportReplacesBindingKeepsOldDocument() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let oldDocument = try await Fixture.seedOldDocument(in: store)

        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        let confirmation = try await service.confirmImport()

        // 绑定指向新文档；提示信息来自会话目标；用户延迟从 0 开始。
        #expect(confirmation.replacedBinding?.lyricDocumentId == oldDocument.id)
        #expect(confirmation.binding.track == Fixture.trackA)
        #expect(confirmation.binding.userDelayMs == 0)
        #expect(confirmation.binding.titleHint == "测试曲目甲")
        #expect(confirmation.binding.artistHint == "测试歌手甲")
        #expect(confirmation.binding.durationHintMs == 183_000)
        #expect(confirmation.documentsLosingLastBinding.map(\.id) == [oldDocument.id])

        let current = try await store.document(for: Fixture.trackA)
        #expect(current?.id == confirmation.document.id)
        // 旧文档保留在库中，不静默销毁。
        let oldStillThere = try await store.document(id: oldDocument.id)
        #expect(oldStillThere?.id == oldDocument.id)
        #expect(try await store.allDocuments().count == 2)
    }

    @Test("确认原子成功且防重复提交：二次确认报错、库不再变化")
    func confirmAtomicAndIdempotent() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        _ = try await service.confirmImport()

        let afterFirst = try await store.currentSnapshot()
        await expectImportError(.alreadyConfirmed) {
            _ = try await service.confirmImport()
        }
        #expect(try await store.currentSnapshot() == afterFirst)
        // 已完成的会话不允许继续 ingest。
        await expectImportError(.sessionCompleted) {
            _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        }
    }

    @Test("未 ingest 就确认 / 无会话操作均类型化拒绝")
    func guardClauses() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)

        await expectImportError(.noOpenSession) {
            _ = try await service.ingest(fileData: Fixture.lrcData, filename: nil)
        }
        await expectImportError(.noOpenSession) {
            _ = try await service.confirmImport()
        }
        await expectImportError(.noOpenSession) {
            _ = try await service.existingBindingInfo()
        }
        try await service.openImportSession(target: Fixture.targetA())
        await expectImportError(.nothingIngested) {
            _ = try await service.confirmImport()
        }
    }

    // MARK: - 存储错误映射

    @Test("存储层错误映射：revision 冲突 → 类型化冲突错误")
    func storeErrorMapping() {
        let id = UUID()
        let mapped = ImportWorkflowError.mapStoreError(
            ShinAppleDataError.revisionConflict(
                documentId: id, storedRevision: 3, submittedRevision: 5
            )
        )
        #expect(
            mapped == .revisionConflict(documentId: id, storedRevision: 3, submittedRevision: 5)
        )
        #expect(
            ImportWorkflowError.mapStoreError(
                ShinAppleDataError.storageUnavailable("磁盘故障")
            ) == .storageUnavailable("磁盘故障")
        )
    }

    // MARK: - 全流程（临时目录真实 GRDB 库）

    @Test("临时目录真实 GRDB 库全流程：导入→确认→查询→解除→重导入")
    func fullWorkflowAgainstRealStore() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let service = ImportWorkflowService(store: store)
        let association = LyricsAssociationService(store: store)

        // 未导入前：空态。
        #expect(try await association.associationState(for: Fixture.trackA) == .unbound)

        try await service.openImportSession(target: Fixture.targetA())
        let preview = try await service.ingest(fileData: Fixture.lrcData, filename: "全流程.lrc")
        #expect(preview.totalLineCount == 4)
        _ = try await service.confirmImport()

        // 正常态：文档与绑定可查。
        if case let .available(document, binding) = try await association.associationState(for: Fixture.trackA) {
            #expect(document.lines.count == 4)
            #expect(binding.titleHint == "测试曲目甲")
        } else {
            Issue.record("导入后应为 available 状态")
        }

        // 解除关联：文档保留。
        try await association.deleteBinding(for: Fixture.trackA)
        #expect(try await association.associationState(for: Fixture.trackA) == .unbound)
        #expect(try await store.allDocuments().count == 1)

        // 重开一个会话再次导入：全新关联成立。
        try await service.openImportSession(target: Fixture.targetA())
        _ = try await service.ingest(fileData: Fixture.lrcData, filename: "全流程二.lrc")
        let second = try await service.confirmImport()
        if case let .available(document, _) = try await association.associationState(for: Fixture.trackA) {
            #expect(document.id == second.document.id)
        } else {
            Issue.record("重导入后应为 available 状态")
        }
    }
}
