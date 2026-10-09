import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 歌词面板状态机：关联查询、空态与同步显示。
// - 关联查询只经 LyricsAssociationService：快照式刷新，序号防旧结果覆盖新状态；
// - 同步高亮数据来自 PlaybackLyricsCoordinator：只有当前组变化才推送，
//   本模型绝不因播放时间采样刷新全量状态（时间同步零数据库写入）；
// - 浏览模式 FOLLOW/MANUAL：每次交互重置 5 秒等待，停止浏览后恢复跟随；
//   编辑与视图消失会取消等待，旧任务不能影响新歌曲/新文档。
// - 查询失败进入 unavailable 静态错误态并保留中文说明；
//   唯一恢复入口是界面上用户显式点击的「重试」（LyricsPanelView），
//   本模型没有任何定时/事件驱动的自动重试。

@MainActor
final class LyricsPanelModel: ObservableObject {

    enum State: Equatable {
        /// 歌词库不可用（初始化失败或查询失败），附中文说明。
        case unavailable(String)
        /// 未在播放曲目（无可关联对象）。
        case noTrack
        /// 正在查询。
        case loading
        /// 当前曲目无本地歌词：显示提示与「导入歌词」入口。
        case unbound
        /// 有绑定但全部行未打轴：静态显示 + 说明。
        case untimedOnly(document: LyricDocument)
        /// 正常：至少一行已打轴，同步高亮与偏移控制可用。
        case ready(document: LyricDocument)
        /// 切歌过渡：上一曲目的内容保留展示
        /// （置灰 + 顶部「正在阅读非当前播放歌曲」提示条），新曲目的关联
        /// 结果到位后整体替换；期间编辑/偏移/解除关联等操作不可用。
        case transitioning(retained: LyricDocument, retainedUntimedOnly: Bool)
    }

    /// 歌词浏览模式：FOLLOW 自动跟随；MANUAL 在停止交互后延迟恢复。
    enum BrowseMode: Equatable {
        case follow
        case manual
    }

    /// 一次滚动定位请求。视图按 requestId 变化执行一次 scrollTo；
    /// 连续 seek/组变化产生新请求并取代旧动画（连续 seek 取消旧滚动）。
    struct ScrollAnchorRequest: Equatable {
        let requestId: UUID
        let lineId: UUID
    }

    /// 偏移调整步长：0.1 秒。
    static let delayStepMs: Int64 = 100

    @Published private(set) var state: State = .loading
    /// 同步显示状态（当前组/无当前行/清屏/无内容 + 当前用户延迟）。
    /// 仅当前组变化时由协调器推送更新。
    @Published private(set) var syncDisplay: PlaybackLyricsDisplay = .empty
    @Published private(set) var browseMode: BrowseMode = .follow
    @Published private(set) var scrollRequest: ScrollAnchorRequest?
    /// 编辑器打开期间为 true：同步视图挂起自动定位，不与编辑器抢焦点
    private(set) var isAutoScrollSuspended = false
    /// 当前展示内容所属的曲目键（nil = 尚未展示任何曲目内容）。
    /// 过渡决策（LyricsPanelTransition）据此判断「同曲目刷新 / 换曲目」。
    private(set) var displayedTrackKey: String?
    /// 已应用关联结果的曲目生命周期；查询开始时不提前更新，避免旧文档被当作新结果。
    private(set) var displayedTrackEpoch: Int?

    private let service: LyricsAssociationService?
    /// 宿主（AppModel）持有的同步协调器；nil = 歌词库初始化失败。
    private(set) var coordinator: PlaybackLyricsCoordinator?
    /// 请求序号：切歌或重复刷新时，旧查询结果不得覆盖新状态。
    private var sequence = 0
    private var requestedTrackEpoch: Int?
    private var visibleAreas: Set<UUID> = []
    private var activeGestures: Set<UUID> = []
    private var manualResumeTask: Task<Void, Never>?
    private var manualResumeGeneration = 0
    private var scrollableLineIds: Set<UUID> = []
    /// 听歌时给用户短暂阅读窗口；不参与歌词时间计算。
    private let manualResumeDelay: Duration


    init(store: GRDBLyricsStore?, manualResumeDelay: Duration = .seconds(5)) {
        self.manualResumeDelay = manualResumeDelay
        service = store.map(LyricsAssociationService.init)
        guard store != nil else {
            state = .unavailable("本地歌词库不可用，无法读写歌词。")
            return
        }
    }

    /// 宿主在创建协调器后注入，并拉取一次当前显示状态对齐面板。
    func attach(coordinator: PlaybackLyricsCoordinator) {
        self.coordinator = coordinator
        apply(display: coordinator.currentDisplay())
    }

    // MARK: - 关联状态

    /// 刷新当前曲目的关联状态。trackKey 为 nil 表示无可关联的当前曲目。
    /// trackEpoch 用于把关联结果安全地交给同步协调器（过期结果被其丢弃）。
    /// 按命名空间化 trackKey 查询。
    /// 切歌过渡：换曲目且上一状态有可展示文档时进入过渡态
    /// （旧内容保留置灰显示，不闪空白/加载态）；同曲目刷新保留当前内容
    /// 直到结果到达。查询结果只在本序列有效（防旧覆盖新）。
    func refresh(trackKey: String?, trackEpoch: Int) async {
        sequence += 1
        let currentSequence = sequence
        cancelManualResume()
        if displayedTrackKey != trackKey || requestedTrackEpoch != trackEpoch {
            browseMode = isAutoScrollSuspended ? .manual : .follow
            scrollRequest = nil
            scrollableLineIds = []
        }
        requestedTrackEpoch = trackEpoch
        let decision = LyricsPanelTransition.decide(
            previousTrackKey: displayedTrackKey,
            displayedContent: currentRetainedContent,
            newTrackKey: trackKey
        )
        guard let trackKey else {
            state = .noTrack
            displayedTrackKey = nil
            displayedTrackEpoch = nil
            return
        }
        guard let service else {
            state = .unavailable("本地歌词库不可用，无法读写歌词。")
            return
        }
        switch decision {
        case let .retainAndLoad(content):
            state = .transitioning(
                retained: content.document,
                retainedUntimedOnly: content.isUntimedOnly
            )
        case let .loadDirectly(keepCurrentWhileLoading):
            if !keepCurrentWhileLoading {
                state = .loading
            }
        }
        do {
            let resolved = try await service.associationState(forTrackKey: trackKey)
            guard currentSequence == sequence else { return }
            applyAssociationResult(resolved, trackKey: trackKey, trackEpoch: trackEpoch)
        } catch {
            guard currentSequence == sequence else { return }
            state = .unavailable(ErrorText.describe(error))
            displayedTrackKey = trackKey
        }
    }

    /// 应用一条有效的关联查询结果（调用方已做过期校验）。
    private func applyAssociationResult(
        _ resolved: LyricsAssociationState,
        trackKey: String,
        trackEpoch: Int
    ) {
        let previousDocumentId = currentDocumentId
        displayedTrackEpoch = trackEpoch
        switch resolved {
        case .unbound:
            scrollableLineIds = []
            state = .unbound
            displayedTrackKey = trackKey
            coordinator?.applyLyrics(
                trackKey: trackKey, trackEpoch: trackEpoch, document: nil, userDelayMs: 0
            )
        case let .untimedOnly(document):
            scrollableLineIds = []
            state = .untimedOnly(document: document)
            displayedTrackKey = trackKey
            // 全未打轴：协调器归一为「无同步内容」，面板负责静态展示。
            coordinator?.applyLyrics(
                trackKey: trackKey, trackEpoch: trackEpoch, document: document,
                userDelayMs: 0
            )
        case let .available(document, binding):
            scrollableLineIds = Set(document.lines.map(\.id))
            state = .ready(document: document)
            displayedTrackKey = trackKey
            coordinator?.applyLyrics(
                trackKey: trackKey, trackEpoch: trackEpoch, document: document,
                userDelayMs: binding.userDelayMs
            )
        }
        if currentDocumentId != previousDocumentId, !isAutoScrollSuspended {
            browseMode = .follow
            reanchorIfFollowing()
        } else if browseMode == .manual {
            scheduleManualResume()
        }
    }

    /// 解除当前曲目的关联（文档保留）。解除后回到可导入空态。
    func unlink(trackKey: String, trackEpoch: Int) async {
        sequence += 1
        let currentSequence = sequence
        guard let service else { return }
        do {
            try await service.deleteBinding(forTrackKey: trackKey)
        } catch {
            guard currentSequence == sequence else { return }
            state = .unavailable(ErrorText.describe(error))
            return
        }
        guard currentSequence == sequence else { return }
        await refresh(trackKey: trackKey, trackEpoch: trackEpoch)
    }

    // MARK: - 同步显示

    /// 编辑/导入期间取消延时与定位；关闭后重新给予完整阅读等待时间。
    func setAutoScrollSuspended(_ suspended: Bool) {
        guard isAutoScrollSuspended != suspended else { return }
        isAutoScrollSuspended = suspended
        cancelManualResume()
        scrollRequest = nil
        if suspended {
            browseMode = .manual
        } else if browseMode == .manual {
            scheduleManualResume()
        }
    }

    /// 每个实际歌词视图单独登记，切换紧凑布局时旧视图消失不会注销新视图。
    func lyricsAreaAppeared(_ id: UUID) {
        visibleAreas.insert(id)
        if browseMode == .manual { scheduleManualResume() }
        reanchorIfFollowing()
    }

    func lyricsAreaDisappeared(_ id: UUID) {
        visibleAreas.remove(id)
        activeGestures.remove(id)
        if visibleAreas.isEmpty {
            cancelManualResume()
        } else if browseMode == .manual {
            scheduleManualResume()
        }
    }

    func setManualInteractionActive(_ active: Bool, in areaId: UUID) {
        if active { activeGestures.insert(areaId) } else { activeGestures.remove(areaId) }
        enterManualBrowsing()
    }

    /// 协调器的显示状态变化回调入口（AppModel 桥接主线程后调用）。
    /// 仅当前组变化时才产生新的滚动定位请求；编辑器打开期间全部挂起。
    /// 过渡期间显示的是旧曲目文档，不按新曲目的当前组滚动。
    func apply(display: PlaybackLyricsDisplay) {
        let previous = syncDisplay
        syncDisplay = display
        guard !isAutoScrollSuspended else { return }
        guard !isTransitioning else { return }
        let previousAnchor = scrollAnchor(for: previous)
        if let anchor = scrollAnchor(for: display),
           anchor != previousAnchor || display.waitingInterval != previous.waitingInterval {
            requestScroll(to: anchor)
        }
    }

    // MARK: - 切歌过渡

    /// 是否处于切歌过渡态（旧内容置灰展示 + 提示条）。
    var isTransitioning: Bool {
        if case .transitioning = state { return true }
        return false
    }

    /// 当前状态可保留展示的内容（过渡决策输入；transitioning 保留其旧文档）。
    private var currentRetainedContent: LyricsPanelTransition.RetainedContent? {
        switch state {
        case let .ready(document):
            return .timed(document: document)
        case let .untimedOnly(document):
            return .untimed(document: document)
        case let .transitioning(retained, retainedUntimedOnly):
            return retainedUntimedOnly
                ? .untimed(document: retained)
                : .timed(document: retained)
        case .unavailable, .noTrack, .loading, .unbound:
            return nil
        }
    }

    /// 内容变化动画键（视图淡入用）：文档集合变化时改变，纯组内高亮变化不改变。
    /// 值类型字符串便于 SwiftUI `.animation(value:)` 直接观察。
    var contentChangeKey: String {
        switch state {
        case let .ready(document):
            return "ready:\(document.id):\(document.revision)"
        case let .untimedOnly(document):
            return "untimed:\(document.id):\(document.revision)"
        case let .transitioning(retained, _):
            return "transitioning:\(retained.id)"
        case .unavailable:
            return "unavailable"
        case .noTrack:
            return "noTrack"
        case .loading:
            return "loading"
        case .unbound:
            return "unbound"
        }
    }

    /// 滚轮、惯性、滚动条拖动与文本选择都延长手动阅读时间。
    func enterManualBrowsing() {
        guard !isTransitioning, !isAutoScrollSuspended else { return }
        if browseMode != .manual { browseMode = .manual }
        scrollRequest = nil
        scheduleManualResume()
    }

    /// 恢复跟随并立即定位当前组；编辑期间不抢焦点。
    func resumeFollowing() {
        guard !isAutoScrollSuspended, !isTransitioning else { return }
        cancelManualResume()
        browseMode = .follow
        reanchorIfFollowing()
    }

    /// 窗口尺寸变化：仅在 FOLLOW 下重新定位；MANUAL 不打扰阅读。
    func reanchorIfFollowing() {
        guard browseMode == .follow else { return }
        if let anchor = scrollAnchor(for: syncDisplay) {
            requestScroll(to: anchor)
        }
    }

    private func scrollAnchor(for display: PlaybackLyricsDisplay) -> UUID? {
        if let waiting = display.waitingInterval {
            return waiting.anchorLineId ?? waiting.nextLineId
        }
        return display.currentLineIds?.first
    }

    /// 偏移调整（正数延后 / 负数提前，0.1 秒步进）。
    /// 立即按新偏移重算当前组；持久化由协调器异步完成（失败经 AppModel 提示）。
    func adjustDelay(byMs deltaMs: Int64) {
        guard canAdjustDelay, let coordinator else { return }
        _ = coordinator.setDelay(syncDisplay.userDelayMs + deltaMs)
    }

    /// 偏移归零。
    func resetDelay() {
        guard let coordinator else { return }
        _ = coordinator.setDelay(0)
    }

    /// 偏移控制是否可用：仅在「已关联且有打轴行」时提供。
    var canAdjustDelay: Bool {
        guard case .ready = state else { return false }
        return coordinator != nil
    }

    /// 点击歌词行 → 应请求的播放位置（毫秒；引擎已按 [0,duration] 裁剪）。
    /// 无歌词/未知行/未打轴行返回 nil，调用方不发起跳转。
    func seekPosition(forLineId id: UUID) -> Int64? {
        coordinator?.seekPositionMs(forLineId: id)
    }

    /// 当前展示的歌词文档 id（ready / untimedOnly 状态下非空）。
    /// 编辑器打开入口使用（编辑对象在打开时固定为该文档）。
    /// 过渡期间为 nil：置灰展示的旧文档不作为编辑/解除关联目标。
    var currentDocumentId: UUID? {
        switch state {
        case let .ready(document):
            return document.id
        case let .untimedOnly(document):
            return document.id
        case .unavailable, .noTrack, .loading, .unbound, .transitioning:
            return nil
        }
    }

    /// 前台恢复（scenePhase → active）：立即按最近权威快照重算。
    /// 协调器从不用计时器累加，重算即从真实位置重新出发。
    func refreshSyncFromForeground() {
        coordinator?.refresh()
    }

    private func requestScroll(to lineId: UUID) {
        guard browseMode == .follow, !isAutoScrollSuspended, !isTransitioning,
              scrollableLineIds.contains(lineId) else { return }
        scrollRequest = ScrollAnchorRequest(requestId: UUID(), lineId: lineId)
    }

    private func cancelManualResume() {
        manualResumeGeneration += 1
        manualResumeTask?.cancel()
        manualResumeTask = nil
    }

    private func scheduleManualResume() {
        cancelManualResume()
        guard !visibleAreas.isEmpty, activeGestures.isEmpty, !isAutoScrollSuspended, !isTransitioning,
              browseMode == .manual, currentDocumentId != nil else { return }
        let generation = manualResumeGeneration
        let delay = manualResumeDelay
        manualResumeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.manualResumeGeneration == generation,
                  !self.visibleAreas.isEmpty else { return }
            self.resumeFollowing()
        }
    }

    deinit { manualResumeTask?.cancel() }
}
