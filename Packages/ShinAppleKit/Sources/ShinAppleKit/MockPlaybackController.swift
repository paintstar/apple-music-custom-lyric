import Foundation
import os

/// Mock 队列曲目：带标题与时长，供测试与 Mock UI 使用。
public struct MockTrack: Equatable, Sendable {
    public var identity: CatalogIdentity
    public var title: String?
    /// 歌手名：未知保持 nil，不冒充空串。
    public var artist: String?
    /// 未知时长保持 nil（不冒充 0）。
    public var durationMs: Int64?
    /// 资料库 Mock 使用独立、原创的脚本身份；旧目录队列默认仍为 nil。
    public var trackRef: String?

    public init(
        identity: CatalogIdentity,
        title: String? = nil,
        artist: String? = nil,
        durationMs: Int64? = nil,
        trackRef: String? = nil
    ) {
        self.identity = identity
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
        self.trackRef = trackRef
    }
}

/// 测试完全可控的 Mock 播放控制器。
///
/// 确定性规则：
/// - 时间只来自注入的 `ManualClock`，没有任何真实定时器；
/// - `advanceTime(byMs:)` 是唯一的时间推进入口；
/// - 相同操作序列产生相同快照序列；
/// - 播放结束（到达时长）时按 `autoAdvanceOnEnd` 决定自动切歌或进入 `.ended`。
///
/// 状态语义（与 domain 契约一致）：
/// - 初始：`trackEpoch == 0`、无曲目、`positionMs == nil`、`durationMs == nil`；
/// - 每次装载/切歌：`trackEpoch` 递增；
/// - 错误注入不改变已知时间：未知时间保持 nil，绝不冒充 0；
/// - `dispose()` 清空全部监听，此后不再发出通知；
/// - 通知在锁外同步分发，处理器内调用控制器方法不会死锁。
public final class MockPlaybackController: PlaybackController, @unchecked Sendable {

    private struct Entry: Sendable {
        let id: UUID
        let handler: @Sendable (PlaybackSnapshot) -> Void
    }

    private struct State: Sendable {
        var tracks: [MockTrack] = []
        var index: Int?
        var epoch = 0
        var status: PlayerStatus = .idle
        var errorCode: String?
        /// 基准位置：playing 时真实位置 = base + (now - baseClock)。
        var basePositionMs: Int64?
        var baseClockMs: Int64 = 0
        var lastNotified: PlaybackSnapshot?
        var entries: [Entry] = []
        var disposed = false
    }

    /// 一次变更的产出：要分发的快照与分发时的监听者集合。
    private struct MutationOutcome {
        var snapshot: PlaybackSnapshot
        var changed: Bool
        var handlers: [@Sendable (PlaybackSnapshot) -> Void]
    }

    private let clock: ManualClock
    private let autoAdvanceOnEnd: Bool
    /// 契约 setQueue（只有身份、无时长）装载曲目时使用的默认时长；nil 表示未知。
    private let defaultDurationMs: Int64?
    private let state = OSAllocatedUnfairLock(initialState: State())
    let mockLibraryFavorites = OSAllocatedUnfairLock(initialState: [String: Bool]())

    public init(
        clock: ManualClock = ManualClock(),
        autoAdvanceOnEnd: Bool = true,
        defaultDurationMs: Int64? = nil
    ) {
        self.clock = clock
        self.autoAdvanceOnEnd = autoAdvanceOnEnd
        self.defaultDurationMs = defaultDurationMs
    }

    // MARK: - Mock 专属测试接口

    /// 设置 Mock 队列（带标题/时长）并立即装载第 `startAt` 首开始播放。
    public func setMockQueue(_ tracks: [MockTrack], startAt: Int = 0) {
        dispatch(state.withLock { s in
            s.tracks = tracks
            guard !tracks.isEmpty, tracks.indices.contains(startAt) else {
                s.index = nil
                return finishLocked(&s)
            }
            s.index = startAt
            s.epoch += 1
            s.status = .playing
            s.errorCode = nil
            s.basePositionMs = 0
            s.baseClockMs = clock.nowMs
            return finishLocked(&s)
        })
    }

    /// 唯一的时间推进入口。播放中会推进位置并处理播放结束。
    public func advanceTime(byMs ms: Int64) {
        dispatch(state.withLock { s in
            clock.advance(byMs: ms)
            if s.status == .playing {
                resolvePlaybackEndLocked(&s)
            }
            return finishLocked(&s)
        })
    }

    /// 注入错误。播放时间停在最后已知值（未知则保持 nil）。
    public func injectError(_ error: PlaybackError) {
        dispatch(state.withLock { s in
            let now = clock.nowMs
            if s.status == .playing {
                s.basePositionMs = effectivePositionLocked(s, nowMs: now)
            }
            s.status = .error
            s.errorCode = error.code
            return finishLocked(&s)
        })
    }

    /// 进入缓冲态。位置保持最后已知值（未知则保持 nil）。
    public func simulateBuffering() {
        dispatch(state.withLock { s in
            guard s.index != nil else { return finishLocked(&s) }
            let now = clock.nowMs
            if s.status == .playing {
                s.basePositionMs = effectivePositionLocked(s, nowMs: now)
            }
            s.status = .buffering
            return finishLocked(&s)
        })
    }

    /// 当前监听者数量（测试可观测，用于泄漏检查）。
    public var subscriberCount: Int {
        state.withLock { $0.entries.count }
    }

    // MARK: - PlaybackController

    public func snapshot() -> PlaybackSnapshot {
        state.withLock { makeSnapshotLocked($0) }
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        let id = state.withLock { s -> UUID in
            let id = UUID()
            if !s.disposed {
                s.entries.append(Entry(id: id, handler: handler))
            }
            return id
        }
        return MockSubscription(id: id) { [weak self] subscriptionId in
            guard let self else { return }
            self.state.withLock { s in
                s.entries.removeAll { $0.id == subscriptionId }
            }
        }
    }

    public func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {
        let mockTracks = items.map {
            MockTrack(identity: $0, title: nil, durationMs: defaultDurationMs)
        }
        let startIndex = mockTracks.firstIndex(where: { $0.identity == startAt }) ?? 0
        dispatch(state.withLock { s in
            s.tracks = mockTracks
            guard !mockTracks.isEmpty else {
                s.index = nil
                return finishLocked(&s)
            }
            s.index = startIndex
            s.epoch += 1
            s.status = .playing
            s.errorCode = nil
            s.basePositionMs = 0
            s.baseClockMs = clock.nowMs
            return finishLocked(&s)
        })
    }

    public func play() async throws {
        try dispatchThrowing(state.withLock { s -> Result<MutationOutcome, PlaybackError> in
            guard s.index != nil else { return .failure(.trackUnavailable) }
            let now = clock.nowMs
            switch s.status {
            case .paused:
                s.status = .playing
                s.baseClockMs = now
            case .ended:
                // 结束后再次播放：从头开始当前曲目。
                s.status = .playing
                s.basePositionMs = 0
                s.baseClockMs = now
            case .playing:
                break
            default:
                s.status = .playing
                s.baseClockMs = now
            }
            return .success(finishLocked(&s))
        })
    }

    public func pause() async throws {
        try dispatchThrowing(state.withLock { s -> Result<MutationOutcome, PlaybackError> in
            guard s.index != nil else { return .failure(.trackUnavailable) }
            let now = clock.nowMs
            if s.status == .playing {
                s.basePositionMs = effectivePositionLocked(s, nowMs: now)
                s.status = .paused
            }
            return .success(finishLocked(&s))
        })
    }

    public func seek(positionMs ms: Int64) async throws {
        try dispatchThrowing(state.withLock { s -> Result<MutationOutcome, PlaybackError> in
            guard s.index != nil else { return .failure(.trackUnavailable) }
            let now = clock.nowMs
            s.basePositionMs = clampSeekLocked(s, ms)
            s.baseClockMs = now
            // seek 离开末尾后回到可播放语义（暂停态，等待用户播放）。
            if s.status == .ended, let duration = currentTrackLocked(s)?.durationMs, ms < duration {
                s.status = .paused
            }
            return .success(finishLocked(&s))
        })
    }

    public func next() async throws {
        try dispatchThrowing(state.withLock { s -> Result<MutationOutcome, PlaybackError> in
            guard s.index != nil else { return .failure(.trackUnavailable) }
            let now = clock.nowMs
            if let i = s.index, i + 1 < s.tracks.count {
                switchToLocked(&s, i + 1, nowMs: now)
            } else {
                s.status = .ended
                s.basePositionMs = currentTrackLocked(s)?.durationMs ?? s.basePositionMs
            }
            return .success(finishLocked(&s))
        })
    }

    public func previous() async throws {
        try dispatchThrowing(state.withLock { s -> Result<MutationOutcome, PlaybackError> in
            guard s.index != nil else { return .failure(.trackUnavailable) }
            let now = clock.nowMs
            if let i = s.index, i > 0 {
                switchToLocked(&s, i - 1, nowMs: now)
            } else {
                // 已是第一首：重新开始当前曲目。
                s.status = .playing
                s.basePositionMs = 0
                s.baseClockMs = now
            }
            return .success(finishLocked(&s))
        })
    }

    public func dispose() {
        state.withLock { s in
            s.disposed = true
            s.entries.removeAll()
        }
    }

    // MARK: - 私有实现（*_Locked 函数要求调用方处于 withLock 闭包内）

    /// 统一收尾：生成快照，记录是否变化，返回需要通知的处理器集合。
    private func finishLocked(_ s: inout State) -> MutationOutcome {
        let snapshot = makeSnapshotLocked(s)
        let changed = s.lastNotified != snapshot
        s.lastNotified = snapshot
        return MutationOutcome(
            snapshot: snapshot,
            changed: changed,
            handlers: changed ? s.entries.map(\.handler) : []
        )
    }

    private func dispatch(_ outcome: MutationOutcome) {
        guard outcome.changed else { return }
        for handler in outcome.handlers {
            handler(outcome.snapshot)
        }
    }

    private func dispatchThrowing(_ result: Result<MutationOutcome, PlaybackError>) throws {
        switch result {
        case .failure(let error):
            throw error
        case .success(let outcome):
            dispatch(outcome)
        }
    }

    private func currentTrackLocked(_ s: State) -> MockTrack? {
        guard let index = s.index, s.tracks.indices.contains(index) else { return nil }
        return s.tracks[index]
    }

    /// 计算当前有效位置。无基准（从未装载）返回 nil。
    private func effectivePositionLocked(_ s: State, nowMs: Int64) -> Int64? {
        guard let base = s.basePositionMs else { return nil }
        let raw: Int64
        if s.status == .playing {
            raw = base + (nowMs - s.baseClockMs)
        } else {
            raw = base
        }
        let clamped = max(raw, 0)
        if let duration = currentTrackLocked(s)?.durationMs {
            return min(clamped, duration)
        }
        return clamped
    }

    /// 播放中到达曲目末尾时：自动切下一首，或进入 .ended。
    private func resolvePlaybackEndLocked(_ s: inout State) {
        let now = clock.nowMs
        guard let duration = currentTrackLocked(s)?.durationMs else { return }
        guard let position = effectivePositionLocked(s, nowMs: now), position >= duration else { return }
        if autoAdvanceOnEnd, let i = s.index, i + 1 < s.tracks.count {
            switchToLocked(&s, i + 1, nowMs: now)
        } else {
            s.status = .ended
            s.basePositionMs = duration
            s.baseClockMs = now
        }
    }

    private func switchToLocked(_ s: inout State, _ newIndex: Int, nowMs: Int64) {
        s.index = newIndex
        s.epoch += 1
        s.status = .playing
        s.errorCode = nil
        s.basePositionMs = 0
        s.baseClockMs = nowMs
    }

    private func clampSeekLocked(_ s: State, _ ms: Int64) -> Int64 {
        var clamped = max(ms, 0)
        if let duration = currentTrackLocked(s)?.durationMs {
            clamped = min(clamped, duration)
        }
        return clamped
    }

    private func makeSnapshotLocked(_ s: State) -> PlaybackSnapshot {
        let now = clock.nowMs
        let track = currentTrackLocked(s)
        return PlaybackSnapshot(
            trackEpoch: s.epoch,
            track: track?.identity,
            title: track?.title,
            artist: track?.artist,
            positionMs: effectivePositionLocked(s, nowMs: now),
            durationMs: track?.durationMs,
            status: s.status,
            errorCode: s.errorCode,
            trackRef: track?.trackRef
        )
    }
}

/// Mock 订阅句柄。
private final class MockSubscription: PlaybackSubscriptionHandle, @unchecked Sendable {
    private let id: UUID
    private let onCancel: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(id: UUID, onCancel: @escaping @Sendable (UUID) -> Void) {
        self.id = id
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        onCancel(id)
    }
}
