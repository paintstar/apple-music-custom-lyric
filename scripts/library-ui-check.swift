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
    var favoriteSources: [MusicLibrarySource] = []
    var favoriteOverrides: [String: Bool] = [:]
    var failFavorite = false
    var rejectFavorite = false
    var nativeReads = 0
    var nativeOnlyAfterWrite = false
    let exclusiveTrack = MusicLibraryTrack(persistentID: "EEEEEEEEEEEEEEEE", title: "只在喜爱歌单的风铃",
                                           artist: "纸船乐队", isFavorite: true)
    var currentSource: MusicLibrarySource?
    var delayNextSourceRead = false
    var holdNextConfirmation = false
    var confirmationFailure = false
    var confirmationSourceOverride: MusicLibrarySource?
    var pendingConfirmation: CheckedContinuation<Void, Never>?
    var completedConfirmations = 0
    var cancelledConfirmations = 0
    let library: [MusicLibraryTrack]
    let restrictedPlaylistCount: Int?

    init(trackCount: Int = 447, favoriteCount: Int = 1, restrictedPlaylistCount: Int? = nil) {
        self.restrictedPlaylistCount = restrictedPlaylistCount
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
        var playlists = [MusicLibraryPlaylist(id: "N", name: "喜爱歌曲", isSmart: true),
         MusicLibraryPlaylist(id: "D", name: "喜爱歌曲"),
         MusicLibraryPlaylist(id: "A", name: "较慢歌单"),
         MusicLibraryPlaylist(id: "B", name: "当前歌单", parentID: "F"),
         MusicLibraryPlaylist(id: "C", name: "ShinApple · 当前播放"),
         MusicLibraryPlaylist(id: "F", name: "练习文件夹", isFolder: true)]
        if restrictedPlaylistCount != nil { playlists.append(MusicLibraryPlaylist(id: "P", name: "范围练习歌单")) }
        return nativeOnlyAfterWrite && favoriteOverrides.isEmpty ? playlists.filter { $0.id != "N" } : playlists
    }
    func hideNativeUntilFirstWrite() { nativeOnlyAfterWrite = true }
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        switch source {
        case .library:
            if offset == 0 { libraryFirstPageReads += 1 }
            if delaySecondPage && offset == 200 { try? await Task.sleep(for: .milliseconds(220)) }
            if failAfterFirstPage && offset > 0 { throw MusicLibraryError.contentsChanged }
            let end = min(offset + limit, library.count)
            return MusicLibraryTrackPage(tracks: Array(library[offset..<end]).map(withFavorite), totalCount: library.count,
                                         nextOffset: end < library.count ? end : nil)
        case let .playlist(id):
            if id == "P", let count = restrictedPlaylistCount {
                let members = Array(library.prefix(count))
                let end = min(offset + limit, members.count)
                return MusicLibraryTrackPage(tracks: Array(members[offset..<end]), totalCount: members.count,
                                             nextOffset: end < members.count ? end : nil)
            }
            if id == "N" {
                if offset == 0 { nativeReads += 1 }
                let members = (library.reversed() + [exclusiveTrack]).map(withFavorite).filter { $0.isFavorite == true }
                let end = min(offset + limit, members.count)
                return MusicLibraryTrackPage(tracks: Array(members[offset..<end]), totalCount: members.count,
                                             nextOffset: end < members.count ? end : nil)
            }
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
        if holdNextConfirmation {
            holdNextConfirmation = false
            let fail = confirmationFailure
            if let confirmationSourceOverride { currentSource = confirmationSourceOverride }
            await withCheckedContinuation { pendingConfirmation = $0 }
            do { try Task.checkCancellation() } catch {
                cancelledConfirmations += 1
                throw error
            }
            if fail { throw MusicLibraryError.contentsChanged }
            completedConfirmations += 1
        }
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
    func failPlayback(with error: any Error) { contextFailure = error }
    func resetPlaybackRecords() { plays = []; contextPlays = [] }
    func holdConfirmation(failing: Bool = false, actualSource: MusicLibrarySource? = nil) {
        holdNextConfirmation = true
        confirmationFailure = failing
        confirmationSourceOverride = actualSource
    }
    func releaseConfirmation() {
        let continuation = pendingConfirmation
        pendingConfirmation = nil
        continuation?.resume()
    }
    var isAwaitingConfirmation: Bool { pendingConfirmation != nil }
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
        try await setFavorite(trackRef, value: value, in: .library)
    }
    func setFavorite(_ trackRef: String, value: Bool, in source: MusicLibrarySource) async throws -> Bool {
        favoriteWriteCount += 1
        favoriteSources.append(source)
        let available: [MusicLibraryTrack]
        if source == .library { available = library }
        else { available = try await loadTracks(in: source, offset: 0, limit: 500).tracks }
        guard available.contains(where: { $0.trackRef == trackRef }) else { throw MusicLibraryError.sourceUnavailable }
        try await Task.sleep(for: .milliseconds(40))
        if failFavorite { throw MusicLibraryError.sourceUnavailable }
        if rejectFavorite { return !value }
        favoriteOverrides[trackRef] = value
        return value
    }
    private func withFavorite(_ track: MusicLibraryTrack) -> MusicLibraryTrack {
        var copy = track
        copy.isFavorite = favoriteOverrides[track.trackRef] ?? track.isFavorite
        return copy
    }
    func configureFavorite(failing: Bool = false, rejecting: Bool = false) {
        failFavorite = failing
        rejectFavorite = rejecting
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
        let originalCurrentTrack = model.tracks.last!.trackRef
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

        model.select(.playlist("N"))
        try await wait { !model.isLoading && model.displayedTracks.count == 187 }
        let favoriteRefs = model.displayedTracks.map(\.trackRef)
        var confirmedStarts = 0
        await fixture.failPlayback(with: MusicPlaybackContextError(stage: .create, appleEventCode: -1728))
        model.playFromStart(shuffleEnabled: true) { confirmedStarts += 1 }
        try await wait { !model.isPlayingRequest }
        let attemptedContext = await fixture.contextPlays.last!
        try require(attemptedContext.0 == favoriteRefs && attemptedContext.1 == .playlist(id: "N"),
                    "建立失败时仍传递原生歌单全部187首引用，不传454首资料库")
        try require(model.playbackError?.contains("建立本次播放列表") == true
                    && model.playbackError?.contains("刷新") == false,
                    "上下文建立的对象错误不能误报来源消失或要求无效刷新")
        let failedPlays = await fixture.plays
        try require(confirmedStarts == 0 && failedPlays.isEmpty,
                    "失败不确认播放成功，也不误播旧列表")
        playbackList.reload(currentTrackKey: originalCurrentTrack)
        try await wait { !playbackList.isLoading }
        try require(playbackList.tracks.count == 454,
                    "建立失败后仍展示Music实际旧列表，不把187首伪装成已生效")

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
                    "首曲未变但454→187上下文已确认时，仍发布一次版本通知")
        try await wait { !playbackList.isLoading }
        try require(playbackList.tracks.map(\.trackRef) == favoriteRefs && playbackList.tracks.count == 187,
                    "同一首歌曲按上下文版本通知自动读回187首，不能保留旧454首缓存")
    }

    @MainActor private static func checkFavoriteRefreshAndFailures() async throws {
        let fixture = LibraryFixture()
        let model = MusicLibraryBrowserModel(service: fixture)
        model.startIfNeeded()
        try await wait { !model.isLoading && model.tracks.count == 447 }
        model.select(.playlist("N"))
        try await wait { !model.isLoading && model.filteredTracks.count == 2 }
        let exclusive = model.filteredTracks[1]
        await fixture.configureFavorite(failing: true)
        model.setFavorite(exclusive, value: false)
        try await wait { model.favoriteWrites.isEmpty }
        try require(model.filteredTracks.count == 2 && model.filteredTracks[0].isFavorite == true
                    && model.playbackError != nil, "写入失败保留已确认标记及成员，不乐观移除")
        await fixture.configureFavorite(rejecting: true)
        model.setFavorite(exclusive, value: false)
        try await wait { model.favoriteWrites.isEmpty && !model.isLoading }
        try require(model.filteredTracks.count == 2 && model.filteredTracks[0].isFavorite == true
                    && model.playbackError != nil, "读回与意图不一致时显示Music实际结果并提示未保存")
        await fixture.configureFavorite()
        model.setFavorite(exclusive, value: false)
        model.select(.playlist("D"))
        try await wait { model.favoriteWrites.isEmpty && !model.isLoading && model.filteredTracks.count == 1 }
        try require(model.destination == .playlist("D") && model.filteredTracks[0].title == "当前歌单的句子",
                    "点星后快速换页不恢复旧歌单，迟到响应只刷新当前来源")
        let capturedSources = await fixture.favoriteSources
        try require(capturedSources.allSatisfy { $0 == .playlist(id: "N") }, "异步写入始终使用点击时捕获的来源")
        model.select(.playlist("N"))
        try await wait { !model.isLoading && model.filteredTracks.count == 1 }
        try require(model.filteredTracks[0].title == "末页星光", "重进原生歌单不沿用取消收藏前的成员缓存")
        model.select(.songs)
        try await wait { !model.isLoading && model.filteredTracks.count == 447 }
        let added = model.filteredTracks[0]
        model.selectedTrackID = added.id
        model.searchText = added.title
        try await wait { model.filteredTracks.count == 1 }
        model.scrollOffsetY = 42
        model.setFavorite(added, value: true)
        try await wait { model.favoriteWrites.isEmpty }
        try require(model.searchText == added.title && model.selectedTrackID == added.id && model.scrollOffsetY == 42,
                    "普通资料库点星不重置搜索、选择或滚动")
        model.select(.playlist("N"))
        try await wait { !model.isLoading && model.filteredTracks.count == 2 }
        try require(model.filteredTracks.map(\.trackRef).contains(added.trackRef),
                    "其他页面新增收藏使原生歌单缓存失效，重新进入读回Music成员")

        let firstFixture = LibraryFixture(trackCount: 5, favoriteCount: 0)
        await firstFixture.hideNativeUntilFirstWrite()
        let first = MusicLibraryBrowserModel(service: firstFixture)
        first.startIfNeeded()
        try await wait { !first.isLoading && first.filteredTracks.count == 5 }
        try require(!first.playlists.contains { $0.id == "N" }, "首次收藏前夹具尚未返回原生喜爱歌单")
        first.setFavorite(first.filteredTracks[0], value: true)
        try await wait { first.favoriteWrites.isEmpty && first.playlists.contains { $0.id == "N" } }
        try require(await firstFixture.libraryFirstPageReads == 1, "首次收藏轻量刷新歌单目录，无需重读全部资料库")
        first.cancelForTermination()
        model.cancelForTermination()
    }

    @MainActor static func main() async throws {
        try await checkFilteredContextRecovery()
        try await checkPlaylistScope()
        try await checkPlaybackListConfirmationLifecycle()
        try await checkPlaybackListReturnToPreviousTrack()
        try await checkPlaybackListSafeErrors()
        let fixture = LibraryFixture()
        let model = MusicLibraryBrowserModel(service: fixture)
        model.startIfNeeded()
        model.startIfNeeded()
        try await wait { !model.isLoading && model.filteredTracks.count == 447 }
        try require(model.tracks.count == 447 && !model.hasMore, "自动读取所有分页")
        try require(await fixture.prepareCount == 1, "多次挂载仅初始化一次")
        try require(await fixture.plays.isEmpty, "浏览不能自动开始播放")
        try require(model.filteredTracks.first?.title == "末页星光", "最近添加按真实日期排序")

        model.select(.playlist("N"))
        try await wait { !model.isLoading && model.filteredTracks.count == 2 }
        try require(model.filteredTracks.map(\.title) == ["末页星光", "只在喜爱歌单的风铃"],
                    "原生喜爱歌单保留独有曲目与Music返回顺序，不依赖全库标记筛选")
        try require(model.playlists.filter { $0.name == "喜爱歌曲" }.count == 2,
                    "同名普通歌单按各自persistent ID保留，不按名称合并")
        model.playFromStart(shuffleEnabled: true)
        try await wait { !model.isPlayingRequest }
        let favoriteContext = await fixture.contextPlays
        try require(favoriteContext.count == 1 && favoriteContext[0].0 == model.displayedTracks.map(\.trackRef)
                    && favoriteContext[0].1 == .playlist(id: "N") && favoriteContext[0].2 == true,
                    "冷启动随机播放使用原生喜爱歌单完整上下文与真实来源")
        try require(await fixture.shuffleRequests == 1, "随机按钮使用独立随机入口，不预选某首强制建立新列表")
        let favoriteList = PlaybackListModel(service: fixture)
        favoriteList.reload(currentTrackKey: model.displayedTracks.first?.trackRef)
        try await wait { !favoriteList.isLoading }
        try require(favoriteList.tracks == model.displayedTracks && favoriteList.tracks.count == 2,
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
        model.select(.playlist("N"))
        try await wait { !model.isLoading && model.filteredTracks.count == 2 }
        let favorite = model.filteredTracks[1]
        model.selectedTrackID = model.filteredTracks[0].id
        model.scrollOffsetY = 72
        let scrollSequence = model.scrollResetSequence
        model.setFavorite(favorite, value: false)
        model.setFavorite(favorite, value: false)
        try await wait { model.favoriteWrites.isEmpty && !model.isLoading && model.filteredTracks.count == 1 }
        let favoriteSources = await fixture.favoriteSources
        try require(await fixture.favoriteWriteCount == 1 && favoriteSources == [.playlist(id: "N")],
                    "同曲目喜爱请求去重并使用点击时真实来源，未入资料库也可取消喜爱")
        try require(model.selectedTrackID == model.filteredTracks[0].id && model.scrollOffsetY == 72
                    && model.scrollResetSequence == scrollSequence, "成员刷新保留现存选择与滚动位置")
        try await checkFavoriteRefreshAndFailures()

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

    @MainActor private static func checkPlaylistScope() async throws {
        let fixture = LibraryFixture(trackCount: 455, restrictedPlaylistCount: 187)
        let browser = MusicLibraryBrowserModel(service: fixture)
        browser.startIfNeeded()
        try await wait { !browser.isLoading && browser.tracks.count == 455 }
        browser.select(.playlist("P"))
        try await wait { !browser.isLoading && browser.displayedTracks.count == 187 }
        let expectedRefs = browser.displayedTracks.map(\.trackRef)
        let selected = browser.displayedTracks[93]
        browser.play(selected)
        try await wait { !browser.isPlayingRequest }
        let firstRequest = await fixture.contextPlays.last
        try require(firstRequest?.0 == expectedRefs && firstRequest?.1 == .playlist(id: "P"),
                    "187首歌单点播提交其完整可见顺序，不扩大为455首资料库")

        let playback = PlaybackListModel(service: fixture)
        playback.reload(currentTrackKey: selected.trackRef)
        try await wait { !playback.isLoading }
        try require(playback.tracks.map(\.trackRef) == expectedRefs, "当前播放列表从真实来源读回187首")
        playback.play(playback.tracks[150])
        try await wait { !playback.isPlayingRequest }
        let contextRequests = await fixture.contextPlays
        try require(contextRequests.count == 2 && contextRequests.last?.0 == expectedRefs,
                    "当前播放列表再次点歌也走完整上下文，不能绕回单曲入口")
        playback.reload(currentTrackKey: browser.displayedTracks[150].trackRef)
        try await wait { !playback.isLoading }
        try require(playback.tracks.count == 187 && browser.displayedTracks.count == 187,
                    "再次点播后实际来源仍为187首，浏览歌单不受播放刷新影响")
        playback.cancel()
        browser.cancelForTermination()
    }

    @MainActor private static func checkPlaybackListConfirmationLifecycle() async throws {
        let fixture = LibraryFixture(trackCount: 455, restrictedPlaylistCount: 187)
        let playback = PlaybackListModel(service: fixture)
        let members = try await fixture.loadTracks(in: .playlist(id: "P"), offset: 0, limit: 200).tracks
        let original = members[0].trackRef
        let target = members[95].trackRef
        func synchronize(_ key: String?, epoch: Int, session: Int = 1, context: Int = 0) {
            playback.synchronize(with: .init(trackKey: key, trackEpoch: epoch, sessionEpoch: session,
                                             contextVersion: context))
        }
        await fixture.setCurrentSource(.playlist(id: "P"))
        synchronize(original, epoch: 1)
        try await wait { !playback.isLoading && playback.tracks.count == 187 }
        await fixture.holdConfirmation()
        playback.play(members[95])
        try await waitForConfirmation(fixture)
        synchronize(nil, epoch: 2)
        synchronize(original, epoch: 3)
        synchronize(target, epoch: 4)
        try require(playback.isPlayingRequest && !playback.isLoading && playback.tracks.count == 187,
                    "自己的空快照、旧曲和目标曲过渡均不得取消仍在途的后端确认")
        await fixture.releaseConfirmation()
        try await wait { !playback.isPlayingRequest && !playback.isLoading }
        let completed = await fixture.completedConfirmations
        let cancelled = await fixture.cancelledConfirmations
        try require(completed == 1 && cancelled == 0,
                    "快照先到、后端后确认时命令保持有效并完成一次")
        try require(playback.tracks.map(\.trackRef) == members.map(\.trackRef),
                    "确认结束后重新读回实际187首来源")

        await fixture.holdConfirmation(failing: true, actualSource: .library)
        playback.play(members[120])
        try await waitForConfirmation(fixture)
        synchronize(members[120].trackRef, epoch: 5)
        await fixture.releaseConfirmation()
        try await wait { !playback.isPlayingRequest && !playback.isLoading }
        try require(playback.message == MusicLibraryError.contentsChanged.localizedDescription && playback.tracks.count == 455,
                    "目标快照不能吞掉来源错位确认错误，失败后展示真实455首而非伪造187首")
        synchronize(members[120].trackRef, epoch: 6)
        try await wait { !playback.isLoading }
        try require(playback.message == MusicLibraryError.contentsChanged.localizedDescription,
                    "确认失败后的迟到快照刷新不能清掉错误提示")

        await fixture.setCurrentSource(.playlist(id: "P"))
        synchronize(original, epoch: 6)
        try await wait { !playback.isLoading && playback.tracks.count == 187 }
        await fixture.holdConfirmation()
        playback.play(members[50])
        try await waitForConfirmation(fixture)
        await fixture.setCurrentSource(.library)
        let externalTrack = fixture.library[400].trackRef
        synchronize(externalTrack, epoch: 7)
        try await wait { !playback.isLoading && playback.tracks.count == 455 }
        try require(!playback.isPlayingRequest && playback.message?.contains("未完成确认") == true,
                    "外部第三首歌曲取消旧点歌并读取实际来源，保留未确认说明")
        await fixture.releaseConfirmation()
        try await waitForCancelledConfirmation(fixture, count: 1)
        try require(playback.tracks.count == 455 && playback.message?.contains("未完成确认") == true,
                    "被取消的迟到确认不能清掉新来源或错误说明")

        try await checkPlaybackListExplicitCancellation(fixture: fixture, playback: playback, members: members)
        playback.cancel()
        print("AUTOMATED_PASS: playback-list snapshot transitions/confirmation failure/actual source/external change/late cancellation")
    }

    @MainActor private static func checkPlaybackListExplicitCancellation(
        fixture: LibraryFixture, playback: PlaybackListModel, members: [MusicLibraryTrack]
    ) async throws {
        let target = members[25].trackRef
        for (index, reason) in ["session", "context", "refresh", "replace", "close"].enumerated() {
            await fixture.setCurrentSource(.playlist(id: "P"))
            playback.synchronize(with: .init(trackKey: members[0].trackRef, trackEpoch: 10 + index,
                                             sessionEpoch: 1, contextVersion: 0))
            try await wait { !playback.isLoading && playback.tracks.count == 187 }
            await fixture.holdConfirmation(actualSource: reason == "replace" ? .playlist(id: "P") : nil)
            playback.play(members[25])
            try await waitForConfirmation(fixture)
            switch reason {
            case "session":
                playback.synchronize(with: .init(trackKey: target, trackEpoch: 20, sessionEpoch: 2, contextVersion: 0))
            case "context":
                playback.synchronize(with: .init(trackKey: target, trackEpoch: 21, sessionEpoch: 1, contextVersion: 1))
            case "refresh": playback.reload(currentTrackKey: target)
            case "replace": playback.play(members[26])
            default: playback.cancel()
            }
            try await wait { !playback.isPlayingRequest && !playback.isLoading }
            await fixture.releaseConfirmation()
            try await waitForCancelledConfirmation(fixture, count: index + 2)
            if reason == "close" {
                try require(playback.tracks.isEmpty && playback.message == nil,
                            "关闭后迟到确认不能重开列表或写入错误")
            } else if reason == "replace" {
                try require(playback.tracks.count == 187 && playback.message == nil,
                            "新明确点歌完成后旧请求的迟到取消不能写入错误或清掉新结果")
            } else {
                try require(playback.tracks.count == 187 && playback.message?.contains("未完成确认") == true,
                            "会话、明确上下文或手动刷新取消旧请求，迟到结果不覆盖新读取")
            }
        }
    }

    @MainActor private static func checkPlaybackListReturnToPreviousTrack() async throws {
        let fixture = LibraryFixture(trackCount: 455, restrictedPlaylistCount: 187)
        let playback = PlaybackListModel(service: fixture)
        let members = try await fixture.loadTracks(in: .playlist(id: "P"), offset: 0, limit: 200).tracks
        let original = members[0].trackRef
        let target = members[95].trackRef
        func synchronize(_ key: String?, epoch: Int) {
            playback.synchronize(with: .init(trackKey: key, trackEpoch: epoch, sessionEpoch: 1, contextVersion: 0))
        }
        await fixture.setCurrentSource(.playlist(id: "P"))
        synchronize(original, epoch: 1)
        try await wait { !playback.isLoading && playback.tracks.count == 187 }
        await fixture.holdConfirmation()
        playback.play(members[95])
        try await waitForConfirmation(fixture)
        synchronize(target, epoch: 2)
        synchronize(original, epoch: 1)
        try require(playback.isPlayingRequest && !playback.isLoading,
                    "目标曲出现后原曲的旧epoch迟到样本不能取消确认")
        synchronize(nil, epoch: 3)
        await fixture.setCurrentSource(.library)
        synchronize(original, epoch: 4)
        try await wait { !playback.isPlayingRequest && !playback.isLoading }
        try require(playback.tracks.count == 455 && playback.message?.contains("未完成确认") == true,
                    "A→B后以更新epoch回到A是外部切歌，取消旧确认并读取实际455首来源")
        await fixture.releaseConfirmation()
        try await waitForCancelledConfirmation(fixture, count: 1)
        try require(playback.tracks.count == 455 && playback.message?.contains("未完成确认") == true,
                    "回到A后B的迟到取消不能清掉实际列表与说明")

        await fixture.setCurrentSource(.playlist(id: "P"))
        synchronize(original, epoch: 5)
        try await wait { !playback.isLoading && playback.tracks.count == 187 }
        await fixture.holdConfirmation()
        playback.play(members[0])
        try await waitForConfirmation(fixture)
        synchronize(nil, epoch: 6)
        synchronize(original, epoch: 7)
        synchronize(original, epoch: 8)
        try require(playback.isPlayingRequest && !playback.isLoading,
                    "从头重播当前曲时A等于目标B，空快照及更新epoch仍属于目标确认")
        await fixture.releaseConfirmation()
        try await wait { !playback.isPlayingRequest && !playback.isLoading }
        try require(playback.tracks.count == 187 && playback.message == nil,
                    "同曲重播确认完成后读取实际列表，不误报外部切歌")
        playback.cancel()
    }

    @MainActor private static func checkPlaybackListSafeErrors() async throws {
        let fixture = LibraryFixture(trackCount: 455, restrictedPlaylistCount: 187)
        let playback = PlaybackListModel(service: fixture)
        let members = try await fixture.loadTracks(in: .playlist(id: "P"), offset: 0, limit: 200).tracks
        await fixture.setCurrentSource(.playlist(id: "P"))
        playback.reload(currentTrackKey: members[0].trackRef)
        try await wait { !playback.isLoading && playback.tracks.count == 187 }
        let privateFixtureText = "fixture-private-script-and-library-field"
        let genericMessage = "播放未成功，请检查「音乐」App 后重试。"
        var cases: [(any Error, String)] = [MusicPlaybackContextError.Stage.create, .append, .select].map { stage in
            let error = MusicPlaybackContextError(stage: stage)
            return (error, error.localizedDescription)
        }
        let authorizationError = MusicPlaybackContextError(stage: .create, appleEventCode: -1743)
        cases.append((authorizationError, authorizationError.localizedDescription))
        cases.append((MusicLibraryError.sourceUnavailable, MusicLibraryError.sourceUnavailable.localizedDescription))
        cases.append((PlaybackError.unauthorized,
                      "需要允许 ShinApple 控制「音乐」App。请在系统设置的自动化权限中允许后重试。"))
        cases.append((PlaybackError.musicNotRunning, "暂时无法启动「音乐」App，请打开一次音乐后重试。"))
        cases.append((PlaybackError.trackUnavailable, "这首歌曲目前无法播放，请刷新资料库后重试。"))
        cases.append((PlaybackError.initializationFailed(privateFixtureText), genericMessage))
        cases.append((PlaybackError.unknown(privateFixtureText), genericMessage))
        cases.append((NSError(domain: "FixtureError", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: privateFixtureText]), genericMessage))
        for (index, item) in cases.enumerated() {
            await fixture.failPlayback(with: item.0)
            playback.play(members[95])
            try await wait { !playback.isPlayingRequest && !playback.isLoading }
            try require(playback.message == item.1 && playback.message?.contains(privateFixtureText) == false,
                        "当前列表失败采用安全固定说明，未知执行器文本不外显：用例\(index)")
            try require(playback.tracks.map(\.trackRef) == members.map(\.trackRef),
                        "显示具体失败原因后仍读回实际187首来源：用例\(index)")
        }
        try require(await fixture.plays.isEmpty, "失败原因显示不能误触发播放或谎报成功")
        playback.cancel()
    }

    @MainActor private static func waitForConfirmation(_ fixture: LibraryFixture) async throws {
        for _ in 0..<250 {
            if await fixture.isAwaitingConfirmation { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure.failed("等待后端进入播放确认超时")
    }

    @MainActor private static func waitForCancelledConfirmation(_ fixture: LibraryFixture, count: Int) async throws {
        for _ in 0..<250 {
            if await fixture.cancelledConfirmations == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure.failed("被取消的后端确认未清理")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}
