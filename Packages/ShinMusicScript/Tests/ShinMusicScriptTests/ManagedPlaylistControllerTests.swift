import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct ManagedPlaylistControllerTests {
    @Test("dispose 后仍允许退出清理，自此所有播放入口取消，清理不重新采样")
    func cleanupAfterDispose() async throws {
        let fixture = ContextFixture()
        let domain = "ShinMusicScript.cleanup-controller-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
        let executor = FakeMusicScriptExecutor()
        let controller = MusicScriptPlaybackController(executor: executor, playbackContext: context)
        controller.dispose()
        try await controller.cleanupManagedPlaylistsOnQuit()
        #expect(fixture.stopCount == 1 && fixture.playlists.isEmpty)
        #expect(executor.recordedCommands.isEmpty && executor.recordedReadCount == 0)
        await #expect(throws: CancellationError.self) { try await controller.play() }
        await #expect(throws: CancellationError.self) {
            try await controller.performContextCommand { context, check in
                try context.play([Fixtures.pidB], startingAt: Fixtures.pidB, in: .library,
                                 shuffleEnabled: false, checkCancellation: check)
            }
        }
        #expect(fixture.playlists.isEmpty && fixture.startCount == 1)
    }

    @Test("退出清理排在已进入的上下文操作之后，dispose 使排队播放取消")
    func cleanupSharesCommandQueue() async throws {
        let fixture = ContextFixture()
        let domain = "ShinMusicScript.serial-cleanup-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = MusicPlaybackContext(executor: fixture, defaults: defaults)
        try context.play([Fixtures.pidA], startingAt: Fixtures.pidA, in: .library, shuffleEnabled: false) {}
        let executor = FakeMusicScriptExecutor()
        let controller = MusicScriptPlaybackController(executor: executor, playbackContext: context)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let active = Task {
            try await controller.performContextCommand { _, check in
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw CancellationError() }
                try check()
            }
        }
        let enteredResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 3))
            }
        }
        #expect(enteredResult == .success)
        let queuedPlay = Task { try await controller.play() }
        controller.dispose()
        let cleanup = Task { try await controller.cleanupManagedPlaylistsOnQuit() }
        #expect(fixture.stopCount == 0, "上下文操作未释放，清理不能越过队列")
        release.signal()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await queuedPlay.value }
        try await cleanup.value
        #expect(fixture.stopCount == 1 && fixture.playlists.isEmpty && executor.recordedCommands.isEmpty)
        #expect(executor.recordedReadCount == 0)
    }

    @Test("Mock 的退出清理默认实现不控制 Music")
    func mockCleanupIsNoOp() async throws {
        let controller = MockPlaybackController()
        controller.dispose()
        try await controller.cleanupManagedPlaylistsOnQuit()
    }
}
