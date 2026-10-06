import Foundation
import ShinAppleKit

/// 选项读写使用独立串行队列；不占用播放采样执行器或其锁。
public final class MusicScriptPlaybackOptionsService: PlaybackOptionsControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ShinMusicScript.playback-options", qos: .userInitiated)
    private let executor: any PlaybackOptionsScriptExecuting

    public convenience init() { self.init(executor: AppleScriptPlaybackOptionsExecutor()) }

    init(executor: any PlaybackOptionsScriptExecuting) { self.executor = executor }

    public func readOptions() async throws -> PlaybackOptionsSnapshot { try await perform(.read) }

    public func setVolume(_ volume: Int) async throws -> PlaybackOptionsSnapshot {
        guard (0...100).contains(volume) else { throw PlaybackOptionsError.invalidVolume }
        return try await perform(.volume(volume))
    }

    public func setShuffleEnabled(_ enabled: Bool) async throws -> PlaybackOptionsSnapshot {
        try await perform(.shuffle(enabled))
    }

    public func setRepeatMode(_ mode: PlaybackRepeatMode) async throws -> PlaybackOptionsSnapshot {
        try await perform(.repeatMode(mode))
    }

    private func perform(_ command: PlaybackOptionsCommand) async throws -> PlaybackOptionsSnapshot {
        try Task.checkCancellation()
        let cancellation = OptionsCancellation()
        return try await withTaskCancellationHandler {
            let snapshot: PlaybackOptionsSnapshot = try await withCheckedThrowingContinuation { continuation in
                queue.async { [executor] in
                    do {
                        try cancellation.check()
                        let result = try executor.execute(command, checkCancellation: cancellation.check)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            cancellation.cancel()
        }
    }
}

enum PlaybackOptionsCommand: Equatable, Sendable {
    case read, volume(Int), shuffle(Bool), repeatMode(PlaybackRepeatMode)
}

protocol PlaybackOptionsScriptExecuting: Sendable {
    func execute(_ command: PlaybackOptionsCommand, checkCancellation: () throws -> Void) throws -> PlaybackOptionsSnapshot
}

private final class OptionsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    func cancel() { lock.withLock { isCancelled = true } }
    func check() throws {
        if lock.withLock({ isCancelled }) { throw CancellationError() }
    }
}
