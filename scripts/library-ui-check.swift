import Foundation
import ShinAppleKit

private enum CheckFailure: Error { case failed(String) }

/// 全部记录为原创虚构数据；延迟故意不响应取消，用于验证旧结果不会倒灌。
private actor LibraryFixture: MusicLibraryBrowsing {
    var failAfterFirstPage = false
    var prepareCount = 0
    var plays: [(String, MusicLibrarySource)] = []
    var delaySecondPage = false
    var libraryFirstPageReads = 0
    var favoriteWriteCount = 0
    let library: [MusicLibraryTrack] = (0..<447).map { (index: Int) -> MusicLibraryTrack in
        let identifier = String(format: "%016X", index + 1)
        let title = index == 446 ? "末页星光" : "练习歌曲\(index)"
        let artist = index.isMultiple(of: 2) ? "纸船乐队" : "远山合唱"
        return MusicLibraryTrack(persistentID: identifier, title: title, artist: artist,
                                 album: "原创练习集", durationMs: 180_000,
                                 isFavorite: index == 446,
                                 dateAdded: Date(timeIntervalSince1970: Double(index)))
    }

    func prepareMusicInBackground() async throws { prepareCount += 1 }
    func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        [MusicLibraryPlaylist(id: "A", name: "较慢歌单"),
         MusicLibraryPlaylist(id: "B", name: "当前歌单", parentID: "F"),
         MusicLibraryPlaylist(id: "F", name: "练习文件夹", isFolder: true)]
    }
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        switch source {
        case .library:
            if offset == 0 { libraryFirstPageReads += 1 }
            if delaySecondPage && offset == 200 { try? await Task.sleep(for: .milliseconds(220)) }
            if failAfterFirstPage && offset > 0 { throw MusicLibraryError.contentsChanged }
            let end = min(offset + limit, library.count)
            return MusicLibraryTrackPage(tracks: Array(library[offset..<end]), totalCount: library.count,
                                         nextOffset: end < library.count ? end : nil)
        case let .playlist(id):
            if id == "A" { try? await Task.sleep(for: .milliseconds(220)) }
            let track = MusicLibraryTrack(persistentID: id == "A" ? "AAAAAAAAAAAAAAAA" : "BBBBBBBBBBBBBBBB",
                                          title: id == "A" ? "旧歌单的句子" : "当前歌单的句子")
            return MusicLibraryTrackPage(tracks: [track], totalCount: 1, nextOffset: nil)
        }
    }
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws { plays.append((trackRef, source)) }
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool {
        favoriteWriteCount += 1
        try await Task.sleep(for: .milliseconds(40))
        return value
    }
    func setFailure(_ value: Bool) { failAfterFirstPage = value }
    func setDelayedPaging() { delaySecondPage = true }
}

@main
private struct LibraryUICheck {
    @MainActor static func main() async throws {
        let fixture = LibraryFixture()
        let model = MusicLibraryBrowserModel(service: fixture)
        model.startIfNeeded()
        model.startIfNeeded()
        try await wait { !model.isLoading && model.filteredTracks.count == 447 }
        try require(model.tracks.count == 447 && !model.hasMore, "自动读取所有分页")
        try require(await fixture.prepareCount == 1, "多次挂载仅初始化一次")
        try require(await fixture.plays.isEmpty, "浏览不能自动开始播放")
        try require(model.filteredTracks.first?.title == "末页星光", "最近添加按真实日期排序")

        model.select(.favorites)
        try await wait { model.filteredTracks.count == 1 }
        try require(model.filteredTracks.first?.title == "末页星光", "喜爱分类覆盖末页")
        model.select(.search)
        model.searchText = "不存在的旧搜索"
        model.searchText = "末页星光"
        try await wait { model.filteredTracks.count == 1 && model.filteredTracks.first?.title == "末页星光" }
        model.select(.artists)
        try await wait { model.filteredTracks.count == 447 }
        try require(model.groups.count == 2, "艺人按全部已同步记录分组")
        model.selectGroup("远山合唱")
        model.searchText = "末页星光"
        try await wait { model.filteredTracks.count == 1 }
        try require(model.displayedTracks.isEmpty && model.title == "远山合唱", "组内搜索不跳出当前艺人")

        model.select(.playlist("A"))
        try? await Task.sleep(for: .milliseconds(20))
        model.select(.playlist("B"))
        try await wait { !model.isLoading && model.filteredTracks.first?.title == "当前歌单的句子" }
        try? await Task.sleep(for: .milliseconds(300))
        try require(model.title == "当前歌单" && model.filteredTracks.first?.title == "当前歌单的句子", "迟到歌单不能覆盖当前页面")
        if let track = model.filteredTracks.first { model.play(track) }
        try await wait { !model.isPlayingRequest }
        let plays = await fixture.plays
        try require(plays.count == 1 && plays[0].1 == .playlist(id: "B"), "点歌保留原歌单上下文")
        model.select(.playlist("F"))
        try await wait { !model.isLoading }
        try require(model.isFolder && model.childPlaylists.count == 1 && model.tracks.isEmpty, "文件夹展示真实子歌单")
        model.select(.favorites)
        try await wait { model.filteredTracks.count == 1 }
        if let favorite = model.filteredTracks.first {
            model.setFavorite(favorite, value: false)
            model.setFavorite(favorite, value: false)
        }
        try await wait { model.favoriteWrites.isEmpty && model.filteredTracks.isEmpty }
        try require(await fixture.favoriteWriteCount == 1, "同曲目喜爱标记请求去重，读回后更新分类")

        let delayedFixture = LibraryFixture()
        await delayedFixture.setDelayedPaging()
        let resumed = MusicLibraryBrowserModel(service: delayedFixture)
        resumed.startIfNeeded()
        try await wait { resumed.tracks.count == 200 && resumed.isLoading }
        resumed.select(.playlist("B"))
        try await wait { !resumed.isLoading && resumed.tracks.count == 1 }
        resumed.select(.songs)
        try await wait { !resumed.isLoading && resumed.tracks.count == 447 }
        try require(await delayedFixture.libraryFirstPageReads == 2, "A→B→A半页缓存从新快照自动取齐")

        let failingFixture = LibraryFixture()
        await failingFixture.setFailure(true)
        let failing = MusicLibraryBrowserModel(service: failingFixture)
        failing.startIfNeeded()
        try await wait { !failing.isLoading && failing.errorMessage != nil }
        try require(failing.tracks.count == 200 && failing.errorMessage?.contains("变化") == true,
                    "读取中资料库变化保留已读记录并提示刷新")
        await failingFixture.setFailure(false)
        failing.reload()
        try await wait { !failing.isLoading && failing.tracks.count == 447 }
        try require(failing.errorMessage == nil, "刷新可恢复完整资料库")
        print("AUTOMATED_PASS: library pagination/search/grouping/stale responses/play context/folder/favorite/partial cache/recovery")
    }

    @MainActor private static func wait(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure.failed("等待状态超时")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}
