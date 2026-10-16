import AppKit

/// 正常退出先停止本 App 的任务，再有界等待 Music 清理；关闭窗口不进入此流程。
@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, waiting, finished }
    private var state = State.idle
    private var prepare: @MainActor () -> Void = {}
    private var shouldCleanup: @MainActor () -> Bool = { false }
    private var cleanup: @MainActor () async throws -> Void = {}
    private var timeout = PlaybackCleanupSettings.terminationTimeout
    private var cleanupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var reply: (@MainActor (Bool) -> Void)?

    func configure(
        prepare: @escaping @MainActor () -> Void,
        shouldCleanup: @escaping @MainActor () -> Bool,
        cleanup: @escaping @MainActor () async throws -> Void,
        timeout: Duration = PlaybackCleanupSettings.terminationTimeout
    ) {
        guard state == .idle else { return }
        self.prepare = prepare
        self.shouldCleanup = shouldCleanup
        self.cleanup = cleanup
        self.timeout = timeout
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// reply 可注入以验证退出时序，不退出测试进程或操作真实 Music。
    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        switch state {
        case .waiting: return .terminateLater
        case .finished: return .terminateNow
        case .idle: break
        }
        prepare()
        guard shouldCleanup() else {
            state = .finished
            return .terminateNow
        }
        state = .waiting
        self.reply = reply
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cleanup()
            } catch {
                // 仅报告固定说明，避免输出脚本错误或真实资料库信息。
                if self.state == .waiting {
                    NSLog("ShinApple：退出清理未完成，未清理的应用临时播放清单将保留。")
                }
            }
            self.finishTermination()
        }
        timeoutTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.state == .waiting else { return }
            NSLog("ShinApple：退出清理超时，未清理的应用临时播放清单将保留。")
            self.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard state == .waiting else { return }
        state = .finished
        cleanupTask?.cancel()
        timeoutTask?.cancel()
        cleanupTask = nil
        timeoutTask = nil
        let reply = reply
        self.reply = nil
        // 取消后立即放行，不等待不可及时取消的 Apple Event 返回。
        reply?(true)
    }
}
