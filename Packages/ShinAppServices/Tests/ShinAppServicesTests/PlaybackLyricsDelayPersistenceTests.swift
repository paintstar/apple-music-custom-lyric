import Foundation
import Testing
import ShinAppleData
import ShinAppleKit
@testable import ShinAppServices

@Suite("偏移保存的绑定竞态")
struct PlaybackLyricsDelayPersistenceTests {
    private actor WriteGate {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func pauseFirstWrite() async {
            guard !started else { return }
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [ShinAppleDataError] = []
        private var delays: [Int64] = []

        func record(error: Error) {
            lock.withLock {
                if let error = error as? ShinAppleDataError { errors.append(error) } else {
                    Issue.record("偏移错误应使用既有存储错误类型")
                }
            }
        }

        func record(delay: Int64) { lock.withLock { delays.append(delay) } }
        var savedDelays: [Int64] { lock.withLock { delays } }
        var reportedErrors: [ShinAppleDataError] { lock.withLock { errors } }
    }

    private static func document() -> LyricDocument {
        LyricDocument(sourceFormat: .lrc, lines: [LyricLine(startMs: 1_000, text: "原创偏移测试文本")])
    }

    private static func coordinator(
        store: GRDBLyricsStore, document: LyricDocument, binding: SongBinding,
        gate: WriteGate, recorder: Recorder
    ) -> PlaybackLyricsCoordinator {
        let write = PlaybackLyricsCoordinator.standardDelayWriter(store: store)
        let coordinator = PlaybackLyricsCoordinator(
            onDisplayChange: { _ in },
            onDelayPersistError: { error, _ in recorder.record(error: error) },
            delayWriter: { target, delay in
                await gate.pauseFirstWrite()
                try await write(target, delay)
                recorder.record(delay: delay)
            }
        )
        coordinator.update(snapshot: PlaybackLyricsCoordinatorTests.snapshot(
            track: Fixture.trackA, epoch: 1, positionMs: 1_500
        ))
        coordinator.applyLyrics(
            trackKey: binding.trackKey, trackEpoch: 1, document: document,
            userDelayMs: binding.userDelayMs, binding: binding
        )
        return coordinator
    }

    @Test("等待中的偏移不能修改同曲目的新绑定；换文档后旧错误不影响新状态", arguments: [false, true])
    func rebindRejectsQueuedDelay(applyNewDocument: Bool) async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }
        let original = Self.document()
        let originalBinding = SongBinding(track: Fixture.trackA, lyricDocumentId: original.id)
        try await env.store.save(document: original, binding: originalBinding)
        let gate = WriteGate()
        let recorder = Recorder()
        let coordinator = Self.coordinator(
            store: env.store, document: original, binding: originalBinding, gate: gate, recorder: recorder
        )
        let pending = coordinator.setDelay(500)
        await gate.waitUntilStarted()
        let replacement = Self.document()
        let newBinding = SongBinding(track: Fixture.trackA, lyricDocumentId: replacement.id, userDelayMs: 150)
        try await env.store.save(document: replacement, binding: newBinding)
        if applyNewDocument {
            coordinator.applyLyrics(
                trackKey: newBinding.trackKey, trackEpoch: 1, document: replacement,
                userDelayMs: newBinding.userDelayMs, binding: newBinding
            )
        }
        await gate.release()
        await pending.value
        #expect(try await env.store.binding(for: Fixture.trackA) == newBinding)
        #expect(try await env.store.document(id: original.id) == original)
        #expect(recorder.savedDelays.isEmpty)
        #expect(recorder.reportedErrors.count == (applyNewDocument ? 0 : 1))
        if applyNewDocument { #expect(coordinator.currentDisplay().userDelayMs == 150) }
    }

    @Test("等待中的偏移不能恢复已解绑歌词；切歌后旧错误不影响新歌曲", arguments: [false, true])
    func unlinkDoesNotRestoreBinding(switchTrack: Bool) async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }
        let document = Self.document()
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        try await env.store.save(document: document, binding: binding)
        let gate = WriteGate()
        let recorder = Recorder()
        let coordinator = Self.coordinator(
            store: env.store, document: document, binding: binding, gate: gate, recorder: recorder
        )
        let pending = coordinator.setDelay(-500)
        await gate.waitUntilStarted()
        try await env.store.deleteBinding(for: Fixture.trackA)
        if switchTrack {
            coordinator.update(snapshot: PlaybackLyricsCoordinatorTests.snapshot(
                track: Fixture.trackB, epoch: 2, positionMs: 0
            ))
        }
        await gate.release()
        await pending.value
        #expect(try await env.store.binding(for: Fixture.trackA) == nil)
        #expect(try await env.store.document(id: document.id) == document)
        #expect(recorder.savedDelays.isEmpty)
        #expect(recorder.reportedErrors.count == (switchTrack ? 0 : 1))
        if switchTrack { #expect(coordinator.currentDisplay().userDelayMs == 0) }
    }

    @Test("连续偏移在切歌后仍依次保存原绑定，末次值胜出且另一首歌不变", arguments: [false, true])
    func consecutiveDelaysPersistInOrder(switchTrack: Bool) async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }
        let document = Self.document()
        let binding = SongBinding(
            track: Fixture.trackA, lyricDocumentId: document.id,
            titleHint: "原创曲目提示", artistHint: "虚构作者", durationHintMs: 20_000
        )
        try await env.store.save(document: document, binding: binding)
        let otherDocument = Self.document()
        let otherBinding = SongBinding(track: Fixture.trackB, lyricDocumentId: otherDocument.id, userDelayMs: 250)
        try await env.store.save(document: otherDocument, binding: otherBinding)
        let gate = WriteGate()
        let recorder = Recorder()
        let coordinator = Self.coordinator(
            store: env.store, document: document, binding: binding, gate: gate, recorder: recorder
        )
        coordinator.setDelay(-500)
        await gate.waitUntilStarted()
        coordinator.setDelay(0)
        let last = coordinator.setDelay(750)
        if switchTrack {
            coordinator.update(snapshot: PlaybackLyricsCoordinatorTests.snapshot(
                track: Fixture.trackB, epoch: 2, positionMs: 1_500
            ))
            coordinator.applyLyrics(
                trackKey: otherBinding.trackKey, trackEpoch: 2, document: otherDocument,
                userDelayMs: otherBinding.userDelayMs, binding: otherBinding
            )
        }
        await gate.release()
        await last.value
        var expectedBinding = binding
        expectedBinding.userDelayMs = 750
        #expect(try await env.store.binding(for: Fixture.trackA) == expectedBinding)
        #expect(try await env.store.binding(for: Fixture.trackB) == otherBinding)
        #expect(try await env.store.document(id: document.id) == document)
        #expect(recorder.savedDelays == [-500, 0, 750])
        #expect(recorder.reportedErrors.isEmpty)
        #expect(coordinator.currentDisplay().userDelayMs == (switchTrack ? 250 : 750))
    }

    @Test("旧偏移查询晚于保存完成返回时，不覆盖当前调整；新查询可读取最新值", arguments: [false, true])
    func staleRefreshAfterSaveKeepsLocalDelay(queryStartsAfterCommand: Bool) async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }
        let document = Self.document()
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        try await env.store.save(document: document, binding: binding)
        let writeGate = WriteGate()
        let queryGate = WriteGate()
        let recorder = Recorder()
        let coordinator = Self.coordinator(
            store: env.store, document: document, binding: binding, gate: writeGate, recorder: recorder
        )
        var pending: Task<Void, Never>?
        if queryStartsAfterCommand {
            pending = coordinator.setDelay(500)
            await writeGate.waitUntilStarted()
        }
        let querySequence = coordinator.currentDelaySequence()
        let association = LyricsAssociationService(store: env.store)
        let query = Task {
            let result = try await association.associationState(for: Fixture.trackA)
            await queryGate.pauseFirstWrite()
            return result
        }
        await queryGate.waitUntilStarted()
        if pending == nil {
            pending = coordinator.setDelay(500)
            await writeGate.waitUntilStarted()
        }
        await writeGate.release()
        await pending?.value
        #expect(try await env.store.binding(for: Fixture.trackA)?.userDelayMs == 500)
        await queryGate.release()
        guard case let .available(staleDocument, staleBinding) = try await query.value else {
            Issue.record("门控查询应读取旧关联")
            return
        }
        #expect(staleBinding.userDelayMs == 0)
        coordinator.applyLyrics(
            trackKey: staleBinding.trackKey, trackEpoch: 1, document: staleDocument,
            userDelayMs: staleBinding.userDelayMs, binding: staleBinding,
            expectedDelaySequence: querySequence
        )
        #expect(coordinator.currentDisplay().userDelayMs == 500)

        let freshSequence = coordinator.currentDelaySequence()
        try await env.store.updateBindingDelay(900, expectedBinding: binding, documentRevision: document.revision)
        guard case let .available(freshDocument, freshBinding) = try await association.associationState(for: Fixture.trackA)
        else { Issue.record("新查询应读取最新关联"); return }
        coordinator.applyLyrics(
            trackKey: freshBinding.trackKey, trackEpoch: 1, document: freshDocument,
            userDelayMs: freshBinding.userDelayMs, binding: freshBinding,
            expectedDelaySequence: freshSequence
        )
        #expect(coordinator.currentDisplay().userDelayMs == 900)
        #expect(recorder.reportedErrors.isEmpty)
    }

    @Test("偏移未落盘时A切B再回A，重新查询等保存完成，后续调整从500增至600")
    func returningToTrackWaitsForSubmittedDelay() async throws {
        let env = try TestEnv.makeTempStore()
        defer { TestEnv.cleanup(env.directory) }
        let document = Self.document()
        let binding = SongBinding(track: Fixture.trackA, lyricDocumentId: document.id)
        try await env.store.save(document: document, binding: binding)
        let otherDocument = Self.document()
        let otherBinding = SongBinding(track: Fixture.trackB, lyricDocumentId: otherDocument.id, userDelayMs: 250)
        try await env.store.save(document: otherDocument, binding: otherBinding)
        let gate = WriteGate()
        let recorder = Recorder()
        let coordinator = Self.coordinator(
            store: env.store, document: document, binding: binding, gate: gate, recorder: recorder
        )
        coordinator.setDelay(500)
        await gate.waitUntilStarted()
        coordinator.update(snapshot: PlaybackLyricsCoordinatorTests.snapshot(
            track: Fixture.trackB, epoch: 2, positionMs: 1_500
        ))
        coordinator.applyLyrics(
            trackKey: otherBinding.trackKey, trackEpoch: 2, document: otherDocument,
            userDelayMs: otherBinding.userDelayMs, binding: otherBinding
        )
        coordinator.update(snapshot: PlaybackLyricsCoordinatorTests.snapshot(
            track: Fixture.trackA, epoch: 3, positionMs: 1_500
        ))
        #expect(try await env.store.binding(for: Fixture.trackA)?.userDelayMs == 0)
        let reload = Task {
            // 与面板一致：先等旧生命周期已提交的保存，再读取当前关联。
            await coordinator.waitForPendingDelayWrites()
            let sequence = coordinator.currentDelaySequence()
            let association = LyricsAssociationService(store: env.store)
            guard case let .available(loadedDocument, loadedBinding) = try await association.associationState(for: Fixture.trackA)
            else { Issue.record("返回A后应读到已绑定歌词"); return }
            #expect(loadedBinding.userDelayMs == 500)
            coordinator.applyLyrics(
                trackKey: loadedBinding.trackKey, trackEpoch: 3, document: loadedDocument,
                userDelayMs: loadedBinding.userDelayMs, binding: loadedBinding,
                expectedDelaySequence: sequence
            )
        }
        await gate.release()
        try await reload.value
        #expect(coordinator.currentDisplay().userDelayMs == 500)
        #expect(try await env.store.binding(for: Fixture.trackA)?.userDelayMs == 500)
        await coordinator.setDelay(coordinator.currentDisplay().userDelayMs + 100).value
        #expect(coordinator.currentDisplay().userDelayMs == 600)
        #expect(try await env.store.binding(for: Fixture.trackA)?.userDelayMs == 600)
        #expect(try await env.store.binding(for: Fixture.trackB) == otherBinding)
        #expect(recorder.savedDelays == [500, 600])
        #expect(recorder.reportedErrors.isEmpty)
    }
}
