import AppKit
import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices
import ShinLyricsProvider
import ShinMusicScript

/// 界面状态机：通过 Music 脚本适配器获取播放状态。
/// loading → ready；自动化权限被拒时进入 automationDenied
/// （由快照 errorCode 驱动，用户显式打开系统设置后可恢复）。
/// TCC「自动化」授权由系统在
/// 首次访问「音乐」App 时弹出，拒绝与否经快照/命令错误如实呈现。
@MainActor
final class AppModel: ObservableObject {
    /// 稳定错误码（ShinMusicScript 执行器层约定）。
    static let permissionDeniedCode = "music:permissionDenied"

    let isMock: Bool
    let controller: PlaybackController
    /// 官方音乐资料库与本机歌词库独立；首次打开浏览页时再加载。
    lazy var musicLibraryBrowser = MusicLibraryBrowserModel(service: controller as? MusicLibraryBrowsing)
    lazy var playbackOptions: PlaybackOptionsModel = {
        let service: PlaybackOptionsControlling = isMock
            ? MockPlaybackOptionsController() : MusicScriptPlaybackOptionsService()
        return PlaybackOptionsModel(service: service)
    }()
    /// 目录搜索服务仅 Mock 模式提供：真实模式播放来自「音乐」App 本身，
    /// 不提供官方目录搜索。
    private let searchService: CatalogSearchService?

    @Published private(set) var setup: SetupState = .loading
    @Published private(set) var snapshot: PlaybackSnapshot = PlaybackSnapshot()
    /// 松手后的展示目标；不写入权威快照或歌词时钟。
    @Published private(set) var pendingSeek: SeekPresentation?
    /// 展示层插值时钟：最近有效样本 + 单调差估计，
    /// 仅驱动进度条/时间标签的 TimelineView；权威时间仍是快照位置。
    /// 不需要 @Published：TimelineView 每个 tick 重新读取最新值。
    private(set) var playbackClock = InterpolatedPlaybackClock()
    /// 封面仓库：persistent ID 缓存 + 切歌后台取图；nil 走渐变占位。
    let artworkStore = ArtworkStore()
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var results: [SongSummary] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchMessage: String?
    /// 最近一次成功搜索是否「零结果」（区别于搜索失败/尚未搜索；供列表空态区分文案）。
    @Published private(set) var lastSearchHadNoResults = false
    /// 用户明确选定、正在装载/播放的曲目（“点过什么”只是请求，快照才是结果）。
    @Published private(set) var selectedSong: SongSummary?
    /// 播放侧一次性状态消息。setter 为 internal：保存位置切换扩展
    /// 重建协调器时写入偏移保存失败的提示。
    @Published var playbackMessage: String?

    // MARK: 歌词面板与导入/同步协调/编辑器

    /// 歌词面板状态（nil = 歌词库尚未初始化完成）。
    /// setter 为 internal：保存位置切换扩展（AppModel+LyricsStorage.swift）
    /// 重建服务全家时写入。
    @Published var lyricsPanel: LyricsPanelModel?
    /// 导入流程（nil = 歌词库初始化失败，导入不可用）。
    @Published var importFlow: ImportFlowModel?
    /// 歌词编辑器（nil = 歌词库初始化失败，编辑不可用）。
    @Published var lyricsEditor: LyricsEditorModel?
    /// 本地歌词库管理（nil = 歌词库初始化失败，管理不可用）。
    @Published var library: LyricsLibraryModel?
    /// 歌单自动获取（nil = 歌词库初始化失败）。
    @Published var autoFetch: AutoFetchModel?
    /// 本地歌词库页呈现开关。
    @Published var isLibraryPresented = false
    /// 播放-歌词同步协调器（nil = 歌词库初始化失败）。宿主持有，面板弱关联。
    var lyricsCoordinator: PlaybackLyricsCoordinator?
    /// 当前歌词库连接与所在目录（保存位置切换的基准；nil = 初始化失败）。
    var lyricsStore: GRDBLyricsStore?
    var lyricsDatabaseDirectory: URL?
    /// 保存位置切换进行中（守卫：切换期间不接受再次切换）。
    @Published var isSwitchingStorage = false
    /// 最近一次保存位置切换的结果说明（设置页展示；nil = 无待展示结果）。
    @Published var storageSwitchMessage: String?
    /// 歌词库位置说明（或初始化失败信息），展示于歌词区底部。
    @Published var lyricsDatabaseNote = "歌词库初始化中……"
    /// 导入窗口呈现开关。
    @Published var isImportPresented = false {
        didSet { updateLyricsScrollSuspension() }
    }
    /// 歌词编辑器呈现开关。
    @Published var isLyricsEditorPresented = false {
        didSet { updateLyricsScrollSuspension() }
    }
    /// 上一次驱动歌词面板刷新的曲目键与 epoch（切歌/重新装载时才刷新）。
    private var lastLyricsTrackKey: String?
    private var lastLyricsEpoch: Int?

    /// 目录搜索是否可用（Mock 模式）；真实模式隐藏搜索区并给出指引。
    var isSearchAvailable: Bool { searchService != nil }

    private var subscription: PlaybackSubscriptionHandle?
    /// WindowGroup 共用模型：窗口重建/切换播放器布局不重复订阅或初始化。
    private var startupTask: Task<Void, Never>?
    private let makeLyricsDatabase: @MainActor () async throws -> LyricsDatabase.Database
    private var seekSequence = 0
    private var searchTask: Task<Void, Never>?
    /// 请求序号：丢弃过期的搜索响应。
    private var searchSequence = 0
    private var debounceTask: Task<Void, Never>?

    // MARK: - 构造

    init(
        isMock: Bool,
        controller: PlaybackController,
        searchService: CatalogSearchService?,
        makeLyricsDatabase: (@MainActor () async throws -> LyricsDatabase.Database)? = nil
    ) {
        self.isMock = isMock
        self.controller = controller
        self.searchService = searchService
        self.makeLyricsDatabase = makeLyricsDatabase ?? { try await LyricsDatabase.makeStore(isMock: isMock) }
    }

    deinit {
        subscription?.cancel()
        startupTask?.cancel()
        searchTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - 启动与权限

    // 错误呈现与重试规则（适用于本类型全部失败路径）：
    // - **无自动重试循环**：搜索、播放、歌词查询失败后停留在带中文说明的
    //   静态错误态；只有用户显式操作（重新输入关键词、点「重试」、点
    //   「打开自动化权限设置」、再点一次播放）才会发起新请求；
    // - **错误一次性消费**：searchMessage / playbackMessage / 面板 unavailable
    //   都是普通状态位，由下一次用户动作覆盖或清空；本 App 不使用
    //   .alert(isPresented:) 弹窗，因此不存在「同一错误反复弹窗」的路径；
    // - **旧请求不覆盖新状态**：搜索用 searchSequence 序号、歌词关联用
    //   LyricsPanelModel.sequence、导入用 generation、同步结果由协调器按
    //   (trackKey, trackEpoch) 双重校验丢弃过期返回（详见各自文件）。

    func start() async {
        if startupTask == nil {
            // 独立任务不随某个窗口的 .task 取消；其他窗口等待同一初始化结果。
            startupTask = Task { [weak self] in
                guard let self else { return }
                self.subscription = self.controller.subscribe { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        // 回调跨入主线程时读取最新权威状态，避免排队中的旧采样倒灌。
                        self.applySnapshot(self.controller.snapshot())
                    }
                }
                // subscribe 不承诺回放初值；已暂停的歌曲也必须立即显示。
                self.applySnapshot(self.controller.snapshot())
                await self.setupLyricsServices()
                if self.setup == .loading { self.setup = .ready }
                // 歌单自动获取：就绪后跑一轮快照 diff（未启用则无操作）。
                await self.autoFetch?.refreshNow()
            }
        }
        await startupTask?.value
    }

    private func applySnapshot(_ snapshot: PlaybackSnapshot) {
        if let pendingSeek, !pendingSeek.matches(snapshot) || !Self.canSeek(snapshot, isMock: isMock) {
            self.pendingSeek = nil
            seekSequence += 1
        }
        self.snapshot = snapshot
        playbackClock.apply(sample: Self.playbackSample(snapshot))
        artworkStore.handleTrackChange(snapshot, controller: controller)
        applyAutomationState(snapshot: snapshot)
        lyricsCoordinator?.update(snapshot: snapshot)
        handleLyricsTrackChange(snapshot)
    }

    /// 快照驱动的自动化权限状态（仅真实模式）。
    /// 被拒 → automationDenied；恢复无错误快照（用户重新授权后）→ ready。
    private func applyAutomationState(snapshot: PlaybackSnapshot) {
        guard !isMock else { return }
        if snapshot.errorCode == Self.permissionDeniedCode {
            setup = .automationDenied
        } else if snapshot.errorCode == nil, case .automationDenied = setup {
            setup = .ready
        }
    }

    // MARK: - 搜索（防抖 + 序号防旧覆盖新；仅 Mock 模式）

    private func scheduleSearch() {
        guard searchService != nil else { return }
        debounceTask?.cancel()
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchSequence += 1
            results = []
            searchMessage = nil
            lastSearchHadNoResults = false
            isSearching = false
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms 防抖
            guard !Task.isCancelled else { return }
            await self?.runSearch(query: query)
        }
    }

    private func runSearch(query: String) async {
        guard let searchService else { return }
        searchSequence += 1
        let sequence = searchSequence
        isSearching = true
        searchMessage = nil
        lastSearchHadNoResults = false
        defer {
            if sequence == searchSequence {
                isSearching = false
            }
        }
        do {
            let found = try await searchService.searchSongs(term: query, limit: 25)
            // 旧响应不得覆盖新结果。
            guard sequence == searchSequence, !Task.isCancelled else { return }
            results = found
            lastSearchHadNoResults = found.isEmpty
            if found.isEmpty {
                searchMessage = "没有找到相关歌曲。"
            }
        } catch let error as CatalogSearchError {
            guard sequence == searchSequence else { return }
            if case .emptyTerm = error {
                results = []
            } else {
                searchMessage = searchErrorText(error)
            }
        } catch is CancellationError {
        } catch {
            guard sequence == searchSequence else { return }
            searchMessage = "搜索失败：\(String(describing: error))"
        }
    }

    // MARK: - 播放控制

    /// 点击结果行（仅 Mock 模式）：装载队列并播放（同一份结果作为队列）。
    func play(_ summary: SongSummary) {
        guard searchService != nil else { return }
        selectedSong = summary
        playbackMessage = nil
        let identities = results.map(\.identity)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.controller.setQueue(identities, startAt: summary.identity)
            } catch let error as PlaybackError {
                self.handlePlaybackError(error)
            } catch {
                self.playbackMessage = "播放失败：\(String(describing: error))"
            }
        }
    }

    func togglePlayPause() {
        Task { [weak self] in
            guard let self else { return }
            let status = self.controller.snapshot().status
            do {
                if status == .playing {
                    try await self.controller.pause()
                } else {
                    try await self.controller.play()
                }
            } catch let error as PlaybackError {
                self.handlePlaybackError(error)
            } catch {
                self.playbackMessage = "操作失败：\(String(describing: error))"
            }
        }
    }

    func seek(toMs ms: Int64, expectedSnapshot: PlaybackSnapshot? = nil) {
        let expected = expectedSnapshot ?? snapshot
        let current = controller.snapshot()
        guard isCurrentTrack(expected), Self.canSeek(current, isMock: isMock) else { return }
        seekSequence += 1
        let sequence = seekSequence
        let target = min(max(ms, 0), max(current.durationMs ?? ms, 0))
        pendingSeek = SeekPresentation(sequence: sequence, positionMs: target, expected: expected)
        playbackMessage = nil
        Task { [weak self] in
            guard let self else { return }
            defer { if self.pendingSeek?.sequence == sequence { self.pendingSeek = nil } }
            guard sequence == self.seekSequence, self.isCurrentTrack(expected),
                  Self.canSeek(self.controller.snapshot(), isMock: self.isMock) else { return }
            let beforeCommand = self.controller.snapshot()
            do {
                try await self.controller.seek(positionMs: target)
                guard sequence == self.seekSequence, self.isCurrentTrack(expected) else { return }
                let confirmed = self.controller.snapshot()
                guard confirmed.seq > beforeCommand.seq || (self.isMock && confirmed.seq == 0) else {
                    self.playbackMessage = "跳转后尚未读到新的播放位置。"
                    return
                }
                self.applySnapshot(confirmed)
                self.resumeLyricsAfterSeek(confirmed)
            } catch let error as PlaybackError {
                guard sequence == self.seekSequence, self.isCurrentTrack(expected) else { return }
                self.handlePlaybackError(error)
            } catch {
                guard sequence == self.seekSequence, self.isCurrentTrack(expected) else { return }
                self.playbackMessage = "跳转失败：\(String(describing: error))"
            }
        }
    }

    func playNext() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.controller.next()
            } catch let error as PlaybackError {
                self.handlePlaybackError(error)
            } catch {
                self.playbackMessage = "切歌失败：\(String(describing: error))"
            }
        }
    }

    func playPrevious() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.controller.previous()
            } catch let error as PlaybackError {
                self.handlePlaybackError(error)
            } catch {
                self.playbackMessage = "切歌失败：\(String(describing: error))"
            }
        }
    }

    // 会话过期处理（切歌/播放路径）：自动化权限被拒会把状态机拉回
    // automationDenied，由状态区呈现「打开自动化权限设置」按钮（用户显式
    // 触发）；绝不自动循环重新弹窗。曲目不可用与超时各自有区分文案。
    private func handlePlaybackError(_ error: PlaybackError) {
        switch error {
        case .unauthorized:
            setup = .automationDenied
        case .configurationMissing:
            setup = .failed("应用配置不可用")
        case .userCancelled:
            break
        case .musicNotRunning:
            playbackMessage = "「音乐」App 未运行：请打开音乐并选歌播放。"
        case .network:
            playbackMessage = "网络失败，请检查连接。"
        case .trackUnavailable:
            playbackMessage = "该曲目当前不可播放（可能需要订阅、已下架，或不在本机音乐库）。"
        case .initializationFailed(let reason):
            playbackMessage = "播放器初始化失败：\(reason)"
        case .unknown(let raw):
            playbackMessage = "播放失败：\(raw)"
        }
    }

    // MARK: - 歌词面板与导入

    /// 构建（一次性）本地歌词库与歌词服务。失败不假成功：面板显示不可用空态。
    /// （async：打开入口先做 best-effort 的升级前备份，见 LyricsDatabase.makeStore。）
    /// 服务全家的构建与保存位置切换的重建见 AppModel+LyricsStorage.swift。
    private func setupLyricsServices() async {
        guard lyricsPanel == nil else { return }
        do {
            let database = try await makeLyricsDatabase()
            lyricsStore = database.store
            lyricsDatabaseDirectory = database.directory
            installLyricsServiceGraph(store: database.store, note: database.locationDescription)
        } catch {
            lyricsStore = nil
            lyricsDatabaseDirectory = nil
            lyricsDatabaseNote = "本地歌词库初始化失败：\(ErrorText.describe(error))"
            // 面板仍可用：显示不可用空态（不假造可用状态）；无协调器。
            lyricsPanel = LyricsPanelModel(store: nil)
        }
        refreshLyricsPanel()
    }

    /// 切歌或重新装载（曲目键或 epoch 变化）时才刷新歌词面板；
    /// 播放时间变化不触发任何查询（时间同步由协调器按快照整查完成）。
    private func handleLyricsTrackChange(_ snapshot: PlaybackSnapshot) {
        guard snapshot.trackKey == lastLyricsTrackKey, snapshot.trackEpoch == lastLyricsEpoch else {
            lastLyricsTrackKey = snapshot.trackKey
            lastLyricsEpoch = snapshot.trackEpoch
            refreshLyricsPanel()
            return
        }
    }

    /// 保存位置切换后清除曲目缓存，强制当前歌曲从新库重新装载。
    /// internal：供 AppModel+LyricsStorage.swift 调用。
    func resetLyricsTrackCache() {
        lastLyricsTrackKey = nil
        lastLyricsEpoch = nil
    }

    /// 按当前曲目键刷新歌词面板（内部状态变化后的统一入口；
    /// 也是面板「加载失败 → 重试」空态的手动重试入口，见 ContentView/歌词区）。
    func refreshLyricsPanel() {
        let trackKey = currentTrackKey
        let epoch = snapshot.trackEpoch
        Task { [weak self] in
            guard let self, self.currentTrackKey == trackKey, self.snapshot.trackEpoch == epoch else { return }
            await self.lyricsPanel?.refresh(trackKey: trackKey, trackEpoch: epoch)
        }
    }

    /// 打开导入窗口：目标在打开时从当前曲目键固定（不随后续播放变化）。
    func beginImport() {
        guard let flow = importFlow, let trackKey = currentTrackKey else { return }
        let target = ImportSessionTarget(
            trackKey: trackKey,
            titleHint: snapshot.title ?? selectedSong?.title,
            artistHint: selectedSong?.artistName,
            durationHintMs: snapshot.durationMs ?? selectedSong?.durationMs
        )
        isImportPresented = true
        Task {
            await flow.openSession(target: target)
        }
    }

    // MARK: 在线歌词获取（编排在 AppModel+LyricsFetch.swift）

    /// 在线获取弹窗呈现开关。
    @Published var isLyricsFetchPresented = false
    /// 获取流程状态（nil = 未打开；目标在创建时固定）。
    /// setter 为 internal：获取扩展（AppModel+LyricsFetch.swift）装配弹窗时写入。
    @Published var lyricsFetchModel: NeteaseLyricsFetchModel?

    /// 能否发起在线获取（与导入同门槛：有明确曲目键且导入服务可用）。
    var canBeginOnlineFetch: Bool {
        importFlow != nil && currentTrackKey != nil
    }
}
/// 目录搜索错误的中文文案（AppModel 类型体外，约束类型长度）。
private func searchErrorText(_ error: CatalogSearchError) -> String {
    switch error {
    case .unauthorized:
        return "尚未授权 Apple Music 访问。"
    case .network(let detail):
        return "网络失败：\(detail)"
    case .rateLimited:
        return "请求过于频繁，请稍后再试。"
    case .trackUnavailable:
        return "目录暂不可用。"
    case .unknown(let detail):
        return "搜索失败：\(detail)"
    case .emptyTerm:
        return "请输入搜索关键词。"
    }
}
