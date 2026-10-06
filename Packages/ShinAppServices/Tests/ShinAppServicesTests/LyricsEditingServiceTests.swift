import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 歌词编辑会话测试：草稿隔离、行身份与译文绑定、撤销/重做、
// revision 双连接冲突、关闭守卫。夹具全部为原创虚构文本，不使用真实歌词。

/// 断言抛出指定的 LyricsEditingError（类型相等比较）。
func expectEditingError(
    _ expected: LyricsEditingError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("应当抛出 \(expected)", sourceLocation: sourceLocation)
    } catch let error as LyricsEditingError {
        #expect(error == expected, "实际错误：\(error.message)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("非 LyricsEditingError：\(error)", sourceLocation: sourceLocation)
    }
}

@Suite("歌词编辑会话")
struct LyricsEditingServiceTests {

    // MARK: - 夹具

    enum EditFixture {

        /// 可编辑文档：行 1 带简体中文译文，行 2 无译文，行 3 未打轴。
        /// 绑定到传入曲目（默认 trackA）。
        @discardableResult
        static func seedEditableDocument(
            in store: GRDBLyricsStore,
            track: CatalogIdentity = Fixture.trackA
        ) async throws -> LyricDocument {
            var first = LyricLine(startMs: 1_500, text: "编辑测试第一句")
            first.translations["zh-Hans"] = Translation(
                text: "编辑测试第一句译文", source: .manual, needsReview: false
            )
            let second = LyricLine(startMs: 4_000, text: "编辑测试第二句")
            let untimed = LyricLine(startMs: nil, text: "编辑测试未打轴句")
            let document = LyricDocument(sourceFormat: .lrc, lines: [first, second, untimed])
            try await store.save(
                document: document,
                binding: SongBinding(track: track, lyricDocumentId: document.id)
            )
            return document
        }

        /// 在同一数据库文件上再开一个连接（模拟另一个窗口/双连接场景）。
        static func secondConnection(_ directory: URL) throws -> GRDBLyricsStore {
            try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        }
    }

    // MARK: - 草稿隔离与放弃

    @Test("草稿隔离：提交前 store 不变；discard 后与打开时一致")
    func draftIsolationAndDiscard() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)

        let firstLineId = document.lines[0].id
        _ = try await service.setLineText(lineId: firstLineId, text: "草稿里的新原文测试")
        _ = try await service.setLineTime(lineId: firstLineId, rawTimeString: "12.5")
        _ = try await service.addLine(after: nil, text: "草稿新增行测试")

        // 提交前：库内文档一个字节不变。
        let beforeDiscard = try await store.document(id: document.id)
        #expect(beforeDiscard == document)

        await service.discard()
        let snapshot = try await service.currentSnapshot()
        #expect(snapshot?.hasUnsavedChanges == false)
        #expect(snapshot?.lines == document.lines)
        #expect(snapshot?.canUndo == false)
        // 放弃后：库内文档仍与打开时一致（discard 绝不写库）。
        #expect(try await store.document(id: document.id) == document)
    }

    // MARK: - 原文与待复核

    @Test("改原文 → 该行译文全部待复核；无译文行不受影响；同文本 no-op")
    func setLineTextReviewSemantics() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id
        let secondId = document.lines[1].id

        let snapshot = try await service.setLineText(lineId: firstId, text: "改动后的原文测试")
        let updatedFirst = snapshot.lines.first { $0.id == firstId }
        #expect(updatedFirst?.text == "改动后的原文测试")
        #expect(updatedFirst?.translations["zh-Hans"]?.needsReview == true)

        let updatedSecond = snapshot.lines.first { $0.id == secondId }
        #expect(updatedSecond?.translations.isEmpty == true)

        // 相同文本再设一次：no-op（不产生新历史，也不翻转状态）。
        let noop = try await service.setLineText(lineId: firstId, text: "改动后的原文测试")
        #expect(noop.hasUnsavedChanges == snapshot.hasUnsavedChanges)
        #expect(noop.lines == snapshot.lines)
        #expect(try await service.undo().lines.first { $0.id == firstId }?.text == "编辑测试第一句")
    }

    // MARK: - 时间编辑

    @Test("改时间：合法形式生效；非法输入定位到行且不静默归零；空 = 未打轴")
    func setLineTimeRules() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id
        let untimedId = document.lines[2].id

        func startMs(of id: UUID, from snapshot: LyricsEditingSnapshot) -> Int64? {
            snapshot.lines.first { $0.id == id }?.startMs
        }
        var snapshot = try await service.setLineTime(lineId: firstId, rawTimeString: "[01:02.500]")
        #expect(startMs(of: firstId, from: snapshot) == 62_500)
        snapshot = try await service.setLineTime(lineId: firstId, rawTimeString: "90")
        #expect(startMs(of: firstId, from: snapshot) == 90_000)
        snapshot = try await service.setLineTime(lineId: firstId, rawTimeString: "12.5")
        #expect(startMs(of: firstId, from: snapshot) == 12_500)
        snapshot = try await service.setLineTime(lineId: untimedId, rawTimeString: "1250ms")
        #expect(startMs(of: untimedId, from: snapshot) == 1_250)

        // 空 = 未打轴。
        snapshot = try await service.setLineTime(lineId: firstId, rawTimeString: "   ")
        #expect(startMs(of: firstId, from: snapshot) == nil)

        // 非法输入：类型化错误定位到该行；值保持不变，绝不静默归零。
        await expectEditingError(
            .invalidTimeInput(lineId: untimedId, rawInput: "abc", reason: .malformed)
        ) {
            try await service.setLineTime(lineId: untimedId, rawTimeString: "abc")
        }
        await expectEditingError(
            .invalidTimeInput(lineId: untimedId, rawInput: "1:60", reason: .secondsOutOfRange(60))
        ) {
            try await service.setLineTime(lineId: untimedId, rawTimeString: "1:60")
        }
        snapshot = try await service.currentSnapshot()!
        #expect(startMs(of: untimedId, from: snapshot) == 1_250)

        // 未知名的行操作 → lineNotFound（按稳定 id 定位，不按下标）。
        let ghostId = UUID()
        await expectEditingError(.lineNotFound(lineId: ghostId)) {
            try await service.setLineTime(lineId: ghostId, rawTimeString: "5")
        }
    }

    // MARK: - 行结构与译文归属

    @Test("移动行：只在数组顺序上交换，译文随行 id 走，绝不错配")
    func moveLineKeepsTranslationsBound() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id
        let secondId = document.lines[1].id

        let moved = try await service.moveLine(lineId: firstId, direction: .down)
        #expect(moved.lines.map(\.id) == [secondId, firstId, document.lines[2].id])
        // 译文仍绑在同一 id 上（随行走）。
        let translated = moved.lines.first { $0.id == firstId }
        #expect(translated?.translations["zh-Hans"]?.text == "编辑测试第一句译文")

        // 边界 no-op：已在顶部再上移 → 无变化、不产生新历史
        // （撤销一次应直接回到打开时的原始顺序）。
        let boundary = try await service.moveLine(lineId: secondId, direction: .up)
        #expect(boundary.lines.map(\.id) == moved.lines.map(\.id))
        let undone = try await service.undo()
        #expect(undone.lines.map(\.id) == document.lines.map(\.id))
    }

    @Test("新增/删除行：新行有全新 id；删除行时译文随行删除")
    func addAndDeleteLines() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id
        let originalIds = document.lines.map(\.id)

        // 指定行后插入：新行位于锚点之后（索引 1），锚点保持索引 0。
        let inserted = try await service.addLine(
            after: firstId, text: "插入行测试", startMs: 2_000
        )
        #expect(inserted.lines.count == 4)
        #expect(inserted.lines[0].id == firstId)
        let addedId = inserted.lines[1].id
        #expect(!originalIds.contains(addedId))
        #expect(inserted.lines[1].startMs == 2_000)
        #expect(inserted.lines[1].translations.isEmpty)
        #expect(inserted.lines[2].id == document.lines[1].id)

        // 末尾追加（after = nil）。
        let appended = try await service.addLine(after: nil, text: "末尾行测试")
        #expect(appended.lines.count == 5)
        #expect(appended.lines.last?.id != addedId)
        #expect(appended.lines.last?.startMs == nil)

        // 删除带译文的行：译文随行一起消失。
        let removed = try await service.deleteLine(lineId: firstId)
        #expect(removed.lines.count == 4)
        #expect(!removed.lines.contains { $0.id == firstId })

        // 未知名的行操作 → lineNotFound。
        let ghostId = UUID()
        await expectEditingError(.lineNotFound(lineId: ghostId)) {
            try await service.deleteLine(lineId: ghostId)
        }
        await expectEditingError(.lineNotFound(lineId: ghostId)) {
            try await service.addLine(after: ghostId, text: "锚点不存在测试")
        }
    }

    // MARK: - 撤销 / 重做 / 提交

    @Test("撤销/重做：可回到打开时状态；提交后历史重置且已提交版本不被撤销改变")
    func undoRedoAndCommitReset() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id
        let secondId = document.lines[1].id

        _ = try await service.setLineText(lineId: firstId, text: "撤销前的新文本测试")
        _ = try await service.setLineTime(lineId: secondId, rawTimeString: "[00:09]")
        #expect(try await service.currentSnapshot()?.canUndo == true)

        // 连续撤销可回到打开时状态（hasUnsavedChanges 回到 false）。
        var snapshot = try await service.undo()
        #expect(snapshot.lines.first { $0.id == secondId }?.startMs == 4_000)
        snapshot = try await service.undo()
        #expect(snapshot.lines.first { $0.id == firstId }?.text == "编辑测试第一句")
        #expect(snapshot.hasUnsavedChanges == false)
        #expect(snapshot.canUndo == false)
        #expect(try await store.document(id: document.id)?.revision == 1)

        // 重做恢复两次编辑。
        _ = try await service.redo()
        snapshot = try await service.redo()
        #expect(snapshot.lines.first { $0.id == firstId }?.text == "撤销前的新文本测试")
        #expect(snapshot.lines.first { $0.id == secondId }?.startMs == 9_000)

        // 提交：库内 revision + 1，内容为草稿（提交后的基线即新版本 2）。
        let committed = try await service.commitChanges()
        #expect(committed.baseRevision == 2)
        #expect(committed.hasUnsavedChanges == false)
        let stored = try await store.document(id: document.id)
        #expect(stored?.revision == 2)
        #expect(stored?.lines.first { $0.id == firstId }?.text == "撤销前的新文本测试")

        // 提交后历史重置：撤销不可用、调用为 no-op，已提交版本不被改变。
        #expect(committed.canUndo == false)
        let afterUndo = try await service.undo()
        #expect(afterUndo.canUndo == false)
        #expect(afterUndo.lines == committed.lines)
        #expect(try await store.document(id: document.id)?.revision == 2)
    }

    @Test("同一行连续文本按键合并为一条撤销记录")
    func coalescing() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id

        _ = try await service.setLineText(lineId: firstId, text: "逐字")
        _ = try await service.setLineText(lineId: firstId, text: "逐字输")
        _ = try await service.setLineText(lineId: firstId, text: "逐字输入")
        // 切到时间编辑（不同合并键），再切回文本。
        _ = try await service.setLineTime(lineId: firstId, rawTimeString: "5.5")
        _ = try await service.setLineText(lineId: firstId, text: "逐字输入测试")

        var snapshot = try await service.undo()
        #expect(snapshot.lines.first { $0.id == firstId }?.text == "逐字输入")
        #expect(snapshot.lines.first { $0.id == firstId }?.startMs == 5_500)
        snapshot = try await service.undo()
        #expect(snapshot.lines.first { $0.id == firstId }?.startMs == 1_500)
        #expect(snapshot.lines.first { $0.id == firstId }?.text == "逐字输入")
        snapshot = try await service.undo()
        #expect(snapshot.lines.first { $0.id == firstId }?.text == "编辑测试第一句")
        #expect(snapshot.hasUnsavedChanges == false)
    }

    @Test("无未保存修改时提交为 no-op，不升 revision")
    func commitWithoutChanges() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)

        let snapshot = try await service.commitChanges()
        #expect(snapshot.hasUnsavedChanges == false)
        #expect(try await store.document(id: document.id)?.revision == 1)
        #expect(try await store.document(id: document.id) == document)
    }

    // MARK: - revision 冲突（双连接）

    @Test("双连接 revision 冲突：类型化错误上抛、草稿保留、库中版本不被覆盖")
    func revisionConflictDualConnection() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        let opened = try await service.openEditor(documentId: document.id)
        #expect(opened.baseRevision == 1)
        let firstId = document.lines[0].id
        _ = try await service.setLineText(lineId: firstId, text: "本编辑器草稿文本测试")

        // 另一连接（模拟另一窗口）已把库内文档推进到 revision 2。
        let secondConnection = try EditFixture.secondConnection(dir)
        var concurrent = document
        concurrent.lines[0].text = "其他窗口的文本测试"
        concurrent.revision = 2
        concurrent.updatedAt = LyricTimestamp.now()
        try await secondConnection.save(
            document: concurrent,
            binding: SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        )

        // 本编辑器提交 revision 2（库中已是 2，要求 3）→ 类型化冲突。
        await expectEditingError(
            .revisionConflict(documentId: document.id, storedRevision: 2, submittedRevision: 2)
        ) {
            try await service.commitChanges()
        }

        // 草稿完整保留（不静默覆盖，也不丢失用户修改）。
        let snapshot = try await service.currentSnapshot()
        #expect(snapshot?.hasUnsavedChanges == true)
        #expect(snapshot?.lines.first { $0.id == firstId }?.text == "本编辑器草稿文本测试")
        // 库中保持另一连接的版本，未被回写。
        let stored = try await store.document(id: document.id)
        #expect(stored?.revision == 2)
        #expect(stored?.lines.first { $0.id == firstId }?.text == "其他窗口的文本测试")
    }

    // MARK: - 译文与共享提示

    @Test("译文编辑：manual 写入、清空即删除、人工改写清除待复核；共享绑定计数")
    func translationEditsAndSharing() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: document.id)
        let firstId = document.lines[0].id

        // 先改原文触发待复核，再人工改写译文 → 清除待复核。
        _ = try await service.setLineText(lineId: firstId, text: "改后原文测试")
        var snapshot = try await service.setTranslation(
            lineId: firstId, language: "zh-Hans", text: "人工重写译文测试"
        )
        var translation = snapshot.lines.first { $0.id == firstId }?.translations["zh-Hans"]
        #expect(translation?.text == "人工重写译文测试")
        #expect(translation?.source == .manual)
        #expect(translation?.needsReview == false)

        // 空文本 → 删除该语言译文（合理降级）。
        snapshot = try await service.setTranslation(lineId: firstId, language: "zh-Hans", text: "")
        #expect(snapshot.lines.first { $0.id == firstId }?.translations.isEmpty == true)

        // 新增第二语言译文。
        snapshot = try await service.setTranslation(
            lineId: firstId, language: "zh-Hant", text: "繁體譯文測試"
        )
        translation = snapshot.lines.first { $0.id == firstId }?.translations["zh-Hant"]
        #expect(translation?.text == "繁體譯文測試")

        // 同一文档再绑到第二首曲目 → 共享绑定计数为 2。
        try await store.updateBinding(
            SongBinding(track: Fixture.trackB, lyricDocumentId: document.id)
        )
        let shared = try await service.bindingsSharingCurrentDocument()
        #expect(shared.count == 2)
        #expect(shared.map(\.trackKey) == shared.map(\.trackKey).sorted())
    }

    // MARK: - 会话守卫与上限

    @Test("会话守卫：noOpenEditor / editorAlreadyOpen / documentNotFound / shouldConfirmClose")
    func sessionGuards() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let document = try await EditFixture.seedEditableDocument(in: store)
        let service = LyricsEditingService(store: store)

        await expectEditingError(.noOpenEditor) { _ = try await service.undo() }
        await expectEditingError(.noOpenEditor) {
            _ = try await service.setLineText(lineId: UUID(), text: "未打开测试")
        }
        let ghostId = UUID()
        await expectEditingError(.documentNotFound(ghostId)) {
            _ = try await service.openEditor(documentId: ghostId)
        }
        #expect(await service.shouldConfirmClose == false)

        _ = try await service.openEditor(documentId: document.id)
        await expectEditingError(.editorAlreadyOpen) {
            _ = try await service.openEditor(documentId: document.id)
        }
        #expect(await service.shouldConfirmClose == false)
        _ = try await service.setLineText(lineId: document.lines[0].id, text: "守卫测试")
        #expect(await service.shouldConfirmClose == true)

        // discard 后守卫解除；closeEditor 幂等且回到 idle。
        await service.discard()
        #expect(await service.shouldConfirmClose == false)
        await service.closeEditor()
        await service.closeEditor()
        #expect(await service.currentPhase == .idle)
        #expect(try await store.document(id: document.id)?.revision == 1)
    }

    @Test("行数上限：达到 10,000 行后新增被类型化拒绝")
    func lineLimitReached() async throws {
        let (store, dir) = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(dir) }
        let fullDocument = LyricDocument(
            sourceFormat: .lrc,
            lines: (0..<LyricsEditingError.lineLimit).map { index in
                LyricLine(startMs: Int64(index) * 1_000, text: "上限测试第\(index)行")
            }
        )
        try await store.save(
            document: fullDocument,
            binding: SongBinding(track: Fixture.trackA, lyricDocumentId: fullDocument.id)
        )
        let service = LyricsEditingService(store: store)
        _ = try await service.openEditor(documentId: fullDocument.id)

        await expectEditingError(.lineLimitReached(limit: LyricsEditingError.lineLimit)) {
            try await service.addLine(after: nil, text: "超出上限测试")
        }
        #expect(try await service.currentSnapshot()?.lines.count == LyricsEditingError.lineLimit)
    }
}
