import Foundation

/// SB 封面使用独立实例，图像读取不持播放执行锁；自定义执行器仍遵守原串行契约。
final class MusicCurrentArtworkAccess: @unchecked Sendable {
    private let provider: (any MusicArtworkProviding)?
    private let lock: NSLock
    private let independent: Bool

    init(executor: any MusicScriptExecutor, provider: (any MusicArtworkProviding)?, executorLock: NSLock) {
        if let provider {
            self.provider = provider
            independent = true
            lock = NSLock()
        } else if let bridge = executor as? ScriptingBridgeExecutor {
            self.provider = bridge.makeArtworkProvider()
            independent = true
            lock = NSLock()
        } else {
            self.provider = executor as? any MusicArtworkProviding
            independent = false
            lock = executorLock
        }
    }

    func fetch(shouldCancel: () -> Bool) -> MusicArtworkResult? {
        guard let provider, !shouldCancel() else { return nil }
        if independent { return read(provider, shouldCancel: shouldCancel) }
        return MusicAppleScriptExecution.withLock { read(provider, shouldCancel: shouldCancel) }
    }

    private func read(_ provider: any MusicArtworkProviding, shouldCancel: () -> Bool) -> MusicArtworkResult? {
        lock.withLock {
            guard !shouldCancel() else { return nil }
            let result = provider.readCurrentTrackArtwork()
            return shouldCancel() ? nil : result
        }
    }
}
