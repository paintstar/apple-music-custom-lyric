import Foundation
import os
import ShinAppleKit

// MARK: - Music 脚本播放适配器

/// 「音乐」App 脚本适配器：满足现有 PlaybackController 契约。
///
/// 设计要点：
/// - **采样制**：真实时间只来自脚本采样（`player position`），不用计时器累加
///   冒充进度；秒→整数毫秒换算只在适配器边界（MusicScriptMapping.secondsToMs）。
/// - **快照扩展字段**：seq/sessionEpoch/trackRef/sampledAtMonotonicMs/
///   requestDurationMs/capabilities 描述采样时机与执行能力；未知值 nil。
/// - **切歌识别**：persistent ID 变化 → trackEpoch 递增；同批读取前后身份
///   不一致的快照整批丢弃（不组装 A 歌名 + B 进度的混合快照）。
/// - **命令不冒充成功**：play/pause/next/previous/seek 发出后立即触发一次
///   读回，结果以随后的快照为准；失败抛 domain 错误。
/// - **错误分类**：权限拒绝（-1743）、Music 未启动、无曲目、超时、单字段
///   不可用、命令不支持分别映射（MusicScriptMapping）。
///
/// 线程模型：与 MockPlaybackController 相同——状态锁内合并、锁外分发；
/// 执行器（SBApplication/NSAppleScript 非线程安全）由专用执行锁串行化，
/// 仅控制命令允许在执行锁内短读 disposed；禁止持状态锁等待执行锁，回调始终在锁外。
public final class MusicScriptPlaybackController: PlaybackController, @unchecked Sendable {

    /// 默认采样间隔（毫秒）；控制器构造时可覆盖。
    public static let defaultSamplingIntervalMs = 400

    private struct Entry: Sendable {
        let id: UUID
        let handler: @Sendable (PlaybackSnapshot) -> Void
    }

    private struct State: Sendable {
        var snapshot = PlaybackSnapshot()
        var seq = 0
        var trackEpoch = 0
        var lastTrackRef: String?
        var entries: [Entry] = []
        var disposed = false
        var samplingTask: Task<Void, Never>?
    }

    /// 一次采样合并的产出：要分发的快照与监听者集合。
    private struct PublishOutcome {
        var snapshot: PlaybackSnapshot
        var changed: Bool
        var handlers: [@Sendable (PlaybackSnapshot) -> Void]
    }

    /// 会话编号：进程内每次构造新控制器递增（区分适配器重启前后的快照流）。
    private static let sessionCounter = OSAllocatedUnfairLock(initialState: 0)

    private let executor: MusicScriptExecutor
    /// 点播执行器（按 persistent ID 定位音乐库曲目；AppleScript whose 模板）。
    private let libraryLocator: MusicScriptExecutor
    /// 执行锁：保证 SBApplication/NSAppleScript 的串行访问（不嵌套状态锁）。
    private let executorLock = NSLock()
    private let libraryPlayQueue = DispatchQueue(label: "ShinMusicScript.library-play", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let samplingIntervalNanos: UInt64
    private let sessionEpoch: Int
    /// 重型资料库读取有自己的串行执行器，不能阻塞播放采样锁。
    let libraryCache = MusicLibraryCache()
    /// 本适配器实现 Music 词典中的播放、切歌和跳转命令；
    /// 命令能否执行仍受授权、曲目与当前播放器状态约束。
    private let capabilities = PlaybackCapabilities(
        playPause: true, next: true, previous: true, seek: true
    )

    /// - Parameters:
    ///   - executor: 主执行器（生产环境为 ScriptingBridgeExecutor）。
    ///   - libraryLocator: 点播执行器（生产环境为 AppleScriptExecutor；nil 复用主执行器）。
    ///   - samplingIntervalMs: 采样间隔；测试可传极小值并手动调用 refreshOnce。
    ///   - startsSampler: false 时不启动自动采样（单元测试确定性使用）。
    public init(
        executor: MusicScriptExecutor,
        libraryLocator: MusicScriptExecutor? = nil,
        samplingIntervalMs: Int = MusicScriptPlaybackController.defaultSamplingIntervalMs,
        startsSampler: Bool = true
    ) {
        self.executor = executor
        self.libraryLocator = libraryLocator ?? executor
        self.samplingIntervalNanos = UInt64(max(samplingIntervalMs, 1)) * 1_000_000
        self.sessionEpoch = Self.sessionCounter.withLock { current in
            current += 1
            return current
        }
        // 初始快照即携带会话与能力信息（首个采样前的 snapshot() 不缺上下文）。
        state.withLock { s in
            s.snapshot.sessionEpoch = sessionEpoch
            s.snapshot.capabilities = capabilities
        }
        if startsSampler {
            beginSampling()
        }
    }

    deinit {
        state.withLock { $0.samplingTask }?.cancel()
    }

    /// 启动周期采样。采样循环只在未 dispose 时运行；执行调用经执行锁串行。
    private func beginSampling() {
        let interval = samplingIntervalNanos
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.sampleOnce() { return }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
        state.withLock { s in
            guard !s.disposed else {
                task.cancel()
                return
            }
            s.samplingTask = task
        }
    }

    /// 一次采样（读取在执行锁内计时，合并在状态锁内）。
    /// 返回 false 表示已 dispose（采样循环退出条件）。
    @discardableResult
    private func sampleOnce() -> Bool {
        let startedAt = DispatchTime.now()
        let outcome: MusicSnapshotOutcome = executorLock.withLock {
            executor.readSnapshot()
        }
        let requestDurationMs = Int64(
            DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        ) / 1_000_000
        return publish(outcome: outcome, requestDurationMs: requestDurationMs)
    }

    /// 公开的手动刷新入口（控制命令后、测试与前台恢复时调用）。
    @discardableResult
    public func refreshOnce() -> Bool {
        sampleOnce()
    }

    // MARK: - PlaybackController

    public func snapshot() -> PlaybackSnapshot {
        state.withLock { $0.snapshot }
    }

    @discardableResult
    public func subscribe(
        _ handler: @escaping @Sendable (PlaybackSnapshot) -> Void
    ) -> PlaybackSubscriptionHandle {
        let id = state.withLock { s -> UUID in
            let id = UUID()
            if !s.disposed {
                s.entries.append(Entry(id: id, handler: handler))
            }
            return id
        }
        return ScriptControllerSubscription(id: id) { [weak self] subscriptionId in
            guard let self else { return }
            self.state.withLock { s in
                s.entries.removeAll { $0.id == subscriptionId }
            }
        }
    }

    /// v2 语义：现有契约的 setQueue 按目录身份装载队列，而目录 ID ≠ persistent ID
    /// （禁止混用），脚本适配器无法安全执行——如实抛错，不假装装载成功。
    /// 按 persistent ID 点播使用 playTrackRef（见下）。
    public func setQueue(
        _ items: [CatalogIdentity], startAt: CatalogIdentity?
    ) async throws {
        throw PlaybackError.unknown("music-script:setQueueUnsupported（目录 ID 不是 persistent ID）")
    }

    public func play() async throws {
        try performCommand { try self.executor.play() }
    }

    public func pause() async throws {
        try performCommand { try self.executor.pause() }
    }

    public func seek(positionMs ms: Int64) async throws {
        // 越界裁剪：时长已知裁到 [0, duration]，未知保底非负（契约约定）。
        let durationMs = state.withLock { $0.snapshot.durationMs }
        var clampedMs = max(ms, 0)
        if let durationMs {
            clampedMs = min(clampedMs, durationMs)
        }
        let seconds = Double(clampedMs) / 1_000
        try performCommand { try self.executor.seek(toSeconds: seconds) }
    }

    public func next() async throws {
        try performCommand { try self.executor.nextTrack() }
    }

    public func previous() async throws {
        try performCommand { try self.executor.previousTrack() }
    }

    public func dispose() {
        let task: Task<Void, Never>? = state.withLock { s in
            s.disposed = true
            s.entries.removeAll()
            let task = s.samplingTask
            s.samplingTask = nil
            return task
        }
        task?.cancel()
    }

    /// v2 点播预留（契约要求覆写默认实现）：按
    /// `music-script:persistent:<persistentID>` 在音乐库定位曲目并播放；
    /// 命名空间/白名单不符或定位不到抛 trackUnavailable。
    public func playTrackRef(_ trackRef: String) async throws {
        guard let persistentID = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else {
            throw PlaybackError.trackUnavailable
        }
        do {
            try executorLock.withLock {
                try libraryLocator.playPersistentID(persistentID)
            }
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        } catch {
            throw PlaybackError.unknown("music:unknown:\(String(describing: error))")
        }
        sampleOnce()
    }

    /// 仅给已通过白名单的库点播模板使用；短控制命令与采样串行，读库本身不走此锁。
    func performLibraryPlay(_ script: String) async throws {
        try Task.checkCancellation()
        let cancellation = MusicLibraryCancellation()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    libraryPlayQueue.async { [self] in
                        do {
                            try cancellation.check()
                            try executorLock.withLock {
                                try cancellation.check()
                                guard !state.withLock({ $0.disposed }) else { throw CancellationError() }
                                let result = try MusicLibraryScriptExecution.execute(script, cancellation: cancellation)
                                guard result.stringValue == "ok" else { throw MusicLibraryError.sourceUnavailable }
                            }
                            _ = sampleOnce()
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                cancellation.cancel()
            }
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    // MARK: - 封面

    /// 读当前曲目封面（执行锁内同批读取 persistent ID + 图像，与快照采样
    /// 串行化，不与 SBApplication 并发）。执行器不具备封面能力
    /// （Mock / AppleScript 兜底）时返回 nil——调用方走占位渐变，不阻塞。
    public func fetchCurrentTrackArtwork() -> MusicArtworkResult? {
        guard let provider = executor as? MusicArtworkProviding else { return nil }
        return executorLock.withLock {
            provider.readCurrentTrackArtwork()
        }
    }
}

// MARK: - 命令发出与读回

extension MusicScriptPlaybackController {

    /// 命令发出（执行锁内）→ 立即读回一次快照（命令发出不冒充成功）。
    private func performCommand(_ body: @escaping () throws -> Void) throws {
        do {
            try executorLock.withLock {
                try body()
            }
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        } catch {
            throw PlaybackError.unknown("music:unknown:\(String(describing: error))")
        }
        sampleOnce()
    }
}

// MARK: - 采样合并与发布

extension MusicScriptPlaybackController {

    /// 把一次读取结果合并进状态并在内容变化时分发（合并在状态锁内，
    /// 分发在锁外——与 MockPlaybackController 相同的死锁规避模式）。
    private func publish(outcome: MusicSnapshotOutcome, requestDurationMs: Int64) -> Bool {
        let sampledAt = Self.monotonicNowMs()
        let result: PublishOutcome? = state.withLock { s -> PublishOutcome? in
            guard !s.disposed else { return nil }

            var snapshot = PlaybackSnapshot()
            snapshot.sessionEpoch = sessionEpoch
            snapshot.sampledAtMonotonicMs = sampledAt
            snapshot.requestDurationMs = requestDurationMs
            snapshot.capabilities = capabilities

            switch outcome {
            case .identityChangedDuringRead:
                // 同批身份不一致：整批丢弃，保持上一发布值（下个周期重读）。
                return nil
            case .musicNotRunning:
                Self.applyEnvironmentLocked(&s, snapshot: &snapshot, status: .notRunning)
            case .noCurrentTrack(let stateCode):
                Self.applyEnvironmentLocked(&s, snapshot: &snapshot, status: .noTrack)
                // noTrack 语义本身已确定；状态枚举读不出已知值时补 errorCode。
                if let stateCode, MusicScriptMapping.status(forStateCode: stateCode) == nil {
                    snapshot.errorCode = MusicScriptMapping.unknownStateCode(stateCode)
                }
            case .snapshot(let raw):
                Self.applyTrackSnapshotLocked(raw, state: &s, snapshot: &snapshot)
            case .failed(let failure):
                Self.applyFailureLocked(failure, state: &s, snapshot: &snapshot)
            }

            // 内容未变化不发布（seq/采样时间戳不参与比较）。
            s.seq += 1
            snapshot.seq = s.seq
            let changed = s.snapshot.contentValue != snapshot.contentValue
            let handlers = changed ? s.entries.map(\.handler) : []
            s.snapshot = snapshot
            return PublishOutcome(snapshot: snapshot, changed: changed, handlers: handlers)
        }
        // nil 也表示切歌时丢弃了混合身份样本；只有 dispose 才应终止周期采样。
        guard let result else { return state.withLock { !$0.disposed } }
        if result.changed {
            for handler in result.handlers {
                handler(result.snapshot)
            }
        }
        return true
    }

    /// 环境态（未运行/无曲目）统一处理：身份不可读 → trackRef nil、时间 nil；
    /// 之前有曲目时 epoch 递增（装载/卸载都是生命周期变化）。
    private static func applyEnvironmentLocked(
        _ s: inout State,
        snapshot: inout PlaybackSnapshot,
        status: PlayerStatus
    ) {
        if s.lastTrackRef != nil {
            s.lastTrackRef = nil
            s.trackEpoch += 1
        }
        snapshot.trackEpoch = s.trackEpoch
        snapshot.trackRef = nil
        snapshot.status = status
    }

    /// 曲目快照用例：trackRef/epoch 推进 + 字段换算（锁内调用）。
    private static func applyTrackSnapshotLocked(
        _ raw: MusicScriptRawSnapshot,
        state s: inout State,
        snapshot: inout PlaybackSnapshot
    ) {
        let trackRef = raw.persistentID.map { SongBinding.trackKey(persistentID: $0) }
        if trackRef != s.lastTrackRef {
            s.lastTrackRef = trackRef
            s.trackEpoch += 1
        }
        snapshot.trackEpoch = s.trackEpoch
        snapshot.trackRef = trackRef
        snapshot.title = raw.title
        snapshot.artist = raw.artist
        snapshot.positionMs = raw.positionSeconds.flatMap(MusicScriptMapping.secondsToMs)
        snapshot.durationMs = raw.durationSeconds.flatMap(MusicScriptMapping.secondsToMs)
        if let status = MusicScriptMapping.status(forStateCode: raw.playerStateCode) {
            snapshot.status = status
        } else {
            snapshot.status = .error
            snapshot.errorCode = MusicScriptMapping.unknownStateCode(raw.playerStateCode)
        }
    }

    /// 读取失败用例：身份状态视为未变（保留 trackRef/epoch），值字段全部
    /// 置 nil（未知不是旧值），状态显式 error + 稳定错误码（锁内调用）。
    private static func applyFailureLocked(
        _ failure: MusicScriptFailure,
        state s: inout State,
        snapshot: inout PlaybackSnapshot
    ) {
        snapshot.trackEpoch = s.trackEpoch
        snapshot.trackRef = s.lastTrackRef
        snapshot.status = .error
        snapshot.errorCode = failure.errorCode
    }

    /// 宿主进程单调时钟毫秒（跨进程/跨时钟域不可直接比较）。
    static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

/// 适配器订阅句柄（可取消、幂等）。
private final class ScriptControllerSubscription: PlaybackSubscriptionHandle, @unchecked Sendable {
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
