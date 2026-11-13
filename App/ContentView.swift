import SwiftUI
import ShinAppleKit

/// 浏览位置与展示模式独立；窄窗临时显示小播放器，放大后恢复原浏览位置。
struct ContentView: View {
    private enum Presentation: String { case browser, nowPlaying, compact }
    private static let lyricsRailWidth: CGFloat = 260
    private static let floatingPlayerMargin: CGFloat = 16
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var windowController = PlayerWindowController()
    @State private var selection: SidebarPage = .music(.recent)
    @State private var presentation: Presentation
    @State private var compactReturn: Presentation
    private let preferences: UserDefaults
    @AppStorage("player.hasSavedPresentation") private var hasSavedPresentation = false
    @State private var windowWidth: CGFloat = 1180
    @State private var floatingPlayerHeight: CGFloat = 0
    @State private var previousPages: [SidebarPage] = []
    @State private var showsPlaybackList = false
    @State private var showsStatusBar = false
    @State private var searchFocusRequest: UUID?
    @State private var trackRevealRequest: MusicLibraryTrackReveal?
    @State private var revealTask: Task<Void, Never>?
    @AppStorage("player.showLibraryLyrics") private var showsLibraryLyrics = true
    var floatingLyricsWindow: FloatingLyricsWindowController?
    var menuRouter: MusicWindowMenuRouter?

    init(preferences: UserDefaults = .standard, floatingLyricsWindow: FloatingLyricsWindowController? = nil,
         menuRouter: MusicWindowMenuRouter? = nil) {
        self.preferences = preferences
        self.floatingLyricsWindow = floatingLyricsWindow
        self.menuRouter = menuRouter
        _presentation = State(initialValue: Presentation(rawValue: preferences.string(forKey: "player.presentationMode") ?? "") ?? .browser)
        let savedReturn = Presentation(rawValue: preferences.string(forKey: "player.compactReturnMode") ?? "") ?? .browser
        _compactReturn = State(initialValue: savedReturn == .compact ? .browser : savedReturn)
    }

    private var expandedPresentation: Presentation { presentation == .compact ? compactReturn : presentation }
    private var selectionBinding: Binding<SidebarPage> {
        Binding(get: { selection }, set: { selectPage($0) })
    }

    private var musicDestination: MusicLibraryDestination? {
        if case let .music(destination) = selection { return destination }
        return nil
    }

    private var isBrowsing: Bool {
        expandedPresentation == .browser && windowWidth >= PlayerWindowController.compactBreakpoint
    }

    private var libraryLyricsVisible: Bool {
        let sidebarWidth = windowWidth >= 900 ? SidebarView.width : 0
        return isBrowsing && showsLibraryLyrics && windowWidth - sidebarWidth >= 740
    }

    private var hasPresentedSheet: Bool {
        model.isImportPresented
            || model.isLyricsFetchPresented
            || model.isLyricsEditorPresented
            || model.isLibraryPresented
            || model.isAudioLinkImportPresented
    }

    var body: some View {
        GeometryReader { geometry in
            let usesCompact = geometry.size.width < PlayerWindowController.compactBreakpoint
            let hasSidebar = expandedPresentation == .browser && geometry.size.width >= 900
            let availableWidth = geometry.size.width - (hasSidebar ? SidebarView.width : 0)
            let hasLyrics = expandedPresentation == .browser && showsLibraryLyrics && availableWidth >= 740
            HStack(spacing: 0) {
                if hasSidebar {
                    SidebarView(selection: selectionBinding, browser: model.musicLibraryBrowser,
                                onEditLyrics: { model.beginLyricsEditing() },
                                onNowPlaying: { showNowPlaying() },
                                onImportAudioFromLink: { model.beginAudioLinkImport() },
                                topContentInset: geometry.safeAreaInsets.top)
                }
                if usesCompact {
                    CompactPlayerView(artworkStore: model.artworkStore, topControls: AnyView(compactWindowControls))
                } else if expandedPresentation == .nowPlaying {
                    NowPlayingView(artworkStore: model.artworkStore)
                } else {
                    browserArea(hasLyrics: hasLyrics, availableWidth: availableWidth)
                }
            }
            .ignoresSafeArea(.container, edges: hasSidebar || usesCompact ? .top : [])
            .background(VisualEffectBackground(material: .contentBackground))
            .background {
                let accessor = PlayerWindowAccessor(controller: windowController, initiallyCompact: presentation == .compact,
                                                    needsExpandedWindow: hasPresentedSheet, menuRouter: menuRouter)
                MusicWindowMenuObserver(browser: model.musicLibraryBrowser, accessor: accessor) { browser in
                    guard !hasPresentedSheet, !model.isTerminating else { return nil }
                    return windowMenuActions(browser)
                }
            }
            .overlay(alignment: .top) {
                if expandedPresentation != .browser && !usesCompact {
                    windowControls
                        .padding(.leading, 76)
                        .offset(y: -geometry.safeAreaInsets.top)
                }
            }
            .onChange(of: geometry.size.width, initial: true) { previousWidth, width in
                windowWidth = width
                if width < PlayerWindowController.compactBreakpoint { showsPlaybackList = false }
                if windowController.hasRestoredInitialLayout, presentation == .compact,
                   windowController.hasExpandedContent,
                   previousWidth < PlayerWindowController.compactBreakpoint,
                   width >= PlayerWindowController.compactBreakpoint {
                    presentation = compactReturn
                }
            }
            .task {
                guard !hasSavedPresentation else { return }
                hasSavedPresentation = true
            }
        }
        .sheet(isPresented: $model.isImportPresented) {
            if let flow = model.importFlow { ImportFlowView(flow: flow) }
        }
        .sheet(isPresented: $model.isLyricsFetchPresented) {
            if let fetchModel = model.lyricsFetchModel {
                NeteaseLyricsFetchView(
                    model: fetchModel,
                    isMock: model.isMock,
                    onClose: { model.isLyricsFetchPresented = false }
                )
            }
        }
        .sheet(isPresented: $model.isLibraryPresented) {
            if let library = model.library { LyricsLibraryView(library: library) }
        }
        .sheet(isPresented: $model.isLyricsEditorPresented,
               onDismiss: { model.finishLyricsEditing() }, content: {
            if let editor = model.lyricsEditor {
                LyricsEditorView(model: editor) { model.requestCloseLyricsEditor() }
            }
        })
        .sheet(isPresented: $model.isAudioLinkImportPresented,
               onDismiss: { model.flushPendingAudioLinkSheetAction() }, content: {
            if let linkModel = model.audioLinkImportModel {
                AudioLinkImportView(model: linkModel, isMock: model.isMock) {
                    model.isAudioLinkImportPresented = false
                }
            }
        })
        .onAppear {
            configureMainWindowPresentation()
            if hasPresentedSheet {
                expandForSheet(true)
            }
        }
        .onChange(of: model.isImportPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLyricsFetchPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLibraryPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLyricsEditorPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isAudioLinkImportPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: presentation) { _, mode in
            preferences.set(mode.rawValue, forKey: "player.presentationMode")
            if mode != .browser { showsPlaybackList = false }
        }
        .onChange(of: compactReturn) { _, mode in
            preferences.set(mode.rawValue, forKey: "player.compactReturnMode")
        }
        .onReceive(NotificationCenter.default.publisher(for: .shinSelectLibraryPage)) { _ in openPage(.library) }
        .onDisappear { cancelTrackReveal() }
    }

    private func browserArea(hasLyrics: Bool, availableWidth: CGFloat) -> some View {
        let railWidth = hasLyrics ? Self.lyricsRailWidth : 0
        let playerWidth = max(0, availableWidth - railWidth - 2 * Self.floatingPlayerMargin)
        return HStack(spacing: 0) {
            browserPage.frame(maxWidth: .infinity, maxHeight: .infinity)
                // 浮栏不参与资料库尺寸求解，进度更新只重排覆盖层。
                .overlay(alignment: .bottom) {
                    PlayerBarView(artworkStore: model.artworkStore,
                                  availableWidth: playerWidth,
                                  onNowPlaying: { showNowPlaying() },
                                  onToggleLyrics: { toggleLibraryLyrics(isVisible: hasLyrics) },
                                  showsLyrics: hasLyrics,
                                  floatingLyricsControl: floatingLyricsControl,
                                  trailingMenu: AnyView(navigationMenu()
                                    .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)),
                                  playbackListVisibility: $showsPlaybackList)
                        .frame(maxWidth: PlayerBarView.maximumWidth)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: FloatingPlayerHeightKey.self, value: geometry.size.height)
                            }
                        }
                        .padding(.horizontal, Self.floatingPlayerMargin)
                        .padding(.bottom, 20)
                }
                .onPreferenceChange(FloatingPlayerHeightKey.self) { height in
                    guard height > 0, floatingPlayerHeight != height else { return }
                    floatingPlayerHeight = height
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsStatusBar, musicDestination != nil {
                        MusicLibraryStatusBar(browser: model.musicLibraryBrowser)
                    }
                }
            HStack(spacing: 0) {
                if hasLyrics {
                    MusicLibraryLyricsRail(artworkStore: model.artworkStore,
                                           onClose: { showsLibraryLyrics = false })
                        .frame(width: Self.lyricsRailWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: railWidth, alignment: .trailing)
            .clipped()
            .contentShape(Rectangle())
            .allowsHitTesting(hasLyrics)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: hasLyrics)
    }

    private var floatingLyricsControl: AnyView? {
        floatingLyricsWindow.map { controller in
            AnyView(FloatingLyricsToggleButton(controller: controller, model: model))
        }
    }

    @ViewBuilder
    private var browserPage: some View {
        // 使用实际栏高，涵盖窄屏换行和错误提示，末项仍能完整滚到浮栏上方。
        let bottomInset = floatingPlayerHeight + 40
        switch selection {
        case .music:
            MusicLibraryBrowserView(browser: model.musicLibraryBrowser, page: selectionBinding,
                                    bottomContentInset: bottomInset, searchFocusRequest: $searchFocusRequest,
                                    trackRevealRequest: $trackRevealRequest)
        case .library:
            if let library = model.library {
                LyricsLibraryView(library: library, isEmbedded: true, bottomContentInset: bottomInset)
            } else {
                libraryUnavailable
            }
        case .settings:
            SettingsPageView(bottomContentInset: bottomInset)
        }
    }

    private var windowControls: some View {
        HStack(spacing: 14) {
            playerPresentationControls
            Spacer()
            PlaybackVolumeButton(model: model.playbackOptions, compact: true)
            navigationMenu(compact: true)
        }
        .buttonStyle(.plain)
        .font(.body)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 34)
    }

    private var compactWindowControls: some View {
        HStack(spacing: 2) {
            Button {
                if presentation == .compact { presentation = compactReturn }
                windowController.showExpanded(reduceMotion: reduceMotion)
            } label: {
                Image(systemName: "pip.exit")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .help("展开窗口，返回原页面")
            .accessibilityLabel("展开窗口，返回原页面")
            PlaybackVolumeButton(model: model.playbackOptions, compact: true)
            navigationMenu(compact: true)
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5).allowsHitTesting(false) }
    }

    private var playerPresentationControls: some View {
        HStack(spacing: 0) {
            Button { returnToBrowser() } label: {
                Image(systemName: "xmark").frame(width: 32, height: 32)
            }
            .help("关闭播放器，返回资料库")
            .accessibilityLabel("关闭播放器并返回资料库")
            Button {
                if presentation == .compact {
                    presentation = compactReturn
                    windowController.showExpanded(reduceMotion: reduceMotion)
                } else if windowController.showCompact(reduceMotion: reduceMotion) {
                    compactReturn = presentation
                    presentation = .compact
                }
            } label: {
                Image(systemName: presentation == .compact ? "pip.exit" : "pip.enter")
                    .frame(width: 32, height: 32)
            }
            .help(presentation == .compact ? "展开播放器" : "切换紧凑播放器")
            .accessibilityLabel(presentation == .compact ? "展开播放器" : "切换紧凑播放器")
        }
        .font(.title2.weight(.medium))
        .padding(1)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.14), lineWidth: 0.75).allowsHitTesting(false) }
        .environment(\.colorScheme, .dark)
    }

    private func navigationMenu(compact: Bool = false) -> some View {
        MusicLibraryNavigationMenu(
            browser: model.musicLibraryBrowser,
            panel: model.lyricsPanel,
            compact: compact,
            canImport: model.canBeginImport,
            onSelect: openPage,
            onNowPlaying: showNowPlaying,
            onImport: { expandBeforeAction { model.beginImport() } },
            onEdit: { expandBeforeAction { model.beginLyricsEditing() } },
            onImportAudioFromLink: { expandBeforeAction { model.beginAudioLinkImport() } }
        )
    }

    /// 浮窗只展示已知主窗；主窗关闭后由同一个 WindowGroup 重建并沿用已有 sheet。
    private func configureMainWindowPresentation() {
        let action = openWindow
        let controller = windowController
        floatingLyricsWindow?.presentMainWindow = { [weak controller] in
            if controller?.presentAttachedWindow() != true {
                action(id: PlayerWindowController.mainWindowGroupID)
            }
        }
    }

    private func openPage(_ page: SidebarPage) {
        returnToBrowser()
        selectPage(page)
    }

    private func selectPage(_ page: SidebarPage, remember: Bool = true, fromReveal: Bool = false) {
        if !fromReveal { cancelTrackReveal() }
        guard selection != page else { return }
        if remember { previousPages.append(selection) }
        searchFocusRequest = nil
        selection = page
        if case let .music(destination) = page { model.musicLibraryBrowser.select(destination) }
    }

    private func returnToBrowser() {
        if presentation == .compact || windowWidth < PlayerWindowController.compactBreakpoint {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
        presentation = .browser
    }

    private func showNowPlaying() {
        cancelTrackReveal()
        if presentation == .compact || windowWidth < PlayerWindowController.compactBreakpoint {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
        presentation = .nowPlaying
    }

    private func toggleLibraryLyrics(isVisible: Bool) {
        showsLibraryLyrics = !isVisible
        let hasSidebar = windowWidth >= 900
        if !isVisible && windowWidth - (hasSidebar ? SidebarView.width : 0) < 740 {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
    }

    private func expandBeforeAction(_ action: () -> Void) {
        if windowWidth < 900 {
            windowController.showExpanded(reduceMotion: true)
            if presentation == .compact { presentation = compactReturn }
        }
        action()
    }

    private func expandForSheet(_ shown: Bool) {
        if shown { expandBeforeAction({}) }
    }

    private var libraryUnavailable: some View {
        VStack(spacing: 8) {
            Text("本地歌词库不可用。").font(.headline)
            Text(model.lyricsDatabaseNote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FloatingPlayerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension ContentView {
    private func windowMenuActions(_ browser: MusicLibraryBrowserModel) -> MusicWindowMenuActions {
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
            importAudioFromLink: { expandBeforeAction { model.beginAudioLinkImport() } }
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

    private func cancelTrackReveal() {
        revealTask?.cancel()
        revealTask = nil
        trackRevealRequest = nil
    }
}
