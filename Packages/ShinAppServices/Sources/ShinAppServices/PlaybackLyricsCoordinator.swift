import Foundation
import os
import ShinAppleData
import ShinAppleKit
import ShinLyricsEngine

// MARK: - 同步显示输出

/// 同步视图的「当前显示状态」。
/// 协调器只在当前组（或用户延迟）变化时重新产出本值；UI 不逐帧刷新，
/// 时间同步绝不触碰数据库。
public struct PlaybackLyricsDisplay: Equatable, Sendable {

    /// 显示内容：与引擎三态查询一一对应，外加「无可用歌词」。
    public enum Content: Equatable, Sendable {
        /// 尚无可用歌词：未关联、文档全部未打轴、或尚未装载。空态由面板状态机呈现。
        case idle
        /// 有歌词但当前无行：首组之前、未知/无效播放时间、已到结束边界。不猜测。
        case noCurrentLine
        /// 清屏边界：定时空白组生效中（区间被该组消耗，无可见行）。
        case cleared(startMs: Int64)
        /// 当前组：同一起点的行稳定 id，按文档来源顺序。
        case current(lineIds: [UUID])
    }

    public let content: Content
    /// 当前用户延迟（整数毫秒；正数 = 延后显示，本项目 UI 约定）。
    public let userDelayMs: Int64
    /// 稳定的等待边界，不包含逐帧进度；动画位置仍由展示时钟读取。
    public let waitingInterval: LyricsWaitingInterval?

    public init(content: Content, userDelayMs: Int64, waitingInterval: LyricsWaitingInterval? = nil) {
        self.content = content
        self.userDelayMs = userDelayMs
        self.waitingInterval = waitingInterval
    }

    /// 无同步内容的初始状态。
    public static let empty = PlaybackLyricsDisplay(content: .idle, userDelayMs: 0)

    /// 当前组行 id；其余内容为 nil。
    public var currentLineIds: [UUID]? {
        if case let .current(lineIds) = content { return lineIds }
        return nil
    }
}

/// 用户延迟持久化写入器：把「某曲目（按命名空间化 trackKey）当前应生效的
/// userDelayMs」写入仓库。生产实现走 `GRDBLyricsStore.updateBinding`
/// （读改写，只改延迟字段）；测试可注入计数/门控实现。
/// 时间同步路径绝不调用本写入器。
public typealias PlaybackLyricsDelayWriter = @Sendable (
    _ trackKey: String, _ delayMs: Int64
) async throws -> Void

// MARK: - 协调器

/// 播放快照 → 歌词同步显示的协调器。
///
/// 关键保证：
/// - **权威时钟**：SDK 快照位置是唯一时间真值。本类型无任何计时器/插值，
///   每个快照按快照内位置整查一次索引；暂停冻结（同位置零通知）、seek 立即
///   重算、`refresh()` 重算都是该规则的推论，不存在「从旧时间累加」的路径。
/// - **组变化去抖**：每次整查后与上次通知值比较，只有显示状态变化才回调
///   `onDisplayChange`；同组内任意多个快照零通知，绝不逐帧刷新全量状态。
/// - **切歌不闪回**：曲目身份或 trackEpoch 变化立即丢弃旧索引并清零延迟；
///   关联结果按 (track, epoch) 双重校验应用——A 的慢查询返回时已切到 B 则丢弃。
/// - **同步零写库**：时间同步路径不写数据库；唯一写路径是用户显式 `setDelay`
///   的持久化任务（链式串行执行，await 返回的 Task 可确定性等待落盘完成）。
///
/// 线程模型：与 MockPlaybackController 相同——锁内完成状态变更，
/// 锁外同步分发通知；回调内再调用本类型方法不会死锁。
public final class PlaybackLyricsCoordinator: @unchecked Sendable {

    /// 已装载的歌词：只保留索引即可（延迟重建走 withUserDelayMs，不重读文档）。
    private struct Load {
        let index: LyricsTimelineIndex
    }

    private struct State {
        /// 已见快照的曲目键（命名空间化）；nil = 尚无曲目。
        var trackKey: String?
        /// 已见快照的生命周期编号；nil = 尚未见过任何快照。
        var epoch: Int?
        /// 最近一次权威快照（重算的唯一时间来源）。
        var lastSnapshot: PlaybackSnapshot?
        /// 当前用户延迟（正数 = 延后）；曲目切换时清零，装载关联时按绑定恢复。
        var userDelayMs: Int64 = 0
        var load: Load?
        var lastNotified = PlaybackLyricsDisplay.empty
        /// 延迟持久化任务链尾部；新写入等它完成后再执行，保证按调用序落盘。
        var persistTask: Task<Void, Never>?
    }

    private struct MutationOutcome {
        var display = PlaybackLyricsDisplay.empty
        var changed = false
        static let unchanged = MutationOutcome()
    }

    private let onDisplayChange: @Sendable (PlaybackLyricsDisplay) -> Void
    private let onDelayPersistError: @Sendable (Error) -> Void
    private let delayWriter: PlaybackLyricsDelayWriter
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameters:
    ///   - onDisplayChange: 显示状态变化回调（仅变化时调用；调用线程 = 触发线程，
    ///     宿主自行桥接主线程）。
    ///   - onDelayPersistError: 延迟持久化失败回调（原始错误，宿主负责中文呈现）。
    ///   - delayWriter: 延迟持久化写入器；生产用 `standardDelayWriter(store:)`。
    public init(
        onDisplayChange: @escaping @Sendable (PlaybackLyricsDisplay) -> Void,
        onDelayPersistError: @escaping @Sendable (Error) -> Void = { _ in },
        delayWriter: @escaping PlaybackLyricsDelayWriter = { _, _ in }
    ) {
        self.onDisplayChange = onDisplayChange
        self.onDelayPersistError = onDelayPersistError
        self.delayWriter = delayWriter
    }

    /// 生产装配：延迟持久化写入 GRDB 歌词库（读现有绑定 → 只改 userDelayMs → 写回）。
    /// 绑定已不存在（如刚解除关联后到达的迟到写入）时静默跳过：无处可写，不报错。
    public static func standardDelayWriter(store: GRDBLyricsStore) -> PlaybackLyricsDelayWriter {
        { trackKey, delayMs in
            guard let binding = try await store.binding(forTrackKey: trackKey) else { return }
            var updated = binding
            updated.userDelayMs = delayMs
            try await store.updateBinding(updated)
        }
    }

    // MARK: - 输入

    /// 输入一个权威播放快照（App 从 PlaybackController 订阅转发）。
    /// 曲目键（trackRef/目录身份 → trackKey）或 trackEpoch 变化时立即丢弃
    /// 旧歌词并清零延迟，等待新关联结果。
    public func update(snapshot: PlaybackSnapshot) {
        let outcome = state.withLock { s -> MutationOutcome in
            if snapshot.trackKey != s.trackKey || snapshot.trackEpoch != s.epoch {
                s.trackKey = snapshot.trackKey
                s.epoch = snapshot.trackEpoch
                s.load = nil
                s.userDelayMs = 0
            }
            s.lastSnapshot = snapshot
            return Self.recompute(&s)
        }
        notify(outcome)
    }

    /// 应用宿主经 `LyricsAssociationService` 查得的关联结果。
    ///
    /// 过期结果（trackKey 或 epoch 与当前快照不一致）被丢弃，绝不覆盖新曲目。
    /// `document == nil` 或文档没有任何打轴行 → 无同步内容（idle）。
    public func applyLyrics(
        trackKey: String?,
        trackEpoch: Int,
        document: LyricDocument?,
        userDelayMs: Int64
    ) {
        let outcome: MutationOutcome = state.withLock { s in
            guard trackKey == s.trackKey, trackEpoch == s.epoch else { return .unchanged }
            if let document, document.lines.contains(where: { $0.startMs != nil }) {
                s.userDelayMs = userDelayMs
                s.load = Load(index: LyricsTimelineIndex(document: document, userDelayMs: userDelayMs))
            } else {
                s.userDelayMs = 0
                s.load = nil
            }
            return Self.recompute(&s)
        }
        notify(outcome)
    }

    /// 调整用户延迟（正数 = 延后显示）。立即重建索引并按最近快照重算
    /// （`withUserDelayMs` 只换算查询坐标，绝不烘焙进行时间）；
    /// 持久化经链式串行任务异步执行，按调用顺序落盘。
    ///
    /// 持久化规则：
    /// - **最后写胜出（last-write-wins）**：连续多次调整按调用序串行落盘，
    ///   最后一次调整的值是最终持久值；中间值不参与合并；
    /// - **无自动重试**：写入失败只经 `onDelayPersistError` 上报一次，
    ///   绝不自动循环重试；用户下一次调整即一次全新的写入尝试。
    /// - Returns: 持久化任务（等待即包含此前排队的全部写入）；测试可 await。
    @discardableResult
    public func setDelay(_ newDelayMs: Int64) -> Task<Void, Never> {
        let (task, outcome) = state.withLock { s -> (Task<Void, Never>, MutationOutcome) in
            s.userDelayMs = newDelayMs
            if let load = s.load {
                s.load = Load(index: load.index.withUserDelayMs(newDelayMs))
            }
            let capturedTrackKey = s.trackKey
            let writer = delayWriter
            let reportError = onDelayPersistError
            let previous = s.persistTask
            let persist = Task<Void, Never> {
                await previous?.value
                guard let trackKey = capturedTrackKey else { return }
                do {
                    try await writer(trackKey, newDelayMs)
                } catch {
                    reportError(error)
                }
            }
            s.persistTask = persist
            return (persist, Self.recompute(&s))
        }
        notify(outcome)
        return task
    }

    /// 前台恢复等外部触发的重算入口：按最近一次权威快照重新整查。
    /// 本类型从不用计时器累加，重算即从真实位置重新出发；显示未变化时零通知。
    public func refresh() {
        let outcome = state.withLock { s in Self.recompute(&s) }
        notify(outcome)
    }

    // MARK: - 查询

    /// 当前显示状态（初始化/重建面板时拉取一次；此后以 onDisplayChange 推送为准）。
    public func currentDisplay() -> PlaybackLyricsDisplay {
        state.withLock { $0.lastNotified }
    }

    /// 点击歌词行 → 应请求的播放位置：引擎按偏移公式反算 effectiveStartMs，
    /// 并按 [0, durationMs]（时长已知时）裁剪，负值裁到 0。
    /// 无歌词 / 未知行 id / 未打轴行 → nil（调用方不发起跳转）。
    public func seekPositionMs(forLineId id: UUID) -> Int64? {
        state.withLock { s -> Int64? in
            guard let load = s.load else { return nil }
            return load.index.seekPositionMs(forLineId: id, durationMs: s.lastSnapshot?.durationMs)
        }
    }

    // MARK: - 内部（recompute 为静态纯函数：要求调用方持有锁）

    /// 整查索引并与上次通知比较；只有显示状态变化才标记 changed（组变化去抖）。
    private static func recompute(_ s: inout State) -> MutationOutcome {
        let content: PlaybackLyricsDisplay.Content
        let waitingInterval = s.load?.index.waitingInterval(
            playbackMs: s.lastSnapshot?.positionMs, durationMs: s.lastSnapshot?.durationMs
        )
        if let load = s.load {
            switch load.index.query(
                playbackMs: s.lastSnapshot?.positionMs,
                durationMs: s.lastSnapshot?.durationMs
            ) {
            case .noCurrentLine:
                content = .noCurrentLine
            case let .cleared(boundary):
                content = .cleared(startMs: boundary.startMs)
            case let .current(lines):
                content = .current(lineIds: lines.map(\.id))
            }
        } else {
            content = .idle
        }
        let display = PlaybackLyricsDisplay(
            content: content, userDelayMs: s.userDelayMs, waitingInterval: waitingInterval
        )
        guard display != s.lastNotified else { return .unchanged }
        s.lastNotified = display
        return MutationOutcome(display: display, changed: true)
    }

    private func notify(_ outcome: MutationOutcome) {
        guard outcome.changed else { return }
        onDisplayChange(outcome.display)
    }
}
