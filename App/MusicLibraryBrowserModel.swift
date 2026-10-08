import Foundation
import ShinAppleKit

/// 官方「音乐」资料库的浏览目的地；与本机学习歌词库分开保存。
enum MusicLibraryDestination: Hashable, Sendable {
    case search, recent, artists, albums, songs, favorites
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
        case .favorites: return "喜爱歌曲"
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
        case .favorites: return "star.fill"
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
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackError: String?
    @Published private(set) var favoriteWrites: Set<String> = []
    @Published private(set) var totalCount = 0
    @Published private(set) var nextOffset: Int?
    @Published var searchText = "" { didSet { if searchText != oldValue { scheduleFilter() } } }
    @Published var selectedGroupID: String?
    /// 视图移出树（完整/紧凑播放器）后仍保留稳定行定位与选择。
    @Published var selectedTrackID: String?
    var scrollOffsetY: Double = 0
    private(set) var scrollResetSequence = 0
    private let service: MusicLibraryBrowsing?
    private var loadTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var favoriteTasks: [String: Task<Void, Never>] = [:]
    private var loadSequence = 0
    private var filterSequence = 0
    private var playSequence = 0
    private var didStart = false
    private var cache: [MusicLibrarySource: CachedPage] = [:]
    /// 资料库分页参数，限制单次脚本和界面载入量；与曲目内容无关。
    static let pageSize = 200

    private struct CachedPage {
        var tracks: [MusicLibraryTrack]
        var total: Int
        var next: Int?
    }

    init(service: MusicLibraryBrowsing?) { self.service = service }

    deinit {
        loadTask?.cancel(); filterTask?.cancel(); playTask?.cancel()
        favoriteTasks.values.forEach { $0.cancel() }
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
    var lacksFavoriteMetadata: Bool {
        destination == .favorites && !tracks.isEmpty && tracks.allSatisfy { $0.isFavorite == nil }
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
        guard !didStart else { return }
        didStart = true
        reload()
    }

    func select(_ destination: MusicLibraryDestination) {
        guard self.destination != destination else { return }
        let changedSource = self.destination.source != destination.source
        self.destination = destination
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

    func reload() { loadPage(reset: true, includePlaylists: true) }
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
        beginPlayback(track, prepare: nil)
    }

    func playFromStart(shuffleEnabled: Bool, preparePlayback: @escaping @MainActor (Bool) async -> Bool) {
        let currentTracks = displayedTracks
        guard !isFolder, let start = shuffleEnabled ? currentTracks.randomElement() : currentTracks.first else { return }
        beginPlayback(start, prepare: { await preparePlayback(shuffleEnabled) })
    }

    private func beginPlayback(_ track: MusicLibraryTrack, prepare: (@MainActor () async -> Bool)?) {
        guard let service else { return }
        playSequence += 1
        let sequence = playSequence
        let source = destination.source
        playTask?.cancel()
        playbackError = nil
        isPlayingRequest = true
        playTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if let prepare {
                    let prepared = await prepare()
                    try Task.checkCancellation()
                    guard let self, sequence == self.playSequence else { return }
                    guard prepared else {
                        self.isPlayingRequest = false
                        self.playbackError = "播放方式未能更新，请检查「音乐」App 后重试。"
                        return
                    }
                }
                try await service.playTrack(track.trackRef, in: source)
                guard let self, sequence == self.playSequence else { return }
                self.isPlayingRequest = false
            } catch {
                guard let self, sequence == self.playSequence else { return }
                self.isPlayingRequest = false
                if !(error is CancellationError) { self.playbackError = Self.message(for: error, playing: true) }
            }
        }
    }

    func artworkData(for trackRef: String) async -> Data? {
        guard let service else { return nil }
        return try? await service.artworkData(for: trackRef)
    }

    func setFavorite(_ track: MusicLibraryTrack, value: Bool) {
        guard let service, !favoriteWrites.contains(track.trackRef) else { return }
        let trackRef = track.trackRef
        favoriteWrites.insert(trackRef)
        playbackError = nil
        favoriteTasks[trackRef] = Task { [weak self] in
            do {
                let confirmed = try await service.setFavorite(trackRef, value: value)
                guard let self else { return }
                self.updateFavorite(trackRef, value: confirmed)
                self.favoriteWrites.remove(trackRef)
                self.favoriteTasks[trackRef] = nil
                if self.isLoading { self.loadPage(reset: true, includePlaylists: false) }
            } catch {
                guard let self else { return }
                self.favoriteWrites.remove(trackRef)
                self.favoriteTasks[trackRef] = nil
                if self.tracks.contains(where: { $0.trackRef == trackRef }) {
                    self.playbackError = "喜爱标记未保存，请刷新资料库后重试。"
                }
            }
        }
    }

    private func updateFavorite(_ trackRef: String, value: Bool) {
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

    private func loadPage(reset: Bool, includePlaylists: Bool) {
        guard let service else {
            errorMessage = "当前播放源不提供资料库浏览。"
            return
        }
        loadSequence += 1
        let sequence = loadSequence
        let source = destination.source
        let initialOffset = reset ? 0 : nextOffset ?? 0
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            do {
                try await service.prepareMusicInBackground()
                try Task.checkCancellation()
                if includePlaylists {
                    let playlists = try await service.loadPlaylists()
                    guard let self, sequence == self.loadSequence else { return }
                    self.playlists = playlists
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
        filterSequence += 1
        let sequence = filterSequence
        let tracks = tracks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = destination
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            // 快速分页和连续输入合并为一次过滤，避免每一页都重排整个资料库。
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                var filtered = tracks.filter { track in
                    let matchesFavorite = destination != .favorites || track.isFavorite == true
                    let matchesQuery = query.isEmpty || [track.title, track.artist ?? "", track.album ?? ""]
                        .contains { $0.localizedStandardContains(query) }
                    return matchesFavorite && matchesQuery
                }
                if destination == .recent {
                    filtered.sort {
                        let left = $0.dateAdded ?? .distantPast
                        let right = $1.dateAdded ?? .distantPast
                        return left == right ? $0.id < $1.id : left > right
                    }
                }
                return filtered
            }.value
            guard let self, !Task.isCancelled, sequence == self.filterSequence else { return }
            self.filteredTracks = result
        }
    }

    private static func message(for error: Error, playing: Bool = false) -> String {
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

private extension String {
    var nonemptyLibraryText: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
