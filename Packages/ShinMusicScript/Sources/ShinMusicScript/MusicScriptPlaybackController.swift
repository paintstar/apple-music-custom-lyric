import Foundation
import os
import ShinAppleKit

/// 「音乐」App 脚本适配器：满足现有 PlaybackController 契约。
///
/// 设计要点：
/// - **采样制**：真实时间只来自脚本采样（`player position`），不用计时器累加
///   冒充进度；秒→整数毫秒换算只在适配器边界（MusicScriptMapping.secondsToMs）。
/// - 快照携带采样时机、会话与能力信息；未知值 nil。
/// - persistent ID 变化时递增 trackEpoch；同批身份变化的快照整批丢弃。
/// - 命令发送后读回，结果以快照为准；错误由 MusicScriptMapping 分类。
///
/// 线程模型：与 MockPlaybackController 相同——状态锁内合并、锁外分发；
/// 执行器先进入 OSA 调度门，再获取专用执行锁；独立封面实例有自己的执行锁。
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
        var latestReadOrder = 0
        var vocabularyReadback: MusicVocabularyReadback?
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

    private enum TransportSnapshot {
        case refresh
        case ready(PublishOutcome?)
    }

    /// 会话编号：进程内每次构造新控制器递增（区分适配器重启前后的快照流）。
    private static let sessionCounter = OSAllocatedUnfairLock(initialState: 0)

    private let executor: MusicScriptExecutor
    /// 执行锁：保证 SBApplication/NSAppleScript 的串行访问（不嵌套状态锁）。
    private let executorLock = NSLock()
    /// 只在执行锁内读写；和快照发布序号分开，保留未发布采样的先后关系。
    private var sampleReadOrder = 0
    private var sampleTime: @Sendable () -> Int64 = MusicScriptPlaybackController.monotonicNowMs
    private let playbackCommandQueue = MusicPlaybackCommandQueue()
    private let artworkAccess: MusicCurrentArtworkAccess
    private var playbackContext = MusicPlaybackContext()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let samplingIntervalNanos: UInt64
    private let sessionEpoch: Int
    /// 重型资料库读取有自己的串行执行器，不能阻塞播放采样锁。
    private(set) var libraryCache = MusicLibraryCache()
    /// 本适配器实现 Music 词典中的播放、停止、切歌和跳转命令；
    /// 命令能否执行仍受授权、曲目与当前播放器状态约束。
    private let capabilities = PlaybackCapabilities(
        playPause: true, next: true, previous: true, seek: true, stop: true
    )

    /// - Parameters:
    ///   - executor: 主执行器（生产环境为 ScriptingBridgeExecutor）。
    ///   - libraryLocator: 保留旧构造参数以兼容调用方；点播统一使用完整播放上下文。
    ///   - samplingIntervalMs: 采样间隔；测试可传极小值并手动调用 refreshOnce。
    ///   - startsSampler: false 时不启动自动采样（单元测试确定性使用）。
    public init(
        executor: MusicScriptExecutor,
        libraryLocator: MusicScriptExecutor? = nil,
        artworkProvider: (any MusicArtworkProviding)? = nil,
        samplingIntervalMs: Int = MusicScriptPlaybackController.defaultSamplingIntervalMs,
        startsSampler: Bool = true
    ) {
        self.executor = executor
        self.artworkAccess = MusicCurrentArtworkAccess(executor: executor, provider: artworkProvider, executorLock: executorLock)
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

    /// 内部测试注入仅替换临时歌单执行器，不向测试发送真实 Music 事件。
    convenience init(executor: MusicScriptExecutor, playbackContext: MusicPlaybackContext,
                     libraryReader: (any MusicLibraryScriptReading)? = nil) {
        self.init(executor: executor, startsSampler: false)
        self.playbackContext = playbackContext
        if let libraryReader { self.libraryCache = MusicLibraryCache(reader: libraryReader) }
    }

    /// Fake 采样可用手动时钟；测试实例不启动后台采样。
    convenience init(executor: MusicScriptExecutor, sampleTime: @escaping @Sendable () -> Int64) {
        self.init(executor: executor, startsSampler: false)
        self.sampleTime = sampleTime
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
            guard !s.disposed else { task.cancel(); return }
            s.samplingTask = task
        }
    }

    /// 一次采样（读取在执行锁内计时，合并在状态锁内）。
    /// 返回 false 表示已 dispose（采样循环退出条件）。
    @discardableResult
    private func sampleOnce() -> Bool {
        guard !state.withLock({ $0.disposed }) else { return false }
        let sample: MusicScriptSample? = MusicAppleScriptExecution.withSamplingLock {
            executorLock.withLock {
                guard !state.withLock({ $0.disposed }) else { return nil }
                return readSampleLocked()
            }
        }
        guard let sample else { return false }
        deliver(merge(sample))
        return !isDisposed
    }

    private func readSampleLocked() -> MusicScriptSample {
        let startedAt = sampleTime()
        let outcome = executor.readSnapshot()
        let sampledAt = sampleTime()
        sampleReadOrder += 1
        return MusicScriptSample(
            order: sampleReadOrder, outcome: outcome, sampledAtMs: sampledAt, requestDurationMs: sampledAt - startedAt
        )
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
        try await performTransportCommand { try self.executor.play() }
    }

    public func pause() async throws {
        try await performTransportCommand { try self.executor.pause() }
    }

    public func stop() async throws {
        try await performTransportCommand { try self.executor.stop() }
    }

    public func seek(positionMs ms: Int64) async throws {
        try await performSeek(ms, expected: nil)
    }

    public func seek(positionMs ms: Int64, expected: PlaybackSnapshot) async throws {
        try await performSeek(ms, expected: expected)
    }

    private func performSeek(_ ms: Int64, expected: PlaybackSnapshot?) async throws {
        try await performTransportCommand(preservingReadback: true) { [self] checkCancellation in
            let current = snapshot()
            let clampedMs = min(max(ms, 0), current.durationMs ?? Int64.max)
            let seconds = Double(clampedMs) / 1_000
            try checkCancellation()
            if let expected {
                guard current.sessionEpoch == expected.sessionEpoch, current.trackEpoch == expected.trackEpoch,
                      let trackRef = expected.trackRef, trackRef == current.trackRef,
                      let persistentID = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else {
                    throw CancellationError()
                }
                try executor.seek(toSeconds: seconds, expectedPersistentID: persistentID)
            } else {
                try executor.seek(toSeconds: seconds)
            }
            state.withLock { $0.vocabularyReadback = nil }
            return ((), .refresh)
        }
    }

    public func next() async throws {
        try await performTransportCommand { try self.executor.nextTrack() }
    }

    public func previous() async throws {
        try await performTransportCommand { try self.executor.previousTrack() }
    }

    var isDisposed: Bool {
        state.withLock { $0.disposed }
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
        playbackCommandQueue.cancelAll()
    }

    public func cleanupManagedPlaylistsOnQuit() async throws {
        // 先关闭新播放入口；清理与已经排队的播放共用串行队列，可在 dispose 后调用。
        dispose()
        try Task.checkCancellation()
        let cancellation = MusicLibraryCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playbackCommandQueue.async(cancellation: cancellation, allowsAfterDisposal: true) { [self] in
                    do {
                        try playbackContext.cleanupOnQuit { try cancellation.check() }
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel() }
    }

    /// 兼容单曲入口也先获取完整资料库，再通过统一上下文整单播放。
    /// 命名空间、白名单不符或完整快照中不存在时抛 trackUnavailable。
    public func playTrackRef(_ trackRef: String) async throws {
        guard MusicScriptMapping.persistentID(fromTrackRef: trackRef) != nil else {
            throw PlaybackError.trackUnavailable
        }
        try Task.checkCancellation()
        guard !state.withLock({ $0.disposed }) else { throw CancellationError() }
        let refs = try await libraryCache.playbackTrackRefs(in: .library)
        guard refs.contains(trackRef) else { throw PlaybackError.trackUnavailable }
        try await playTracks(refs, startingAt: trackRef, in: .library, shuffleEnabled: nil)
    }

    func performVocabularyExample(
        trackKey: String, positionMs: Int64?, expected: PlaybackSnapshot?
    ) async throws -> VocabularyPlaybackResult {
        guard let persistentID = MusicScriptMapping.persistentID(fromTrackRef: trackKey) else {
            throw PlaybackError.trackUnavailable
        }
        return try await performTransportCommand(preservingReadback: true) { [self] checkCancellation in
            let previous = snapshot()
            let result = try executor.playVocabularyExample(
                persistentID: persistentID, positionMs: positionMs, expected: expected, current: previous,
                checkCancellation: checkCancellation
            )
            switch result {
            case .played:
                return (positionMs == nil ? .played : .targetNotReady, .refresh)
            case .queueProtected:
                return (.queueProtected, expected == nil ? .refresh : .ready(nil))
            case .targetNotReady:
                return (.targetNotReady, .refresh)
            case .positionRequested(let targetMs):
                state.withLock { $0.vocabularyReadback = nil }
                let readback = MusicVocabularyReadback(
                    trackRef: trackKey, targetMs: targetMs,
                    previousPositionMs: previous.trackRef == trackKey ? previous.positionMs : nil
                )
                return try confirmVocabularyPosition(readback, checkCancellation: checkCancellation)
            }
        }
    }

    func performContextCommand(
        _ operation: @escaping @Sendable (MusicPlaybackContext, () throws -> Void) throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let cancellation = MusicLibraryCancellation()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    playbackCommandQueue.async(cancellation: cancellation) { [self] in
                        do {
                            try cancellation.check()
                            guard !state.withLock({ $0.disposed }) else { throw CancellationError() }
                            state.withLock { $0.vocabularyReadback = nil }
                            try operation(playbackContext) {
                                try cancellation.check()
                                guard !state.withLock({ $0.disposed }) else { throw CancellationError() }
                            }
                            try cancellation.check()
                            _ = sampleOnce()
                            continuation.resume()
                        } catch {
                            if !(error is CancellationError) { _ = sampleOnce() }
                            continuation.resume(throwing: error)
                        }
                    }
                }
                try Task.checkCancellation()
            } onCancel: { cancellation.cancel() }
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    /// 独立 SB 实例同批校验身份；排队期间取消或 dispose 的旧封面不再发送事件。
    public func fetchCurrentTrackArtwork(shouldCancel: () -> Bool = { false }) -> MusicArtworkResult? {
        artworkAccess.fetch {
            shouldCancel() || state.withLock({ $0.disposed })
        }
    }
}

extension MusicScriptPlaybackController {

    /// 同步 Apple Events 由专用队列承接，避免切歌等待阻塞 UI 或 Swift 协作线程。
    /// 排队期间取消/dispose 的命令不再发出；已发送事件的结果只经随后采样发布。
    private func performTransportCommand(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await performTransportCommand { _ in
            try body()
            return ((), .refresh)
        }
    }

    private func performTransportCommand<Value: Sendable>(
        preservingReadback: Bool = false,
        _ body: @escaping @Sendable (() throws -> Void) throws -> (Value, TransportSnapshot)
    ) async throws -> Value {
        try Task.checkCancellation()
        let cancellation = MusicLibraryCancellation()
        do {
            return try await withTaskCancellationHandler {
                let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                    playbackCommandQueue.async(cancellation: cancellation) { [self] in
                        do {
                            let checkCancellation = { [self] in
                                try cancellation.check()
                                guard !state.withLock({ $0.disposed }) else { throw CancellationError() }
                            }
                            try checkCancellation()
                            let (value, readback) = try MusicAppleScriptExecution.withCancellableLock {
                                try executorLock.withLock {
                                    try checkCancellation()
                                    state.withLock {
                                        $0.latestReadOrder = sampleReadOrder
                                        if !preservingReadback { $0.vocabularyReadback = nil }
                                    }
                                    return try body(checkCancellation)
                                }
                            }
                            // 已确认样本若已合入权威快照，仍须发送通知。
                            switch readback {
                            case .refresh:
                                try checkCancellation()
                                _ = sampleOnce()
                            case .ready(let publication):
                                deliver(publication)
                                try checkCancellation()
                            }
                            continuation.resume(returning: value)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                try Task.checkCancellation()
                return value
            } onCancel: {
                cancellation.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        } catch {
            throw PlaybackError.unknown("music:unknown:\(String(describing: error))")
        }
    }
}

// MARK: - 采样合并与发布

extension MusicScriptPlaybackController {
    private func confirmVocabularyPosition(
        _ readback: MusicVocabularyReadback, checkCancellation: () throws -> Void
    ) throws -> (VocabularyPlaybackResult, TransportSnapshot) {
        let deadline = ContinuousClock.now.advanced(by: MusicVocabularyReadback.confirmationBudget)
        var firstMatchAtMs: Int64?
        while true {
            try checkCancellation()
            let sample = readSampleLocked()
            try checkCancellation()
            let matches = readback.confirms(sample, following: firstMatchAtMs)
            if matches, firstMatchAtMs != nil {
                var protection = readback
                protection.confirm(at: sample.sampledAtMs)
                return (.played, .ready(merge(sample, confirming: protection)))
            }
            if !matches && (ContinuousClock.now >= deadline || !readback.shouldContinueWaiting(for: sample)) {
                return (.targetNotReady, .ready(merge(sample)))
            }
            firstMatchAtMs = matches ? sample.sampledAtMs : nil
            Thread.sleep(forTimeInterval: MusicVocabularyReadback.pollInterval)
        }
    }

    /// 合并时按实际读取顺序丢弃迟到的旧样本；所有监听回调在锁外发送。
    private func merge(
        _ sample: MusicScriptSample, confirming readback: MusicVocabularyReadback? = nil
    ) -> PublishOutcome? {
        state.withLock { s -> PublishOutcome? in
            guard !s.disposed, sample.order > s.latestReadOrder else { return nil }
            s.latestReadOrder = sample.order
            guard let snapshot = sample.snapshot(after: s.snapshot) else { return nil }
            if let readback {
                s.vocabularyReadback = readback
            } else if s.vocabularyReadback?.shouldHold(snapshot, after: s.snapshot) == true {
                return nil
            } else if s.vocabularyReadback?.isActive(for: snapshot) == false {
                s.vocabularyReadback = nil
            }
            let changed = s.snapshot.contentValue != snapshot.contentValue
            let handlers = changed ? s.entries.map(\.handler) : []
            s.snapshot = snapshot
            return PublishOutcome(snapshot: snapshot, changed: changed, handlers: handlers)
        }
    }

    private func deliver(_ result: PublishOutcome?) {
        guard let result, result.changed,
              state.withLock({ !$0.disposed && $0.snapshot.contentValue == result.snapshot.contentValue }) else { return }
        for handler in result.handlers {
            handler(result.snapshot)
        }
    }

    /// 宿主进程单调时钟毫秒（跨进程/跨时钟域不可直接比较）。
    static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
