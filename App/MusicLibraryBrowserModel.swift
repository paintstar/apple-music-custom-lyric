import Foundation
import ShinAppleKit

/// 官方「音乐」资料库的浏览目的地；与本机学习歌词库分开保存。
enum MusicLibraryDestination: Hashable, Sendable {
    case search, recent, artists, albums, songs
    case playlist(String)

    var source: MusicLibrarySource {
        if case let .playlist(id) = self { return .playlist(id: id) }
        return .library
    }

    var title: String {
        switch self {
        case .search: return "搜索"
        case .recent: return "最近添加"
        case .artists: return "艺人"
        case .albums: return "专辑"
        case .songs: return "歌曲"
        case .playlist: return "播放列表"
        }
    }

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .recent: return "clock"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .playlist: return "music.note.list"
        }
    }
}

struct MusicLibraryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [MusicLibraryTrack]
}

/// 首次同步自动读完分页，渐进展示；浏览、筛选和搜索不会发播放命令。
@MainActor
final class MusicLibraryBrowserModel: ObservableObject {
    @Published private(set) var playlists: [MusicLibraryPlaylist] = []
    @Published private(set) var destination: MusicLibraryDestination = .recent
    @Published private(set) var tracks: [MusicLibraryTrack] = []
    @Published private(set) var filteredTracks: [MusicLibraryTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPlayingRequest = false
    /// 已确认的播放上下文变更；同一首歌换列表时也应重新读取当前列表。
    @Published private(set) var confirmedPlaybackContextVersion = 0
    /// 用户刷新资料库时，让仍挂载的缺失封面重新尝试；不跟随播放采样更新。
    @Published private(set) var artworkRequestVersion = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackError: String?
    @Published private(set) var favoriteWrites: Set<String> = []
    @Published private(set) var totalCount = 0
    @Published private(set) var nextOffset: Int?
    @Published private(set) var playlistSort = MusicLibraryPlaylistSort()
    @Published var searchText = "" { didSet { if searchText != oldValue { scheduleFilter() } } }
    @Published var selectedGroupID: String?
    /// 视图移出树（完整/紧凑播放器）后仍保留稳定行定位与选择。
    @Published var selectedTrackID: String?
    var scrollOffsetY: Double = 0
    private(set) var scrollResetSequence = 0
    private let service: MusicLibraryBrowsing?
    private let sortPreferences: MusicLibraryPlaylistSortPreferences
    private var loadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var playlistTask: Task<Void, Never>?
    private var favoriteTasks: [String: Task<Void, Never>] = [:]
    private var loadSequence = 0
    private var filterSequence = 0
    private var playSequence = 0
    private var playlistSequence = 0
    private var didStart = false
    private var isTerminating = false
    private var cache: [MusicLibrarySource: CachedPage] = [:]
    /// 资料库分页参数，限制单次脚本和界面载入量；与曲目内容无关。
    static let pageSize = 200

    private struct CachedPage {
        var tracks: [MusicLibraryTrack]
        var total: Int
        var next: Int?
    }

    init(service: MusicLibraryBrowsing?, sortDefaults: UserDefaults = .standard) {
        self.service = service
        sortPreferences = MusicLibraryPlaylistSortPreferences(defaults: sortDefaults)
    }

    deinit {
        loadTask?.cancel(); filterTask?.cancel(); playTask?.cancel(); playlistTask?.cancel()
        favoriteTasks.values.forEach { $0.cancel() }
    }

    func cancelForTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        loadSequence += 1
        filterSequence += 1
        playSequence += 1
        playlistSequence += 1
        loadTask?.cancel()
        filterTask?.cancel()
        playTask?.cancel()
        playlistTask?.cancel()
        favoriteTasks.values.forEach { $0.cancel() }
        favoriteTasks.removeAll()
        isLoading = false
        isPlayingRequest = false
        favoriteWrites.removeAll()
    }

    var title: String {
        if let group = selectedGroup { return group.title }
        if case let .playlist(id) = destination {
            return playlists.first { $0.id == id }?.name ?? "播放列表"
        }
        return destination.title
    }

    var selectedGroup: MusicLibraryGroup? { grouped(tracks).first { $0.id == selectedGroupID } }
    var displayedTracks: [MusicLibraryTrack] {
        guard let selectedGroup else { return filteredTracks }
        let ids = Set(selectedGroup.tracks.map(\.id))
        return filteredTracks.filter { ids.contains($0.id) }
    }
    var hasMore: Bool { nextOffset != nil }
    var isAvailable: Bool { service != nil }
    var isPartial: Bool { tracks.count < totalCount }
    var isFolder: Bool {
        guard case let .playlist(id) = destination else { return false }
        return playlists.first { $0.id == id }?.isFolder == true
    }
    var childPlaylists: [MusicLibraryPlaylist] {
        guard case let .playlist(id) = destination else { return [] }
        return playlists.filter { $0.parentID == id }
    }
    var groups: [MusicLibraryGroup] { grouped(filteredTracks) }
    var browsingService: MusicLibraryBrowsing? { service }

    private func grouped(_ items: [MusicLibraryTrack]) -> [MusicLibraryGroup] {
        guard destination == .artists || destination == .albums else { return [] }
        let byArtist = destination == .artists
        let grouped = Dictionary(grouping: items) { track in
            if byArtist { return track.artist?.nonemptyLibraryText ?? "未知艺人" }
            let albumArtist = track.albumArtist?.nonemptyLibraryText ?? track.artist ?? ""
            return (track.album?.nonemptyLibraryText ?? "未知专辑") + "\u{1f}" + albumArtist
        }
        return grouped.map { key, values in
            MusicLibraryGroup(
                id: key,
                title: byArtist ? key : values.first?.album?.nonemptyLibraryText ?? "未知专辑",
                subtitle: byArtist ? "\(values.count) 首歌曲"
                    : values.first?.albumArtist?.nonemptyLibraryText ?? values.first?.artist?.nonemptyLibraryText ?? "未知艺人",
                tracks: values
            )
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func startIfNeeded() {
        guard !isTerminating, !didStart else { return }
        didStart = true
        reload()
    }

    func select(_ destination: MusicLibraryDestination) {
        guard !isTerminating, self.destination != destination else { return }
        let changedSource = self.destination.source != destination.source
        self.destination = destination
        if case let .playlist(id) = destination { playlistSort = sortPreferences.value(for: id) }
        playSequence += 1
        playTask?.cancel()
        isPlayingRequest = false
        selectedGroupID = nil
        selectedTrackID = nil
        scrollOffsetY = 0
        scrollResetSequence += 1
        searchText = ""
        playbackError = nil
        if changedSource {
            loadSequence += 1
            loadTask?.cancel()
            isLoading = false
            errorMessage = nil
            if let page = cache[destination.source] {
                apply(page)
                // 旧源的分页快照可能已被其他歌单替换，半页缓存必须从新快照续接。
                if page.next != nil { loadPage(reset: true, includePlaylists: false) }
            } else {
                tracks = []
                filteredTracks = []
                totalCount = 0
                nextOffset = nil
                loadPage(reset: true, includePlaylists: false)
            }
        } else {
            scheduleFilter()
        }
    }

    func reload() {
        guard !isTerminating else { return }
        artworkRequestVersion += 1
        loadPage(reset: true, includePlaylists: true)
    }
    func setPlaylistSort(_ sort: MusicLibraryPlaylistSort) {
        guard !isTerminating, case let .playlist(id) = destination, sort != playlistSort else { return }
        playlistSort = sort
        sortPreferences.save(sort, for: id)
        scheduleFilter()
    }
    func selectGroup(_ id: String?) {
        selectedGroupID = id
        selectedTrackID = nil
        scrollOffsetY = 0
        scrollResetSequence += 1
    }
    func loadMore() {
        guard nextOffset != nil, !isLoading else { return }
        loadPage(reset: true, includePlaylists: false)
    }

    func play(_ track: MusicLibraryTrack) {
        beginPlayback(track, shuffleEnabled: nil, playbackStarted: nil)
    }

    func playFromStart(shuffleEnabled: Bool, playbackStarted: (@MainActor () -> Void)? = nil) {
        let currentTracks = displayedTracks
        guard !isFolder, let start = currentTracks.first else { return }
        beginPlayback(start, shuffleEnabled: shuffleEnabled, playbackStarted: playbackStarted)
    }

    private func beginPlayback(_ track: MusicLibraryTrack, shuffleEnabled: Bool?, playbackStarted: (@MainActor () -> Void)?) {
        guard !isTerminating, let service else { return }
        let trackRefs = displayedTracks.map(\.trackRef)
        guard !isFolder, trackRefs.contains(track.trackRef) else { return }
        playSequence += 1
        let sequence = playSequence
        let source = destination.source
        playTask?.cancel()
        playbackError = nil
        isPlayingRequest = true
        playTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await service.prepareMusicInBackground()
                try Task.checkCancellation()
                if shuffleEnabled == true {
                    try await service.shuffleTracks(trackRefs, in: source)
                } else {
                    try await service.playTracks(trackRefs, startingAt: track.trackRef, in: source,
                                                 shuffleEnabled: shuffleEnabled)
                }
                try Task.checkCancellation()
                guard let self, sequence == self.playSequence else { return }
                self.isPlayingRequest = false
                self.confirmedPlaybackContextVersion += 1
                playbackStarted?()
            } catch {
                guard let self, sequence == self.playSequence else { return }
                self.isPlayingRequest = false
                if !(error is CancellationError) { self.playbackError = Self.message(for: error, playing: true) }
            }
        }
    }

    func setFavorite(_ track: MusicLibraryTrack, value: Bool) {
        guard !isTerminating, let service, !favoriteWrites.contains(track.trackRef) else { return }
        let trackRef = track.trackRef
        let source = destination.source
        favoriteWrites.insert(trackRef)
        playbackError = nil
        favoriteTasks[trackRef] = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let confirmed = try await service.setFavorite(trackRef, value: value, in: source)
                guard let self, !self.isTerminating, !Task.isCancelled else { return }
                self.updateFavorite(trackRef, value: confirmed)
                self.favoriteWrites.remove(trackRef)
                self.favoriteTasks[trackRef] = nil
                // Music 管理喜爱及智能歌单的成员，不能用本地标记推算或沿用旧成员缓存。
                self.invalidateFavoriteMembership(changedIn: source)
                if confirmed != value, self.tracks.contains(where: { $0.trackRef == trackRef }) {
                    self.playbackError = "喜爱标记未保存，请刷新资料库后重试。"
                }
            } catch {
                guard let self, !self.isTerminating, !Task.isCancelled else { return }
                self.favoriteWrites.remove(trackRef)
                self.favoriteTasks[trackRef] = nil
                if self.tracks.contains(where: { $0.trackRef == trackRef }) {
                    self.playbackError = "喜爱标记未保存，请刷新资料库后重试。"
                }
            }
        }
    }

    private func loadPage(reset: Bool, includePlaylists: Bool) {
        guard !isTerminating else { return }
        guard let service else {
            errorMessage = "当前播放源不提供资料库浏览。"
            return
        }
        loadSequence += 1
        let sequence = loadSequence
        let source = destination.source
        let initialOffset = reset ? 0 : nextOffset ?? 0
        let directorySequence = preparePlaylistRefresh(if: includePlaylists)
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await service.prepareMusicInBackground()
                try Task.checkCancellation()
                if includePlaylists {
                    let playlists = try await service.loadPlaylists()
                    guard let self, sequence == self.loadSequence else { return }
                    self.applyPlaylists(playlists, sequence: directorySequence)
                }
                guard let self, sequence == self.loadSequence else { return }
                if self.isFolder {
                    self.apply(CachedPage(tracks: [], total: 0, next: nil))
                    self.isLoading = false
                    return
                }
                try await self.collectPages(service: service, source: source, offset: initialOffset,
                                            reset: reset, sequence: sequence)
                guard sequence == self.loadSequence else { return }
                self.isLoading = false
            } catch {
                guard let self, sequence == self.loadSequence else { return }
                self.isLoading = false
                if !(error is CancellationError) { self.errorMessage = Self.message(for: error) }
            }
        }
    }

    private func collectPages(
        service: MusicLibraryBrowsing, source: MusicLibrarySource,
        offset initialOffset: Int, reset: Bool, sequence: Int
    ) async throws {
        var offset = initialOffset
        var accumulated = reset ? [] : tracks
        var seen = Set(accumulated.map(\.id))
        while true {
            let page = try await service.loadTracks(in: source, offset: offset, limit: Self.pageSize)
            try Task.checkCancellation()
            guard sequence == loadSequence, source == destination.source else { return }
            if let next = page.nextOffset, next <= offset { throw MusicLibraryError.contentsChanged }
            accumulated.append(contentsOf: page.tracks.filter { seen.insert($0.id).inserted })
            let cached = CachedPage(tracks: accumulated, total: page.totalCount, next: page.nextOffset)
            cache[source] = cached
            apply(cached)
            guard let next = page.nextOffset else { break }
            offset = next
        }
    }

    private func apply(_ page: CachedPage) {
        tracks = page.tracks
        totalCount = page.total
        nextOffset = page.next
        scheduleFilter()
    }

    private func scheduleFilter() {
        guard !isTerminating else { return }
        filterSequence += 1
        let sequence = filterSequence
        let tracks = tracks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = destination
        let playlistSort = playlistSort
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            // 快速分页和连续输入合并为一次过滤，避免每一页都重排整个资料库。
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                var filtered = tracks.filter { track in
                    let matchesQuery = query.isEmpty || [track.title, track.artist ?? "", track.album ?? ""]
                        .contains { $0.localizedStandardContains(query) }
                    return matchesQuery
                }
                if destination == .recent {
                    filtered.sort {
                        let left = $0.dateAdded ?? .distantPast
                        let right = $1.dateAdded ?? .distantPast
                        return left == right ? $0.id < $1.id : left > right
                    }
                } else if case .playlist = destination {
                    filtered = playlistSort.applying(to: filtered)
                }
                return filtered
            }.value
            guard let self, !Task.isCancelled, sequence == self.filterSequence else { return }
            self.filteredTracks = result
        }
    }

    /// 浏览页与当前播放列表共用固定错误说明，不透传系统或脚本原始文本。
    static func message(for error: Error, playing: Bool = false) -> String {
        if let error = error as? MusicPlaybackContextError { return error.localizedDescription }
        if let error = error as? MusicLibraryError { return error.localizedDescription }
        if let error = error as? PlaybackError {
            switch error {
            case .unauthorized: return "需要允许 ShinApple 控制「音乐」App。请在系统设置的自动化权限中允许后重试。"
            case .musicNotRunning: return "暂时无法启动「音乐」App，请打开一次音乐后重试。"
            case .trackUnavailable: return "这首歌曲目前无法播放，请刷新资料库后重试。"
            default: break
            }
        }
        // 不展示执行器的原始脚本/错误内容，以免泄露资料库字段。
        return playing ? "播放未成功，请检查「音乐」App 后重试。" : "资料库暂时无法读取，请检查「音乐」App 和自动化权限后重试。"
    }
}

extension MusicLibraryBrowserModel {
    func artworkData(for trackRef: String, in source: MusicLibrarySource? = nil) async -> Data? {
        guard !isTerminating, !Task.isCancelled, let service else { return nil }
        let data = try? await service.artworkData(for: trackRef, in: source ?? destination.source)
        guard !isTerminating, !Task.isCancelled else { return nil }
        return data
    }
}

private extension MusicLibraryBrowserModel {
    func updateFavorite(_ trackRef: String, value: Bool) {
        for key in Array(cache.keys) {
            guard var page = cache[key] else { continue }
            for index in page.tracks.indices where page.tracks[index].trackRef == trackRef {
                page.tracks[index].isFavorite = value
            }
            cache[key] = page
        }
        for index in tracks.indices where tracks[index].trackRef == trackRef {
            tracks[index].isFavorite = value
        }
        scheduleFilter()
    }

    func invalidateFavoriteMembership(changedIn source: MusicLibrarySource) {
        refreshPlaylists()
        for key in Array(cache.keys) {
            if case .playlist = key { cache[key] = nil }
        }
        // Music 可配置为把新喜爱的歌单曲目加入资料库，因此跨来源写入也使全库缓存失效。
        if source != .library { cache[.library] = nil }
        if case .playlist = destination.source {
            loadPage(reset: true, includePlaylists: false)
        } else if isLoading || source != .library {
            loadPage(reset: true, includePlaylists: false)
        }
        // 保留 selectedTrackID、搜索和滚动位置；实际成员仍由 Music 重新读取。
    }

    func preparePlaylistRefresh(if requested: Bool) -> Int {
        if requested {
            playlistSequence += 1
            playlistTask?.cancel()
        }
        return playlistSequence
    }

    func applyPlaylists(_ playlists: [MusicLibraryPlaylist], sequence: Int) {
        guard sequence == playlistSequence else { return }
        self.playlists = playlists
    }

    func refreshPlaylists() {
        guard !isTerminating, let service else { return }
        playlistSequence += 1
        let sequence = playlistSequence
        playlistTask?.cancel()
        playlistTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await service.prepareMusicInBackground()
                let playlists = try await service.loadPlaylists()
                guard let self, !self.isTerminating, !Task.isCancelled, sequence == self.playlistSequence else { return }
                self.playlists = playlists
            } catch {
                guard let self, !self.isTerminating, !Task.isCancelled, sequence == self.playlistSequence else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }
}

private extension String {
    var nonemptyLibraryText: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
