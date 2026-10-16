import AppKit
import Foundation

@main
private struct AppTerminationCheck {
    private enum FakeFailure: Error { case unavailable }

    @MainActor static func main() async throws {
        checkPreferences()
        checkSkippedCleanup()
        try await checkCompletion()
        try await checkFailure()
        try await checkTimeout()
        print("App 退出检查通过：默认开启、偏好持久化、关闭和 Mock、取消顺序、重复退出、完成、失败、超时与迟到结果。")
    }

    @MainActor private static func checkPreferences() {
        let name = "shin-termination-check-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        precondition(PlaybackCleanupSettings.isEnabled(defaults: defaults), "未设置应默认开启")
        defaults.set(false, forKey: PlaybackCleanupSettings.preferenceKey)
        precondition(!PlaybackCleanupSettings.isEnabled(defaults: defaults), "不得覆盖显式关闭")
        let recreated = UserDefaults(suiteName: name)!
        precondition(!PlaybackCleanupSettings.isEnabled(defaults: recreated), "重建后应尊重已保存偏好")
        defaults.set(true, forKey: PlaybackCleanupSettings.preferenceKey)
        precondition(PlaybackCleanupSettings.isEnabled(defaults: recreated), "重新开启应立即生效")
        precondition(!PlaybackCleanupSettings.shouldCleanup(isMock: true, defaults: defaults), "Mock 不触发 Music 清理")
    }

    @MainActor private static func checkSkippedCleanup() {
        let name = "shin-termination-skip-check-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for isMock in [false, true] {
            defaults.set(isMock, forKey: PlaybackCleanupSettings.preferenceKey)
            let delegate = AppTerminationDelegate()
            var prepared = 0
            delegate.configure(
                prepare: { prepared += 1 },
                shouldCleanup: { PlaybackCleanupSettings.shouldCleanup(isMock: isMock, defaults: defaults) },
                cleanup: { preconditionFailure("关闭设置或 Mock 不得执行清理") }
            )
            precondition(delegate.requestTermination { _ in preconditionFailure("立即退出不应异步回复") } == .terminateNow)
            precondition(delegate.requestTermination { _ in preconditionFailure("重复退出不应异步回复") } == .terminateNow)
            precondition(prepared == 1, "关闭或 Mock 仍须同步取消本 App 任务，且只执行一次")
        }
    }

    @MainActor private static func checkCompletion() async throws {
        let delegate = AppTerminationDelegate()
        var events: [String] = []
        var replies = 0
        var releaseCleanup: CheckedContinuation<Void, Never>?
        delegate.configure(
            prepare: { events.append("cancel-app-tasks") },
            shouldCleanup: { true },
            cleanup: {
                precondition(events == ["cancel-app-tasks"], "任务必须在清理前取消")
                events.append("cleanup")
                await withCheckedContinuation { releaseCleanup = $0 }
            }
        )
        precondition(delegate.requestTermination { allowed in
            precondition(allowed)
            replies += 1
            events.append("reply")
        } == .terminateLater)
        precondition(delegate.requestTermination { _ in preconditionFailure("重复 Quit 不应替换回复") } == .terminateLater)
        try await waitUntil { releaseCleanup != nil }
        precondition(replies == 0, "清理结束前不得放行")
        releaseCleanup?.resume()
        releaseCleanup = nil
        try await waitUntil { replies == 1 }
        precondition(events == ["cancel-app-tasks", "cleanup", "reply"])
        precondition(delegate.requestTermination { _ in preconditionFailure("完成后不得重复回复") } == .terminateNow)
    }

    @MainActor private static func checkFailure() async throws {
        let delegate = AppTerminationDelegate()
        var prepared = false
        var replies = 0
        delegate.configure(
            prepare: { prepared = true },
            shouldCleanup: { true },
            cleanup: {
                precondition(prepared)
                throw FakeFailure.unavailable
            }
        )
        precondition(delegate.requestTermination { allowed in
            precondition(allowed)
            replies += 1
        } == .terminateLater)
        try await waitUntil { replies == 1 }
        precondition(delegate.requestTermination { _ in preconditionFailure("失败也仅回复一次") } == .terminateNow)
    }

    @MainActor private static func checkTimeout() async throws {
        let delegate = AppTerminationDelegate()
        var replies = 0
        var releaseCleanup: CheckedContinuation<Void, Never>?
        var wasCancelled = false
        var didFinishCleanup = false
        delegate.configure(
            prepare: {},
            shouldCleanup: { true },
            cleanup: {
                // 模拟正在等待 Apple Event 的任务：收到取消也暂不返回。
                await withCheckedContinuation { releaseCleanup = $0 }
                wasCancelled = Task.isCancelled
                didFinishCleanup = true
            },
            timeout: .milliseconds(40)
        )
        let started = ContinuousClock.now
        precondition(delegate.requestTermination { allowed in
            precondition(allowed)
            replies += 1
        } == .terminateLater)
        try await waitUntil { releaseCleanup != nil }
        try await waitUntil { replies == 1 }
        precondition(started.duration(to: .now) < .seconds(1), "超时不能继续等待清理返回")
        precondition(!didFinishCleanup, "放行退出时挂起的清理尚未返回")
        releaseCleanup?.resume()
        releaseCleanup = nil
        try await waitUntil { didFinishCleanup }
        precondition(wasCancelled, "超时应取消清理任务")
        await Task.yield()
        precondition(replies == 1, "迟到结果不得再次放行")
    }

    @MainActor private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            precondition(ContinuousClock.now < deadline, "退出检查等待超时")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
