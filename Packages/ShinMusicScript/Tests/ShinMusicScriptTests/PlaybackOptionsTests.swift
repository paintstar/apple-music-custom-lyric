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
    func compilesFixedScriptsWithoutExecuting() throws {
        let commands: [PlaybackOptionsCommand] = [.read, .volume(0), .volume(100), .shuffle(true), .shuffle(false),
                                                  .repeatMode(.off), .repeatMode(.all), .repeatMode(.one)]
        for command in commands {
            try MusicAppleScriptExecution.withLock {
                let source = try AppleScriptPlaybackOptionsExecutor.source(for: command)
                let script = try #require(NSAppleScript(source: source))
                var errorInfo: NSDictionary?
                #expect(script.compileAndReturnError(&errorInfo), "固定播放选项模板应通过编译")
            }
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
                    try MusicAppleScriptExecution.withLock {
                        let script = try #require(NSAppleScript(source: "return \(index) * 7"))
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

    @Test("排队操作取消后不会发送；已执行操作的迟到结果不返回")
    func cancelsQueuedRequest() async throws {
        let executor = OptionsTestExecutor(result: .init(volume: 25), blocksFirst: true)
        let service = MusicScriptPlaybackOptionsService(executor: executor)
        let first = Task { try await service.readOptions() }
        for _ in 0..<200 where executor.commands.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(executor.commands.count == 1)
        let second = Task { try await service.setVolume(80) }
        try await Task.sleep(for: .milliseconds(20))
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
        let request = Task { try await service.setVolume(80) }
        for _ in 0..<200 where !executor.hasStarted { try await Task.sleep(for: .milliseconds(5)) }
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

private final class OptionsTestExecutor: PlaybackOptionsScriptExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PlaybackOptionsSnapshot
    private let failure: MusicScriptFailure?
    private let blocksFirst: Bool
    private let blocksBeforeSend: Bool
    private let gate = DispatchSemaphore(value: 0)
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
        if blocksBeforeSend { _ = gate.wait(timeout: .now() + 3) }
        try checkCancellation()
        let isFirst = lock.withLock { recorded.append(command); return recorded.count == 1 }
        if blocksFirst, isFirst { _ = gate.wait(timeout: .now() + 3) }
        if let failure { throw failure }
        return result
    }

    func release() { gate.signal() }
}
