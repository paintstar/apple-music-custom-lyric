import Foundation

/// 正式 App 并发首次使用 OSA 曾返回 errOSAInvalidID，所有脚本共用这一道进程门。
enum MusicAppleScriptExecution {
    static let gate = MusicScriptExecutionGate()

    static func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try gate.withLock(operation)
    }

    static func withSamplingLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try gate.withLock(priority: .sampling, operation)
    }

    static func withCancellableLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try gate.withCancellableLock(operation)
    }
}

/// 生产只使用上面的全局实例；测试使用独立门验证调度，不占用其他测试的 OSA。
/// 闭包不跨 await；与播放执行锁同时使用时，统一先进入此门。
final class MusicScriptExecutionGate: @unchecked Sendable {
    enum Priority { case background, sampling, playback }
    private let condition = NSCondition()
    private var occupied = false
    private var pendingPlayback: Set<UUID> = []
    private var waitingPlayback = 0
    private let priorityKey = "ShinMusicScript.OSA.playback.\(UUID().uuidString)"
    private let enteredKey = "ShinMusicScript.OSA.entered.\(UUID().uuidString)"

    func reservePlayback() -> PlaybackReservation {
        let reservation = PlaybackReservation(gate: self)
        condition.lock()
        pendingPlayback.insert(reservation.id)
        condition.unlock()
        return reservation
    }

    /// 命令入队即预留；多个预留均可进入播放门，不等待其他预留完成。
    func withPlaybackPriority<Value>(_ reservation: PlaybackReservation,
                                     _ operation: () throws -> Value) rethrows -> Value {
        let threadState = Thread.current.threadDictionary
        let previous = threadState[priorityKey]
        threadState[priorityKey] = reservation
        defer { threadState[priorityKey] = previous }
        return try operation()
    }

    func withLock<Value>(priority: Priority = .background, _ operation: () throws -> Value) rethrows -> Value {
        let threadState = Thread.current.threadDictionary
        // 先过门再拿执行锁，兜底执行器的嵌套脚本沿用同一次准入。
        if threadState[enteredKey] != nil { return try autoreleasepool(invoking: operation) }
        enter(priority: threadState[priorityKey] is PlaybackReservation ? .playback : priority)
        threadState[enteredKey] = true
        defer {
            threadState.removeObject(forKey: enteredKey)
            leave()
        }
        return try autoreleasepool(invoking: operation)
    }

    func withCancellableLock<Value>(_ operation: () throws -> Value) throws -> Value {
        let reservation = Thread.current.threadDictionary[priorityKey] as? PlaybackReservation
        return try withLock {
            try reservation?.check()
            return try operation()
        }
    }

    fileprivate func release(_ id: UUID) {
        condition.lock()
        pendingPlayback.remove(id)
        condition.broadcast()
        condition.unlock()
    }

    fileprivate func contains(_ id: UUID) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return pendingPlayback.contains(id)
    }

    private func enter(priority: Priority) {
        condition.lock()
        if priority == .playback { waitingPlayback += 1 }
        while occupied || (priority == .background && !pendingPlayback.isEmpty)
            || (priority == .sampling && waitingPlayback > 0) {
            condition.wait()
        }
        if priority == .playback { waitingPlayback -= 1 }
        occupied = true
        condition.unlock()
    }

    private func leave() {
        condition.lock()
        occupied = false
        condition.broadcast()
        condition.unlock()
    }
}

/// 取消、dispose、命令完成可重复释放，不会泄漏或减成负计数。
final class PlaybackReservation: @unchecked Sendable {
    let id = UUID()
    private let gate: MusicScriptExecutionGate

    fileprivate init(gate: MusicScriptExecutionGate) { self.gate = gate }
    func release() { gate.release(id) }
    func check() throws {
        if !gate.contains(id) { throw CancellationError() }
    }
}
