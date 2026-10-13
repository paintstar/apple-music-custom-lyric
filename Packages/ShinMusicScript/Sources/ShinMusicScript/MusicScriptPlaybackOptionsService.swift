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
                        try command.confirmModeChange(in: result)
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

    func confirmModeChange(in snapshot: PlaybackOptionsSnapshot) throws {
        switch self {
        case let .shuffle(expected) where snapshot.shuffleEnabled != expected:
            throw MusicPlaybackOptionsReadbackFailure(snapshot: snapshot, option: .shuffle)
        case let .repeatMode(expected) where snapshot.repeatMode != expected:
            throw MusicPlaybackOptionsReadbackFailure(snapshot: snapshot, option: .repeatMode)
        default: break
        }
    }
}

/// 保留 Music 实际读回，供界面校正状态；Apple Event 成功不等于模式已生效。
public struct MusicPlaybackOptionsReadbackFailure: Error, Sendable, LocalizedError {
    public enum Option: Sendable { case shuffle, repeatMode }
    public let snapshot: PlaybackOptionsSnapshot
    public let option: Option

    public var errorDescription: String? {
        switch option {
        case .shuffle:
            if snapshot.shuffleEnabled == nil { return "随机播放切换后无法确认状态，请检查「音乐」App 后重试。" }
            return "「音乐」App 未应用随机播放设置，请检查当前播放列表后重试。"
        case .repeatMode:
            if snapshot.repeatMode == nil { return "循环播放切换后无法确认状态，请检查「音乐」App 后重试。" }
            return "「音乐」App 未应用循环播放设置，请检查当前播放列表后重试。"
        }
    }
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
