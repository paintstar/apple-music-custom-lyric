import Foundation
import Combine
import ShinAppleKit

private enum CheckFailure: Error { case failed(String) }

/// 全部记录为原创虚构数据；延迟故意不响应取消，用于验证旧结果不会倒灌。
private actor LibraryFixture: MusicLibraryBrowsing {
    var failAfterFirstPage = false
    var prepareCount = 0
    var plays: [(String, MusicLibrarySource)] = []
    var contextPlays: [([String], MusicLibrarySource, Bool?)] = []
    var shuffleRequests = 0
    var contextTracks: [MusicLibraryTrack] = []
    var contextFailure: (any Error)?
    var delayContextPlayback = false
    var delaySecondPage = false
    var libraryFirstPageReads = 0
    var favoriteWriteCount = 0
    var currentSource: MusicLibrarySource?
    var delayNextSourceRead = false
    let library: [MusicLibraryTrack]

    init(trackCount: Int = 447, favoriteCount: Int = 1) {
        library = (0..<trackCount).map { (index: Int) -> MusicLibraryTrack in
            let identifier = String(format: "%016X", index + 1)
            let title = index == trackCount - 1 ? "末页星光" : "练习歌曲\(index)"
            let artist = index.isMultiple(of: 2) ? "纸船乐队" : "远山合唱"
            return MusicLibraryTrack(persistentID: identifier, title: title, artist: artist,
                                     album: "原创练习集", durationMs: 180_000,
                                     isFavorite: index >= trackCount - favoriteCount,
                                     dateAdded: Date(timeIntervalSince1970: Double(index)))
        }
    }

    func prepareMusicInBackground() async throws { prepareCount += 1 }
    func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        [MusicLibraryPlaylist(id: "A", name: "较慢歌单"),
         MusicLibraryPlaylist(id: "B", name: "当前歌单", parentID: "F"),
         MusicLibraryPlaylist(id: "C", name: "ShinApple · 当前播放"),
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
            if id == "C" {
                let end = min(offset + limit, contextTracks.count)
                return MusicLibraryTrackPage(tracks: Array(contextTracks[offset..<end]), totalCount: contextTracks.count,
                                             nextOffset: end < contextTracks.count ? end : nil)
            }
            if id == "A" { try? await Task.sleep(for: .milliseconds(220)) }
            let track = MusicLibraryTrack(persistentID: id == "A" ? "AAAAAAAAAAAAAAAA" : "BBBBBBBBBBBBBBBB",
                                          title: id == "A" ? "旧歌单的句子" : "当前歌单的句子")
            return MusicLibraryTrackPage(tracks: [track], totalCount: 1, nextOffset: nil)
        }
    }
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {
        plays.append((trackRef, source))
        currentSource = source
    }
    func playTracks(_ trackRefs: [String], startingAt trackRef: String, in source: MusicLibrarySource,
                    shuffleEnabled: Bool?) async throws {
        contextPlays.append((trackRefs, source, shuffleEnabled))
        if let contextFailure { throw contextFailure }
        if delayContextPlayback { try? await Task.sleep(for: .milliseconds(220)) }
        try Task.checkCancellation()
        let available = try await loadTracks(in: source, offset: 0, limit: 500).tracks
        let selected = trackRefs.compactMap { ref in available.first { $0.trackRef == ref } }
        guard selected.count == trackRefs.count, trackRefs.contains(trackRef) else { throw MusicLibraryError.invalidRequest }
        contextTracks = selected
        try await playTrack(trackRef, in: .playlist(id: "C"))
    }
    func shuffleTracks(_ trackRefs: [String], in source: MusicLibrarySource) async throws {
        shuffleRequests += 1
        guard let first = trackRefs.first else { throw MusicLibraryError.invalidRequest }
        try await playTracks(trackRefs, startingAt: first, in: source, shuffleEnabled: true)
    }
    func configurePlayback(failing: Bool = false, delayed: Bool = false) {
        contextFailure = failing ? MusicLibraryError.sourceUnavailable : nil
        delayContextPlayback = delayed
    }
    func failPlayback(with error: MusicPlaybackContextError) { contextFailure = error }
    func resetPlaybackRecords() { plays = []; contextPlays = [] }
    func currentPlaybackSource() async throws -> MusicLibrarySource? {
        let captured = currentSource
        if delayNextSourceRead {
            delayNextSourceRead = false
            try? await Task.sleep(for: .milliseconds(220))
        }
        return captured
    }
    func setCurrentSource(_ source: MusicLibrarySource?, delayed: Bool = false) {
        currentSource = source
        delayNextSourceRead = delayed
    }
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
    @MainActor private static func checkFilteredContextRecovery() async throws {
        let fixture = LibraryFixture(trackCount: 454, favoriteCount: 186)
        let model = MusicLibraryBrowserModel(service: fixture)
        model.startIfNeeded()
        try await wait { !model.isLoading && model.filteredTracks.count == 454 }
        let originalCurrentTrack = model.tracks.first { $0.isFavorite == true }!.trackRef
        await fixture.setCurrentSource(.library)
        let playbackList = PlaybackListModel(service: fixture)
        playbackList.reload(currentTrackKey: originalCurrentTrack)
        try await wait { !playbackList.isLoading }
        try require(playbackList.tracks.count == 454, "夹具初始真实播放来源为整个资料库")
        var publishedContextVersions: [Int] = []
        let contextChanges = model.$confirmedPlaybackContextVersion.dropFirst().sink { version in
            publishedContextVersions.append(version)
            playbackList.reload(currentTrackKey: originalCurrentTrack)
        }
        defer { contextChanges.cancel(); playbackList.cancel() }

        model.select(.favorites)
        try await wait { model.displayedTracks.count == 186 }
        let favoriteRefs = model.displayedTracks.map(\.trackRef)
        var confirmedStarts = 0
        await fixture.failPlayback(with: MusicPlaybackContextError(stage: .create, appleEventCode: -1728))
        model.playFromStart(shuffleEnabled: true) { confirmedStarts += 1 }
        try await wait { !model.isPlayingRequest }
        let attemptedContext = await fixture.contextPlays.last!
        try require(attemptedContext.0 == favoriteRefs && attemptedContext.1 == .library,
                    "建立失败时仍传递全部186首喜爱引用，不传454首资料库")
        try require(model.playbackError?.contains("建立本次播放列表") == true
                    && model.playbackError?.contains("刷新") == false,
                    "上下文建立的对象错误不能误报来源消失或要求无效刷新")
        let failedPlays = await fixture.plays
        try require(confirmedStarts == 0 && failedPlays.isEmpty,
                    "失败不确认播放成功，也不误播旧列表")
        playbackList.reload(currentTrackKey: originalCurrentTrack)
        try await wait { !playbackList.isLoading }
        try require(playbackList.tracks.count == 454,
                    "建立失败后仍展示Music实际旧列表，不把186首伪装成已生效")

        await fixture.failPlayback(with: MusicPlaybackContextError(stage: .start))
        model.playFromStart(shuffleEnabled: true)
        try await wait { !model.isPlayingRequest }
        try require(model.playbackError?.contains("已开始播放") == true,
                    "启动上下文失败和来源不存在分别说明")
        await fixture.failPlayback(with: MusicPlaybackContextError(stage: .create, appleEventCode: -1743))
        model.playFromStart(shuffleEnabled: true)
        try await wait { !model.isPlayingRequest }
        try require(model.playbackError?.contains("自动化权限") == true,
                    "权限拒绝保留系统设置恢复入口，不能仅提示刷新")
        try require(model.confirmedPlaybackContextVersion == 0 && publishedContextVersions.isEmpty,
                    "建立、启动和权限失败均不得发布已确认上下文变更")

        await fixture.configurePlayback()
        model.playFromStart(shuffleEnabled: false) { confirmedStarts += 1 }
        try await wait { !model.isPlayingRequest }
        let actualPlays = await fixture.plays
        try require(confirmedStarts == 1 && actualPlays.count == 1 && model.playbackError == nil,
                    "修复服务失败后主动重试才确认一次播放成功")
        try require(actualPlays[0].0 == originalCurrentTrack && publishedContextVersions == [1],
                    "首曲未变但454→186上下文已确认时，仍发布一次版本通知")
        try await wait { !playbackList.isLoading }
        try require(playbackList.tracks.map(\.trackRef) == favoriteRefs && playbackList.tracks.count == 186,
                    "同一首歌曲按上下文版本通知自动读回186首，不能保留旧454首缓存")
    }

    @MainActor static func main() async throws {
        try await checkFilteredContextRecovery()
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
        model.playFromStart(shuffleEnabled: true)
        try await wait { !model.isPlayingRequest }
        let favoriteContext = await fixture.contextPlays
        try require(favoriteContext.count == 1 && favoriteContext[0].0 == model.displayedTracks.map(\.trackRef)
                    && favoriteContext[0].2 == true, "冷启动随机播放使用完整喜爱筛选上下文，不只选首曲后播全库")
        try require(await fixture.shuffleRequests == 1, "随机按钮使用独立随机入口，不预选某首强制建立新列表")
        let favoriteList = PlaybackListModel(service: fixture)
        favoriteList.reload(currentTrackKey: model.displayedTracks.first?.trackRef)
        try await wait { !favoriteList.isLoading }
        try require(favoriteList.tracks == model.displayedTracks && favoriteList.tracks.count == 1,
                    "当前播放列表读取真正的筛选播放上下文")
        favoriteList.cancel()
        await fixture.resetPlaybackRecords()
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
        let selectedContext = await fixture.contextPlays
        try require(plays.count == 1 && plays[0].1 == .playlist(id: "C")
                    && selectedContext[0].1 == .playlist(id: "B"), "点歌使用当前可见歌单建立真实上下文")
        await fixture.configurePlayback(failing: true)
        model.playFromStart(shuffleEnabled: true)
        try await wait { !model.isPlayingRequest }
        try require(await fixture.plays.count == 1 && model.playbackError != nil, "建立列表失败不误播旧列表")
        await fixture.configurePlayback()
        model.playFromStart(shuffleEnabled: false)
        try await wait { !model.isPlayingRequest }
        let ordinaryContext = await fixture.contextPlays
        try require(await fixture.plays.count == 2 && ordinaryContext.last?.2 == false, "普通播放把关闭随机意图交给上下文服务")
        let contextVersionBeforeCancellation = model.confirmedPlaybackContextVersion
        await fixture.configurePlayback(delayed: true)
        model.playFromStart(shuffleEnabled: true)
        model.select(.playlist("F"))
        try await wait { !model.isLoading }
        try require(model.isFolder && model.childPlaylists.count == 1 && model.tracks.isEmpty, "文件夹展示真实子歌单")
        try? await Task.sleep(for: .milliseconds(260))
        try require(await fixture.plays.count == 2, "切页后的迟到随机设置不能启动旧歌曲")
        try require(model.confirmedPlaybackContextVersion == contextVersionBeforeCancellation,
                    "已过期的播放结果不得发布上下文变更")
        await fixture.configurePlayback()
        await fixture.setCurrentSource(.playlist(id: "B"))
        let playbackList = PlaybackListModel(service: fixture)
        let currentTrack = "music-script:persistent:BBBBBBBBBBBBBBBB"
        playbackList.reload(currentTrackKey: currentTrack)
        try await wait { !playbackList.isLoading }
        try require(playbackList.title == "当前歌单" && playbackList.tracks.first?.trackRef == currentTrack,
                    "当前播放列表独立读取真实来源，不跟随浏览页面")
        await fixture.setCurrentSource(.playlist(id: "A"), delayed: true)
        playbackList.reload(currentTrackKey: "music-script:persistent:AAAAAAAAAAAAAAAA")
        try? await Task.sleep(for: .milliseconds(20))
        playbackList.cancel()
        await fixture.setCurrentSource(.playlist(id: "B"))
        playbackList.reload(currentTrackKey: currentTrack)
        try await wait { !playbackList.isLoading && playbackList.tracks.first?.trackRef == currentTrack }
        try? await Task.sleep(for: .milliseconds(260))
        try require(playbackList.title == "当前歌单" && playbackList.tracks.first?.trackRef == currentTrack,
                    "关闭重开后迟到的来源读取不能覆盖当前列表")
        await fixture.setCurrentSource(nil)
        playbackList.reload(currentTrackKey: currentTrack)
        try await wait { !playbackList.isLoading }
        try require(playbackList.tracks.isEmpty && playbackList.title == nil && playbackList.message != nil,
                    "来源未知清空旧列表并提供说明")
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
        resumed.playFromStart(shuffleEnabled: true)
        try await wait { !resumed.isPlayingRequest }
        let randomPlays = await delayedFixture.plays
        let randomContexts = await delayedFixture.contextPlays
        try require(randomPlays.count == 1 && randomPlays[0].1 == .playlist(id: "C")
                    && randomContexts[0].0 == resumed.displayedTracks.map(\.trackRef)
                    && resumed.displayedTracks.contains(where: { $0.trackRef == randomPlays[0].0 }),
                    "随机起始曲来自当前显示列表，完整显示列表成为播放上下文")

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
        print("AUTOMATED_PASS: library pagination/search/grouping/stale responses/play context/shuffle preparation/current playback list/folder/favorite/partial cache/recovery")
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
