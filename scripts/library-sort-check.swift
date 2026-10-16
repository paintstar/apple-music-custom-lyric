import Combine
import Foundation
import ShinAppleKit

private enum CheckFailure: Error { case failed(String) }

private actor SortFixture: MusicLibraryBrowsing {
    let tracks: [MusicLibraryTrack]
    var played: [String] = []

    init(tracks: [MusicLibraryTrack]) { self.tracks = tracks }
    func prepareMusicInBackground() async throws {}
    func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        [MusicLibraryPlaylist(id: "A", name: "原创歌单"), MusicLibraryPlaylist(id: "B", name: "另一原创歌单")]
    }
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        MusicLibraryTrackPage(tracks: tracks, totalCount: tracks.count, nextOffset: nil)
    }
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {}
    func playTracks(_ trackRefs: [String], startingAt trackRef: String, in source: MusicLibrarySource,
                    shuffleEnabled: Bool?) async throws { played = trackRefs }
    func artworkData(for trackRef: String) async throws -> Data? { nil }
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool { value }
}

@main
private struct LibrarySortCheck {
    private static let tracks: [MusicLibraryTrack] = [
        MusicLibraryTrack(persistentID: "0000000000000001", title: "同名练习", dateAdded: Date(timeIntervalSince1970: 10)),
        MusicLibraryTrack(persistentID: "0000000000000002", title: "起航", artist: "纸船", album: "沿途",
                          durationMs: 120_000, dateAdded: Date(timeIntervalSince1970: 20)),
        MusicLibraryTrack(persistentID: "0000000000000003", title: "同名练习", artist: "远山", album: "远方",
                          durationMs: 180_000, dateAdded: Date(timeIntervalSince1970: 10)),
        MusicLibraryTrack(persistentID: "0000000000000004", title: "", artist: " ", album: ""),
        MusicLibraryTrack(persistentID: "0000000000000005", title: "风铃", artist: "纸船", album: "沿途",
                          durationMs: 120_000, dateAdded: Date(timeIntervalSince1970: 20))
    ]

    @MainActor static func main() async throws {
        try checkStableOrdering()
        let suite = "ShinApple.LibrarySortCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SortFixture(tracks: tracks)
        let model = MusicLibraryBrowserModel(service: service, sortDefaults: defaults)
        model.select(.playlist("A"))
        try await wait { model.displayedTracks.count == tracks.count && !model.isLoading }
        try require(model.displayedTracks == tracks, "默认保留歌单原始顺序")

        let recent = MusicLibraryPlaylistSort(field: .dateAdded, ascending: false)
        model.setPlaylistSort(recent)
        try await wait { model.displayedTracks.map(\.persistentID) == ids([2, 5, 1, 3, 4]) }
        model.searchText = "同名练习"
        try await wait { model.displayedTracks.map(\.persistentID) == ids([1, 3]) }
        model.searchText = ""
        try await wait { model.displayedTracks.count == tracks.count }
        model.play(tracks[2])
        try await wait { !model.isPlayingRequest }
        try require(await service.played == model.displayedTracks.map(\.trackRef), "播放传递完整显示顺序")

        model.select(.playlist("B"))
        try await wait { model.displayedTracks == tracks && !model.isLoading }
        let reversed = MusicLibraryPlaylistSort(field: .returnedOrder, ascending: false)
        model.setPlaylistSort(reversed)
        try await wait { model.displayedTracks == Array(tracks.reversed()) }
        model.select(.playlist("A"))
        try await wait { model.displayedTracks.map(\.persistentID) == ids([2, 5, 1, 3, 4]) }
        try require(model.playlistSort == recent, "每个歌单保留各自排序")

        let restored = MusicLibraryBrowserModel(service: service, sortDefaults: defaults)
        restored.select(.playlist("B"))
        try await wait { restored.displayedTracks == Array(tracks.reversed()) && !restored.isLoading }
        try require(restored.playlistSort == reversed, "重建模型恢复同一歌单偏好")
        restored.setPlaylistSort(MusicLibraryPlaylistSort())
        try await wait { restored.displayedTracks == tracks }
        let reloaded = MusicLibraryPlaylistSortPreferences(defaults: defaults)
        try require(reloaded.value(for: "B") == MusicLibraryPlaylistSort(), "恢复默认原始顺序")
        try require(reloaded.value(for: "A") == recent, "重设另一歌单不影响本歌单")
        let otherWindow = MusicLibraryPlaylistSortPreferences(defaults: defaults)
        reloaded.save(reversed, for: "C")
        otherWindow.save(recent, for: "D")
        try require(reloaded.value(for: "C") == reversed && reloaded.value(for: "D") == recent,
                    "多窗口保存合并最新偏好，不覆盖另一歌单")
        model.cancelForTermination()
        restored.cancelForTermination()
        print("歌单排序检查通过：原始/反向、稳定同值、未知末尾、搜索、播放顺序及逐歌单偏好。")
    }

    private static func checkStableOrdering() throws {
        for ascending in [true, false] {
            let date = MusicLibraryPlaylistSort(field: .dateAdded, ascending: ascending).applying(to: tracks)
            try require(date.map(\.persistentID) == ids(ascending ? [1, 3, 2, 5, 4] : [2, 5, 1, 3, 4]),
                        "时间同值保留返回顺序，未知始终末尾")
            for field: MusicLibraryPlaylistSort.Field in [.title, .artist, .album, .duration] {
                let sorted = MusicLibraryPlaylistSort(field: field, ascending: ascending).applying(to: tracks)
                try require(sorted.last?.persistentID == tracks[3].persistentID, "未知字段始终末尾")
                let tied = field == .title ? ids([1, 3]) : ids([2, 5])
                try require(sorted.map(\.persistentID).filter(tied.contains) == tied, "同值不倒转原始顺序")
            }
        }
        try require(MusicLibraryPlaylistSort(field: .returnedOrder, ascending: false).applying(to: tracks)
                    == Array(tracks.reversed()), "反向包含同名歌曲，不按名称去重")
    }

    private static func ids(_ values: [Int]) -> [String] { values.map { String(format: "%016X", $0) } }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CheckFailure.failed("等待排序模型超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
