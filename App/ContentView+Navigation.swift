import SwiftUI
import ShinAppleKit

extension ContentView {
    /// 浮窗只展示已知主窗；主窗关闭后由同一个 WindowGroup 重建并沿用已有 sheet。
    func configureMainWindowPresentation() {
        let action = openWindow
        let controller = windowController
        floatingLyricsWindow?.presentMainWindow = { [weak controller] in
            if controller?.presentAttachedWindow() != true {
                action(id: PlayerWindowController.mainWindowGroupID)
            }
        }
    }

    func openPage(_ page: SidebarPage) {
        returnToBrowser()
        selectPage(page)
    }

    func selectPage(_ page: SidebarPage, remember: Bool = true, fromReveal: Bool = false) {
        if !fromReveal { cancelTrackReveal() }
        guard selection != page else { return }
        if remember { previousPages.append(selection) }
        searchFocusRequest = nil
        selection = page
        if page == .audioLinkImport { model.prepareAudioLinkImportPage() }
        if case let .music(destination) = page { model.musicLibraryBrowser.select(destination) }
    }

    func returnToBrowser() {
        if presentation == .compact || windowWidth < PlayerWindowController.compactBreakpoint {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
        presentation = .browser
    }

    func showNowPlaying() {
        cancelTrackReveal()
        if presentation == .compact || windowWidth < PlayerWindowController.compactBreakpoint {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
        presentation = .nowPlaying
    }

    func toggleLibraryLyrics(isVisible: Bool) {
        showsLibraryLyrics = !isVisible
        let hasSidebar = windowWidth >= 900
        if !isVisible && windowWidth - (hasSidebar ? SidebarView.width : 0) < 740 {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
    }

    func expandBeforeAction(_ action: () -> Void) {
        if windowWidth < 900 {
            windowController.showExpanded(reduceMotion: true)
            if presentation == .compact { presentation = compactReturn }
        }
        action()
    }

    func expandForSheet(_ shown: Bool) {
        if shown { expandBeforeAction({}) }
    }

    var libraryUnavailable: some View {
        VStack(spacing: 8) {
            Text("本地歌词库不可用。").font(.headline)
            Text(model.lyricsDatabaseNote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func windowMenuActions(_ browser: MusicLibraryBrowserModel) -> MusicWindowMenuActions {
        let destination = musicDestination
        let isSelectedBrowser = destination == browser.destination
        let playlistSort: MusicLibraryPlaylistSort?
        if case .playlist = destination, isSelectedBrowser, !browser.isFolder {
            playlistSort = browser.playlistSort
        } else {
            playlistSort = nil
        }
        let canGoBack = !isBrowsing && presentation != .browser
            || isSelectedBrowser && browser.selectedGroupID != nil || !previousPages.isEmpty
        let find: (() -> Void)? = isSelectedBrowser && !browser.isFolder ? { focusLibrarySearch() } : nil
        let status: (() -> Void)? = destination != nil ? { toggleStatusBar() } : nil
        let reveal: () -> Void = { revealCurrentTrack() }
        let back: (() -> Void)? = canGoBack ? { goBack() } : nil
        return MusicWindowMenuActions(
            windowID: ObjectIdentifier(windowController),
            destination: destination, playlists: browser.playlists, playlistSort: playlistSort,
            isPlaybackListVisible: isBrowsing && showsPlaybackList, areLyricsVisible: libraryLyricsVisible,
            isStatusBarVisible: isBrowsing && destination != nil && showsStatusBar,
            selectDestination: { openPage(.music($0)) },
            changePlaylistSort: { sort in
                guard musicDestination == destination, destination == browser.destination, !browser.isFolder else { return }
                browser.setPlaylistSort(sort)
            },
            findInList: find, togglePlaybackList: { togglePlaybackList() }, toggleLyrics: { toggleLyricsFromMenu() },
            toggleStatusBar: status, revealCurrentTrack: reveal, goBack: back,
            importAudioFromLink: { openPage(.audioLinkImport) }
        )
    }

    private func focusLibrarySearch() {
        cancelTrackReveal()
        returnToBrowser()
        searchFocusRequest = UUID()
    }

    private func togglePlaybackList() {
        let wasVisible = isBrowsing && showsPlaybackList
        returnToBrowser()
        showsPlaybackList = !wasVisible
    }

    private func toggleLyricsFromMenu() {
        let wasVisible = libraryLyricsVisible
        returnToBrowser()
        toggleLibraryLyrics(isVisible: wasVisible)
    }

    private func toggleStatusBar() {
        returnToBrowser()
        showsStatusBar.toggle()
    }

    private func goBack() {
        cancelTrackReveal()
        if !isBrowsing && presentation != .browser {
            returnToBrowser()
        } else if musicDestination == model.musicLibraryBrowser.destination,
                  model.musicLibraryBrowser.selectedGroupID != nil {
            model.musicLibraryBrowser.selectGroup(nil)
        } else if let previous = previousPages.popLast() {
            returnToBrowser()
            selectPage(previous, remember: false)
        }
    }

    private func revealCurrentTrack() {
        cancelTrackReveal()
        guard let trackKey = model.snapshot.trackKey else { return }
        let browser = model.musicLibraryBrowser
        returnToBrowser()
        if musicDestination == browser.destination, browser.hasTrackRow(trackKey) {
            trackRevealRequest = MusicLibraryTrackReveal(destination: browser.destination, trackKey: trackKey)
            return
        }
        let originalPage = selection
        let originalGroup = browser.selectedGroupID
        let originalSearch = browser.searchText
        revealTask = Task { @MainActor in
            let source = try? await browser.browsingService?.currentPlaybackSource()
            guard !Task.isCancelled, selection == originalPage, browser.selectedGroupID == originalGroup,
                  browser.searchText == originalSearch, presentation == .browser, !hasPresentedSheet,
                  model.snapshot.trackKey == trackKey else { return }
            var destinations: [MusicLibraryDestination] = [.songs]
            if case let .playlist(id) = source, browser.playlists.contains(where: { $0.id == id && !$0.isFolder }) {
                destinations.insert(.playlist(id), at: 0)
            }
            for (index, destination) in destinations.enumerated() {
                selectPage(.music(destination), remember: index == 0, fromReveal: true)
                if !browser.searchText.isEmpty { browser.searchText = "" }
                let search = browser.searchText
                await browser.waitForTrackRows()
                guard !Task.isCancelled, musicDestination == destination, browser.destination == destination,
                      browser.searchText == search, presentation == .browser, !hasPresentedSheet,
                      model.snapshot.trackKey == trackKey else { return }
                if browser.hasTrackRow(trackKey) {
                    trackRevealRequest = MusicLibraryTrackReveal(destination: destination, trackKey: trackKey)
                    return
                }
            }
            model.playbackMessage = "当前歌曲暂未出现在已同步的资料库中。"
        }
    }

    func cancelTrackReveal() {
        revealTask?.cancel()
        revealTask = nil
        trackRevealRequest = nil
    }
}
