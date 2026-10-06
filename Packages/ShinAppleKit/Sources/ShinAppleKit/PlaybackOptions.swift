import Foundation

/// 对应 Music 公开脚本词典 song repeat 的三个值。
public enum PlaybackRepeatMode: String, CaseIterable, Sendable {
    case off, all, one
}

public struct PlaybackOptionsSnapshot: Equatable, Sendable {
    /// Music 应用音量，0...100；不表示 macOS 系统或 AirPlay 设备音量。
    public var volume: Int?
    public var shuffleEnabled: Bool?
    public var repeatMode: PlaybackRepeatMode?

    public init(volume: Int? = nil, shuffleEnabled: Bool? = nil, repeatMode: PlaybackRepeatMode? = nil) {
        self.volume = volume
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
    }
}

/// 独立于播放采样；每次设置均返回 Music 读回的值，不乐观假定写入成功。
public protocol PlaybackOptionsControlling: AnyObject, Sendable {
    func readOptions() async throws -> PlaybackOptionsSnapshot
    func setVolume(_ volume: Int) async throws -> PlaybackOptionsSnapshot
    func setShuffleEnabled(_ enabled: Bool) async throws -> PlaybackOptionsSnapshot
    func setRepeatMode(_ mode: PlaybackRepeatMode) async throws -> PlaybackOptionsSnapshot
}

public enum PlaybackOptionsError: Error, Equatable, Sendable, LocalizedError {
    case invalidVolume

    public var errorDescription: String? { "音量必须介于 0 与 100 之间。" }
}

/// 仅保存演示选项，不读取或控制 Music。
public actor MockPlaybackOptionsController: PlaybackOptionsControlling {
    private var snapshot: PlaybackOptionsSnapshot

    public init(snapshot: PlaybackOptionsSnapshot = .init(volume: 50, shuffleEnabled: false, repeatMode: .off)) {
        self.snapshot = snapshot
    }

    public func readOptions() async throws -> PlaybackOptionsSnapshot {
        try Task.checkCancellation()
        return snapshot
    }

    public func setVolume(_ volume: Int) async throws -> PlaybackOptionsSnapshot {
        try Task.checkCancellation()
        guard (0...100).contains(volume) else { throw PlaybackOptionsError.invalidVolume }
        snapshot.volume = volume
        return snapshot
    }

    public func setShuffleEnabled(_ enabled: Bool) async throws -> PlaybackOptionsSnapshot {
        try Task.checkCancellation()
        snapshot.shuffleEnabled = enabled
        return snapshot
    }

    public func setRepeatMode(_ mode: PlaybackRepeatMode) async throws -> PlaybackOptionsSnapshot {
        try Task.checkCancellation()
        snapshot.repeatMode = mode
        return snapshot
    }
}
