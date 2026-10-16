import CoreServices
import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct PlaybackOptionsTests {
    @Test("播放选项保留未知字段；零音量和关闭状态可区分")
    func parsesKnownAndMissingFields() throws {
        let known = try AppleScriptPlaybackOptionsExecutor.parse(Self.list([
            NSAppleEventDescriptor(int32: 0), NSAppleEventDescriptor(boolean: false), NSAppleEventDescriptor(string: "off")
        ]))
        #expect(known == PlaybackOptionsSnapshot(volume: 0, shuffleEnabled: false, repeatMode: .off))
        let missing = try AppleScriptPlaybackOptionsExecutor.parse(Self.list([
            NSAppleEventDescriptor(string: "invalid"), NSAppleEventDescriptor.null(), NSAppleEventDescriptor(string: "unknown")
        ]))
        #expect(missing == PlaybackOptionsSnapshot())
        let outside = try AppleScriptPlaybackOptionsExecutor.parse(Self.list([
            NSAppleEventDescriptor(int32: 101), NSAppleEventDescriptor(int32: 0), NSAppleEventDescriptor.null()
        ]))
        #expect(outside == PlaybackOptionsSnapshot())
    }

    @Test("固定读写模板均可编译；参数不含用户文本且拒绝越界音量")
    func compilesFixedScriptsWithoutExecuting() async throws {
        let commands: [PlaybackOptionsCommand] = [.read, .volume(0), .volume(100), .shuffle(true), .shuffle(false),
                                                  .repeatMode(.off), .repeatMode(.all), .repeatMode(.one)]
        for command in commands {
            try await MusicScriptTestExecution.compile(AppleScriptPlaybackOptionsExecutor.source(for: command))
        }
        #expect(throws: PlaybackOptionsError.invalidVolume) {
            try AppleScriptPlaybackOptionsExecutor.source(for: .volume(-1))
        }
        #expect(throws: PlaybackOptionsError.invalidVolume) {
            try AppleScriptPlaybackOptionsExecutor.source(for: .volume(101))
        }
    }

    @Test("多个并发调用的脚本生命周期不串用 OSA ID；仅执行原创算术，不发送 Music 事件")
    func concurrentScriptLifetimes() async throws {
        let results = try await withThrowingTaskGroup(of: Int32.self) { group in
            for index in 1...32 {
                group.addTask {
                    try await MusicScriptTestExecution.run {
                        guard let script = NSAppleScript(source: "return \(index) * 7") else {
                            throw MusicScriptTestExecution.Failure.construction
                        }
                        var errorInfo: NSDictionary?
                        guard script.compileAndReturnError(&errorInfo) else { throw ScriptLifetimeFailure.compile }
                        let result = script.executeAndReturnError(&errorInfo)
                        guard errorInfo == nil else { throw ScriptLifetimeFailure.execute }
                        return result.int32Value
                    }
                }
            }
            var values: [Int32] = []
            for try await value in group { values.append(value) }
            return values.sorted()
        }
        #expect(results == (1...32).map { Int32($0 * 7) })
    }

    @Test("选项设置返回执行器读回状态，而不是请求值；越界不发送命令")
    func returnsReadbackAndValidatesBeforeQueue() async throws {
        let executor = OptionsTestExecutor(result: .init(volume: 37, shuffleEnabled: false, repeatMode: .one))
        let service = MusicScriptPlaybackOptionsService(executor: executor)
        let result = try await service.setVolume(70)
        #expect(result.volume == 37)
        #expect(executor.commands == [.volume(70)])
        await #expect(throws: PlaybackOptionsError.invalidVolume) { try await service.setVolume(101) }
        #expect(executor.commands.count == 1)
    }

    @Test("随机/循环必须确认写入目标；未生效或未知时保留实际读回并明确失败")
    func confirmsModeChanges() async throws {
        let confirmed = PlaybackOptionsSnapshot(volume: 37, shuffleEnabled: true, repeatMode: .one)
        let service = MusicScriptPlaybackOptionsService(executor: OptionsTestExecutor(result: confirmed))
        #expect(try await service.setShuffleEnabled(true) == confirmed)
        #expect(try await service.setRepeatMode(.one) == confirmed)
        let actualValues = [PlaybackOptionsSnapshot(volume: 37, shuffleEnabled: false, repeatMode: .off),
                            PlaybackOptionsSnapshot(volume: 37)]
        for actual in actualValues {
            let refused = MusicScriptPlaybackOptionsService(executor: OptionsTestExecutor(result: actual))
            do {
                _ = try await refused.setShuffleEnabled(true)
                Issue.record("随机设置未生效不能报告成功")
            } catch let failure as MusicPlaybackOptionsReadbackFailure {
                #expect(failure.snapshot == actual)
                #expect(failure.option == .shuffle)
                #expect(failure.errorDescription?.contains("随机播放") == true)
            }
            do {
                _ = try await refused.setRepeatMode(.one)
                Issue.record("循环设置未生效不能报告成功")
            } catch let failure as MusicPlaybackOptionsReadbackFailure {
                #expect(failure.snapshot == actual)
                #expect(failure.option == .repeatMode)
                #expect(failure.errorDescription?.contains("循环播放") == true)
            }
            #expect(try await refused.readOptions() == actual, "普通读取应保留未知值，不误报设置失败")
        }
    }

    @Test("排队操作取消后不会发送；已执行操作的迟到结果不返回")
    @available(macOS 15.0, *)
    func cancelsQueuedRequest() async throws {
        let executor = OptionsTestExecutor(result: .init(volume: 25), blocksFirst: true)
        let service = MusicScriptPlaybackOptionsService(executor: executor)
        defer { executor.release() }
        let first = Task { try await service.readOptions() }
        try #require(await executor.entered.wait(timeout: .seconds(1)))
        #expect(executor.commands.count == 1)
        let taskExecutor = OptionsRequestTaskExecutor()
        let second = Task.detached(executorPreference: taskExecutor) { try await service.setVolume(80) }
        try #require(await taskExecutor.suspended.wait(timeout: .seconds(1)))
        second.cancel()
        first.cancel()
        executor.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(executor.commands == [.read])
    }

    @Test("执行器等待共享资源期间取消，取得资源后不发送选项命令")
    func cancelsWhileExecutorWaits() async throws {
        let executor = OptionsTestExecutor(blocksBeforeSend: true)
        let service = MusicScriptPlaybackOptionsService(executor: executor)
        defer { executor.release() }
        let request = Task { try await service.setVolume(80) }
        try #require(await executor.entered.wait(timeout: .seconds(1)))
        #expect(executor.hasStarted)
        request.cancel()
        executor.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(executor.commands.isEmpty)
    }

    @Test("读取/写入失败透传可分类错误；Mock 状态独立保存在本机")
    func errorsAndMockState() async throws {
        let service = MusicScriptPlaybackOptionsService(executor: OptionsTestExecutor(failure: .permissionDenied))
        await #expect(throws: MusicScriptFailure.permissionDenied) { try await service.readOptions() }
        let mock = MockPlaybackOptionsController()
        _ = try await mock.setVolume(0)
        _ = try await mock.setShuffleEnabled(true)
        _ = try await mock.setRepeatMode(.all)
        #expect(try await mock.readOptions() == .init(volume: 0, shuffleEnabled: true, repeatMode: .all))
    }

    private static func list(_ fields: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor(listDescriptor: ())
        for (index, field) in ([NSAppleEventDescriptor(string: "ok")] + fields).enumerated() {
            descriptor.insert(field, at: index + 1)
        }
        return descriptor
    }
}

private enum ScriptLifetimeFailure: Error { case compile, execute }

/// 非隔离请求只在此执行器运行；没有就绪 job 才报告挂起，不把首次 enqueue 或泛化跳转当作已经排队。
/// 测试闭包唯一的挂起点是选项服务的 continuation，首请求仍持有服务队列，次请求此时已入队。
@available(macOS 15.0, *)
private final class OptionsRequestTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ShinMusicScript.tests.options-request")
    private let lock = NSLock()
    private var pending = 0
    let suspended = MusicTestSignal()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.withLock { pending += 1 }
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
            let idle = self.lock.withLock { self.pending -= 1; return self.pending == 0 }
            if idle { self.suspended.signal() }
        }
    }
}

private final class OptionsTestExecutor: PlaybackOptionsScriptExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PlaybackOptionsSnapshot
    private let failure: MusicScriptFailure?
    private let blocksFirst: Bool
    private let blocksBeforeSend: Bool
    private let gate = DispatchSemaphore(value: 0)
    let entered = MusicTestSignal()
    private var recorded: [PlaybackOptionsCommand] = []
    private var started = false
    var commands: [PlaybackOptionsCommand] { lock.withLock { recorded } }
    var hasStarted: Bool { lock.withLock { started } }

    init(result: PlaybackOptionsSnapshot = .init(), failure: MusicScriptFailure? = nil,
         blocksFirst: Bool = false, blocksBeforeSend: Bool = false) {
        self.result = result
        self.failure = failure
        self.blocksFirst = blocksFirst
        self.blocksBeforeSend = blocksBeforeSend
    }

    func execute(_ command: PlaybackOptionsCommand, checkCancellation: () throws -> Void) throws -> PlaybackOptionsSnapshot {
        lock.withLock { started = true }
        if blocksBeforeSend { entered.signal(); gate.wait() }
        try checkCancellation()
        let isFirst = lock.withLock { recorded.append(command); return recorded.count == 1 }
        if blocksFirst, isFirst { entered.signal(); gate.wait() }
        if let failure { throw failure }
        return result
    }

    func release() { gate.signal() }
}
