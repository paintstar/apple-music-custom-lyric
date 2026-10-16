import Foundation
import ShinAppleKit
@testable import ShinMusicScript

/// OSA 的同步门和解释器不能阻塞 Swift 协作线程；有限并发仍让生命周期测试竞争真实门。
enum MusicScriptTestExecution {
    // 真实 OSA 生命周期共用同一门实现；不与并行的纯 Fake 播放控制器争用生产全局实例。
    private static let gate = MusicScriptExecutionGate()
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ShinMusicScript.tests.OSA"
        queue.qualityOfService = .userInitiated
        // 至少两个工作线程竞争 OSA 门，同时避免 32 个等待者占满系统 GCD 工作线程。
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    enum Failure: Error { case construction, compile(Int?), execute(Int?) }

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    continuation.resume(returning: try gate.withLock(operation))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func compile(_ source: String) async throws {
        try await run {
            guard let script = NSAppleScript(source: source) else { throw Failure.construction }
            var error: NSDictionary?
            guard script.compileAndReturnError(&error), error == nil else {
                throw Failure.compile((error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue)
            }
        }
    }

    static func string(_ source: String) async throws -> String? {
        try await run {
            guard let script = NSAppleScript(source: source) else { throw Failure.construction }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil else { throw Failure.execute((error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue) }
            return result.stringValue
        }
    }
}

// MARK: - 测试夹具（全部原创虚构：测试曲目甲/乙/丙，16 位十六进制假 persistent ID）

enum Fixtures {
    /// 假 persistent ID（十六进制白名单内）。
    static let pidA = "0A1B2C3D4E5F6071"
    static let pidB = "0F0E0D0C0B0A0908"
    static var refA: String { SongBinding.trackKey(persistentID: pidA) }
    static var refB: String { SongBinding.trackKey(persistentID: pidB) }

    static func snapshot(
        state: Int = MusicScriptPlayerState.playing,
        position: Double? = 106.773002624512,
        pid: String = Fixtures.pidA,
        title: String? = "测试曲目甲",
        artist: String? = "测试歌手乙",
        album: String? = "测试专辑丙",
        duration: Double? = 123.871002197266
    ) -> MusicSnapshotOutcome {
        .snapshot(
            MusicScriptRawSnapshot(
                playerStateCode: state,
                positionSeconds: position,
                persistentID: pid,
                title: title,
                artist: artist,
                album: album,
                durationSeconds: duration
            )
        )
    }
}

/// 完全可控的假执行器：快照按脚本队列出列，命令只记录并按需抛错。
/// 不依赖真实 Music.app，无法替代真实环境中的授权与播放验证。
final class FakeMusicScriptExecutor: MusicScriptExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [MusicSnapshotOutcome]
    private var commands: [String] = []
    private var commandFailures: [String: MusicScriptFailure] = [:]
    private var seekValues: [Double] = []
    private var playedPersistentIDs: [String] = []
    private var readCount = 0

    init(outcomes: [MusicSnapshotOutcome] = []) {
        queue = outcomes
    }

    // 编排
    func enqueue(_ outcome: MusicSnapshotOutcome) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(outcome)
    }

    func failCommand(_ name: String, with failure: MusicScriptFailure) {
        lock.lock()
        defer { lock.unlock() }
        commandFailures[name] = failure
    }

    // 观测
    var recordedCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }

    var recordedSeekValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return seekValues
    }

    var recordedPlayedPersistentIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return playedPersistentIDs
    }

    var recordedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }

    // MusicScriptExecutor
    func readSnapshot() -> MusicSnapshotOutcome {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard !queue.isEmpty else { return .failed(.unknown("测试队列已空")) }
        return queue.removeFirst()
    }

    func play() throws {
        try record("play")
    }

    func pause() throws {
        try record("pause")
    }

    func nextTrack() throws {
        try record("nextTrack")
    }

    func previousTrack() throws {
        try record("previousTrack")
    }

    func seek(toSeconds seconds: Double) throws {
        lock.lock()
        seekValues.append(seconds)
        lock.unlock()
        try record("seek")
    }

    func playPersistentID(_ persistentID: String) throws {
        lock.lock()
        playedPersistentIDs.append(persistentID)
        lock.unlock()
        try record("playPersistentID")
    }

    private func record(_ name: String) throws {
        lock.lock()
        commands.append(name)
        let failure = commandFailures[name]
        lock.unlock()
        if let failure {
            throw failure
        }
    }
}

/// 快照通知计数器（线程安全）。
final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var last: PlaybackSnapshot?

    var notificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var lastSnapshot: PlaybackSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func record(_ snapshot: PlaybackSnapshot) {
        lock.lock()
        count += 1
        last = snapshot
        lock.unlock()
    }
}
