import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices
import ShinLyricsProvider

// 歌单自动获取管线：
// - 刷新 = 快照 diff：新增成员入获取队列，移出成员走删除管线；
// - 获取队列串行执行（provider 内建限速）：高置信自动落位（auto-high 注记），
//   低置信进待确认队列；每步写审计；
// - 删除铁律：只删「自动落位 && 落位后未编辑 && 无人工翻译」的文档，
//   手动导入/用户确认获取/人工编辑过的永不自动删；
// - 停用、勾选变化和切换保存位置会立即使旧运行令牌失效。
//
// 触发点：启动就绪后、设置变更后、设置页「立即刷新」。
// Music 歌单没有变更通知，全部时机都是快照对比（拉当前成员 diff 上次）。

/// 事务线程也能同步检查失效状态；只保存运行有效性，不携带用户资料。
final class AutoFetchRun: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
    func check() throws {
        guard isValid else { throw CancellationError() }
    }
}

@MainActor
final class AutoFetchModel: ObservableObject {

    // MARK: 状态（设置页数据源）

    /// 设置状态（设置交互扩展 AutoFetchModel+Settings.swift 写入）。
    @Published var settings = AutoFetchSettings()
    /// 可勾选的歌单列表（刷新自 Music；文件夹与智能歌单如实列出并标注）。
    /// 可勾选歌单列表（设置交互扩展写入）。
    @Published var playlists: [MusicLibraryPlaylist] = []
    @Published private(set) var isRefreshing = false
    /// 最近一轮刷新摘要（设置交互扩展写入）。
    @Published var lastRunSummary: String?
    /// 待确认队列（设置交互扩展写入）。
    @Published var pendingItems: [PendingAutoFetchItem] = []
    /// 最近一轮审计摘要（设置页展开显示）。
    /// 最近审计摘要（设置交互扩展写入；展示最近 20 条）。
    @Published var recentAudit: [AutoFetchAuditEntry] = []
    /// 一次性操作反馈（保存设置失败等）；nil = 无。
    @Published var actionMessage: String?

    let store: GRDBLyricsStore
    /// 状态仓库（设置交互扩展共用）。
    let repository: AutoFetchStore
    /// 资料库浏览服务（设置交互扩展装载歌单列表共用）。
    let library: (any MusicLibraryBrowsing)?
    let fetchService: any LyricsFetchServicing
    private var currentRun: AutoFetchRun?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private(set) var isSuspended = false
    private(set) var stateRevision = 0
    /// 刷新面板回调（自动落位/删除后刷新歌词显示）。
    var onLibraryChanged: (() -> Void)?

    init(
        store: GRDBLyricsStore,
        library: (any MusicLibraryBrowsing)?,
        fetchService: any LyricsFetchServicing
    ) {
        self.store = store
        self.repository = AutoFetchStore(store: store)
        self.library = library
        self.fetchService = fetchService
    }


    // MARK: - 主刷新流程

    /// 一次扫描的全部中间产物。
    private struct MembershipScan {
        /// trackKey → 所属勾选歌单集合。
        var membershipByKey: [String: Set<String>] = [:]
        /// trackKey → 本轮看到的曲目信息（新增获取时的搜索基准）。
        var trackInfo: [String: MusicLibraryTrack] = [:]
        var addedKeys: Set<String> = []
        var removedKeys: Set<String> = []
        var failedPlaylists: [String] = []
        var snapshots: [PlaylistMembershipSnapshot] = []
        var work: [AutoFetchWorkItem] = []
    }

    /// 一轮新增处理的计数。
    private struct AdditionCounts {
        var imported = 0
        var pending = 0
        var failed = 0
        var skippedExisting = 0
    }

    /// 配置改变时同步失效，不能等待设置写盘或网络返回后才停止旧结果。
    func invalidateCurrentRun() {
        stateRevision &+= 1
        currentRun?.invalidate()
    }

    /// 切目录前停止新刷新，并等待旧任务及已排队事务结束，再复制数据库。
    func suspendAndWait() async throws {
        isSuspended = true
        refreshRequested = false
        invalidateCurrentRun()
        await refreshTask?.value
        try await store.waitForPendingWrites()
    }

    func resume() { isSuspended = false }

    /// 同时只运行一轮；配置变化要求的刷新在旧轮退出后执行。
    func refreshNow() async {
        guard !isSuspended else { return }
        if let refreshTask {
            refreshRequested = true
            await refreshTask.value
            return
        }
        isRefreshing = true
        let task = Task {
            defer {
                isRefreshing = false
                refreshTask = nil
                currentRun = nil
            }
            repeat {
                refreshRequested = false
                let run = AutoFetchRun()
                currentRun = run
                await withTaskCancellationHandler {
                    await performRefresh(run: run)
                } onCancel: {
                    run.invalidate()
                }
            } while refreshRequested && !isSuspended && !Task.isCancelled
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRefresh(run: AutoFetchRun) async {
        await reloadState()
        guard run.isValid else { return }
        let currentSettings = settings
        guard currentSettings.isEnabled, !currentSettings.playlistIDs.isEmpty else {
            lastRunSummary = currentSettings.isEnabled ? "尚未勾选任何播放列表。" : "自动获取未启用。"
            return
        }
        guard let library else {
            lastRunSummary = "当前播放连接不支持读取播放列表，本轮未执行。"
            return
        }
        do {
            let scan = try await scanMembership(settings: currentSettings, library: library, run: run)
            guard run.isValid else { return }
            // 先原子保存变化待办，再推进观察快照；中断或某项失败不会丢失其他成员的移出。
            try await repository.recordObservations(
                scan.snapshots, work: scan.work, activePlaylistIDs: currentSettings.playlistIDs,
                isValid: { run.isValid }
            )
            let work = try await repository.workItems()
            try run.check()
            // 一份歌单未知，就无法证明曲目已移出全部监控歌单；删除待办保留到恢复。
            let removal = scan.failedPlaylists.isEmpty
                ? try await processRemovals(scan: scan, work: work, run: run) : (deleted: 0, kept: 0)
            let additions = try await processAdditions(scan: scan, work: work, run: run)
            guard run.isValid else { return }
            await reloadState()
            guard run.isValid else { return }
            onLibraryChanged?()
            lastRunSummary = Self.summarize(scan: scan, removal: removal, additions: additions)
        } catch {
            guard run.isValid else { return }
            lastRunSummary = "本轮未完成，成员变化已保留，可再次刷新：\(ErrorText.describe(error))"
        }
    }

    /// 拉取全部勾选歌单成员并计算差异；这里只准备新基准，不提前写入。
    /// 单个歌单读取失败：保留其旧快照（不 diff），计入 failedPlaylists 下轮再试。
    private func scanMembership(
        settings: AutoFetchSettings,
        library: any MusicLibraryBrowsing,
        run: AutoFetchRun
    ) async throws -> MembershipScan {
        var scan = MembershipScan()
        let allPlaylists = (try? await library.loadPlaylists()) ?? []
        try run.check()
        var playlistNames: [String: String] = [:]
        for playlist in allPlaylists {
            playlistNames[playlist.id] = playlist.name
        }
        for playlistID in settings.playlistIDs {
            var members: [MusicLibraryTrack] = []
            do {
                var offset = 0
                while true {
                    let page = try await library.loadTracks(
                        in: .playlist(id: playlistID), offset: offset, limit: 200
                    )
                    try run.check()
                    members.append(contentsOf: page.tracks)
                    guard let next = page.nextOffset else { break }
                    offset = next
                }
            } catch {
                try run.check()
                scan.failedPlaylists.append(playlistNames[playlistID] ?? playlistID)
                continue
            }
            let memberKeys = members.map(\.trackRef)
            let previous = await repository.snapshot(playlistID: playlistID)
            try run.check()
            let diff = PlaylistMembershipDiffer.diff(
                previous: previous?.memberTrackKeys, current: memberKeys
            )
            scan.snapshots.append(PlaylistMembershipSnapshot(
                playlistID: playlistID,
                playlistName: playlistNames[playlistID],
                memberTrackKeys: memberKeys
            ))
            for key in memberKeys {
                scan.membershipByKey[key, default: []].insert(playlistID)
            }
            for track in members {
                scan.trackInfo[track.trackRef] = track
            }
            scan.addedKeys.formUnion(diff.added)
            scan.removedKeys.formUnion(diff.removed)
            scan.work += diff.added.map { AutoFetchWorkItem(kind: .fetch, trackKey: $0, playlistIDs: [playlistID]) }
            scan.work += diff.removed.map { AutoFetchWorkItem(kind: .remove, trackKey: $0, playlistIDs: [playlistID]) }
        }
        return scan
    }

    /// 删除管线：移出的歌若不再属于任何勾选歌单，按铁律清理。
    private func processRemovals(
        scan: MembershipScan, work: [AutoFetchWorkItem], run: AutoFetchRun
    ) async throws -> (deleted: Int, kept: Int) {
        var deleted = 0
        var kept = 0
        for item in work.filter({ $0.kind == .remove }).sorted(by: { $0.trackKey < $1.trackKey }) {
            try run.check()
            if scan.membershipByKey[item.trackKey] == nil {
                let track = scan.trackInfo[item.trackKey]
                switch try await removeIfAutoFetched(trackKey: item.trackKey, title: track?.title, run: run) {
                case .deleted: deleted += 1
                case .kept: kept += 1
                case .noLyrics: break
                }
            }
            try await repository.completeWork(item, isValid: { run.isValid })
        }
        return (deleted, kept)
    }

    /// 获取队列：新增成员逐首处理（串行；provider 限速；已有绑定不碰）。
    private func processAdditions(
        scan: MembershipScan,
        work: [AutoFetchWorkItem], run: AutoFetchRun
    ) async throws -> AdditionCounts {
        var counts = AdditionCounts()
        let ignored = await repository.ignoredTrackKeys()
        let pending = Set(await repository.pendingItems().map(\.trackKey))
        try run.check()
        for item in work.filter({ $0.kind == .fetch }).sorted(by: { $0.trackKey < $1.trackKey }) {
            try run.check()
            guard let track = scan.trackInfo[item.trackKey] else {
                if scan.failedPlaylists.isEmpty {
                    try await repository.completeWork(item, isValid: { run.isValid })
                }
                continue
            }
            let completed = try await processAddition(track: track, ignored: ignored, pending: pending,
                                                      counts: &counts, run: run)
            try run.check()
            if completed { try await repository.completeWork(item, isValid: { run.isValid }) }
        }
        return counts
    }

    private func processAddition(
        track: MusicLibraryTrack, ignored: Set<String>, pending: Set<String>,
        counts: inout AdditionCounts, run: AutoFetchRun
    ) async throws -> Bool {
        if ignored.contains(track.trackRef) || pending.contains(track.trackRef) { return true }
        if try await store.binding(forTrackKey: track.trackRef) != nil {
            counts.skippedExisting += 1
            return true
        }
        try run.check()
        switch await fetchAndImport(track: track, run: run) {
        case .imported: counts.imported += 1
        case .pending: counts.pending += 1
        case .failed:
            counts.failed += 1
            return false
        case .skipped: break
        }
        return true
    }

    /// 中文结果摘要（设置页一行呈现）。
    private static func summarize(
        scan: MembershipScan,
        removal: (deleted: Int, kept: Int),
        additions: AdditionCounts
    ) -> String {
        var parts: [String] = []
        parts.append("新增 \(scan.addedKeys.count) 首、移出 \(scan.removedKeys.count) 首。")
        if additions.imported > 0 { parts.append("自动获取 \(additions.imported) 首。") }
        if additions.pending > 0 { parts.append("\(additions.pending) 首待确认。") }
        if additions.failed > 0 { parts.append("\(additions.failed) 首获取失败。") }
        if additions.skippedExisting > 0 {
            parts.append("\(additions.skippedExisting) 首已有歌词跳过。")
        }
        if removal.deleted > 0 { parts.append("自动清理 \(removal.deleted) 首。") }
        if removal.kept > 0 { parts.append("\(removal.kept) 首有手动内容保留。") }
        if !scan.failedPlaylists.isEmpty {
            parts.append("读取失败歌单：\(scan.failedPlaylists.joined(separator: "、"))；本轮暂缓清理，下次刷新重试。")
        }
        if parts.count == 1 { parts.append("勾选歌单无成员变化。") }
        return parts.joined(separator: " ")
    }

    // MARK: - 删除管线（铁律实现）

    enum RemovalOutcome {
        case deleted
        case kept
        case noLyrics
    }

    /// 移出歌单后的清理：仅当歌词是「自动落位 && 未编辑 && 无人工翻译」时删除；
    /// 其余一律保留并写审计说明原因。
    private func removeIfAutoFetched(
        trackKey: String, title: String?, run: AutoFetchRun
    ) async throws -> RemovalOutcome {
        let displayTitle = title ?? "未知曲目"
        guard let binding = try await store.binding(forTrackKey: trackKey)
        else { return .noLyrics }
        try run.check()
        guard let document = try await store.document(id: binding.lyricDocumentId)
        else { return .noLyrics }

        try run.check()
        let isUntouchedAutoDocument = document.isAutoFetched
            && document.isUneditedSinceFetch
            && !document.hasManualTranslation
        guard isUntouchedAutoDocument else {
            let reason: String
            if !document.hasFetchProvenance {
                reason = "手动导入"
            } else if document.fetchMatchKind == .userConfirmed {
                reason = "用户确认获取"
            } else if !document.isUneditedSinceFetch {
                reason = "获取后有人工编辑"
            } else {
                reason = "含人工翻译"
            }
            await repository.appendAudit(AutoFetchAuditEntry(
                action: .skipped,
                trackKey: trackKey,
                title: displayTitle,
                detail: "移出播放列表，但歌词为\(reason)成果，按规则保留"
            ), isValid: { run.isValid })
            return .kept
        }
        do {
            let deleted = try await store.deleteDocumentIfUnchanged(
                binding: binding, revision: document.revision, isValid: { run.isValid },
                shouldDelete: { $0.isAutoFetched && $0.isUneditedSinceFetch && !$0.hasManualTranslation }
            )
            try run.check()
            guard deleted else { return .kept }
            await repository.appendAudit(AutoFetchAuditEntry(
                action: .deleted,
                trackKey: trackKey,
                title: displayTitle,
                detail: "移出所有勾选播放列表，自动清理未编辑的自动歌词"
            ), isValid: { run.isValid })
            return .deleted
        } catch {
            try run.check()
            await repository.appendAudit(AutoFetchAuditEntry(
                action: .skipped,
                trackKey: trackKey,
                title: displayTitle,
                detail: "删除失败：\(ErrorText.describe(error))"
            ), isValid: { run.isValid })
            throw error
        }
    }

    // MARK: - 单曲获取（自动路径）

    enum FetchOutcome {
        case imported
        case pending
        case failed
        case skipped
    }

    // MARK: - 待确认处理（设置页操作）

    /// 用户处理完待确认项（确认导入或忽略）后调用。
    func resolvePending(trackKey: String) async {
        guard !isSuspended else { return }
        try? await repository.removePending(trackKey: trackKey)
        pendingItems = await repository.pendingItems()
    }

    /// 标记「此歌不再自动获取」并移出待确认队列。
    func ignorePending(_ item: PendingAutoFetchItem) async {
        guard !isSuspended else { return }
        invalidateCurrentRun()
        try? await repository.ignore(trackKey: item.trackKey)
        guard !isSuspended else { return }
        await resolvePending(trackKey: item.trackKey)
        actionMessage = "《\(item.title)》已标记为不再自动获取。"
    }
}
