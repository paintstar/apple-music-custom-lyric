import SwiftUI
import ShinAppleKit

/// 浏览位置与展示模式独立；窄窗临时显示小播放器，放大后恢复原浏览位置。
struct ContentView: View {
    enum Presentation: String { case browser, nowPlaying, compact }
    private static let lyricsRailWidth: CGFloat = 260
    private static let floatingPlayerMargin: CGFloat = 16
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @StateObject var windowController = PlayerWindowController()
    @State var selection: SidebarPage = .music(.recent)
    @State var presentation: Presentation
    @State var compactReturn: Presentation
    private let preferences: UserDefaults
    @AppStorage("player.hasSavedPresentation") private var hasSavedPresentation = false
    @State var windowWidth: CGFloat = 1180
    @State private var floatingPlayerHeight: CGFloat = 0
    @State var previousPages: [SidebarPage] = []
    @State var showsPlaybackList = false
    @State var showsStatusBar = false
    @State var searchFocusRequest: UUID?
    @State var trackRevealRequest: MusicLibraryTrackReveal?
    @State var revealTask: Task<Void, Never>?
    @AppStorage("player.showLibraryLyrics") var showsLibraryLyrics = true
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

    var musicDestination: MusicLibraryDestination? {
        if case let .music(destination) = selection { return destination }
        return nil
    }

    var isBrowsing: Bool {
        expandedPresentation == .browser && windowWidth >= PlayerWindowController.compactBreakpoint
    }

    var libraryLyricsVisible: Bool {
        let sidebarWidth = windowWidth >= 900 ? SidebarView.width : 0
        return isBrowsing && showsLibraryLyrics && windowWidth - sidebarWidth >= 740
    }

    var hasPresentedSheet: Bool {
        model.isImportPresented || model.isLyricsFetchPresented
            || model.isLyricsEditorPresented || model.isLibraryPresented
            || model.isAIStudyPreviewPresented || model.isAIKeyPointsPresented
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
                                topContentInset: geometry.safeAreaInsets.top)
                }
                if usesCompact {
                    CompactPlayerView(artworkStore: model.artworkStore, topControls: AnyView(compactWindowControls))
                } else if expandedPresentation == .nowPlaying {
                    NowPlayingView(artworkStore: model.artworkStore, floatingLyricsControl: floatingLyricsControl)
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
        .sheet(isPresented: $model.isImportPresented) { if let flow = model.importFlow { ImportFlowView(flow: flow) } }
        .sheet(isPresented: $model.isLyricsFetchPresented) {
            if let fetchModel = model.lyricsFetchModel {
                NeteaseLyricsFetchView(model: fetchModel, isMock: model.isMock,
                                       onClose: { model.isLyricsFetchPresented = false })
            }
        }
        .sheet(isPresented: $model.isLibraryPresented) { if let library = model.library { LyricsLibraryView(library: library) } }
        .sheet(isPresented: $model.isLyricsEditorPresented, onDismiss: { model.finishLyricsEditing() }, content: {
            if let editor = model.lyricsEditor { LyricsEditorView(model: editor) { model.requestCloseLyricsEditor() } }
        })
        .sheet(isPresented: $model.isAIStudyPreviewPresented, onDismiss: { model.finishAIStudyPreview() }, content: {
            if let previewModel = model.aiStudyPreviewModel { AIStudyPreviewView(model: previewModel) }
        })
        .sheet(isPresented: $model.isAIKeyPointsPresented, onDismiss: { model.finishAIKeyPoints() }, content: {
            if let keyPointsModel = model.aiKeyPointsModel { AIKeyPointsView(model: keyPointsModel) }
        })
        .onAppear {
            configureMainWindowPresentation()
            if hasPresentedSheet { expandForSheet(true) }
        }
        .onChange(of: model.isImportPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLyricsFetchPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLibraryPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLyricsEditorPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isAIStudyPreviewPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isAIKeyPointsPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: presentation) { _, mode in
            preferences.set(mode.rawValue, forKey: "player.presentationMode")
            if mode != .browser { showsPlaybackList = false }
        }
        .onChange(of: compactReturn) { _, mode in
            preferences.set(mode.rawValue, forKey: "player.compactReturnMode")
        }
        .onReceive(NotificationCenter.default.publisher(for: .shinSelectLibraryPage)) { _ in openPage(.library) }
        .onReceive(NotificationCenter.default.publisher(for: .shinSelectAudioLinkImportPage)) { _ in openPage(.audioLinkImport) }
        .onReceive(NotificationCenter.default.publisher(for: .shinSelectSettingsPage)) { notification in
            let category = notification.object as? SettingsCategory ?? .aiStudy
            preferences.set(category.rawValue, forKey: SettingsCategory.preferenceKey)
            openPage(.settings)
        }
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
        case .vocabulary:
            if let store = model.lyricsStore {
                VocabularyBookContainerView(
                    store: store,
                    model: model,
                    bottomContentInset: bottomInset
                )
                .id(ObjectIdentifier(store))
            } else {
                libraryUnavailable
            }
        case .audioLinkImport:
            AudioLinkImportView(model: model.ensureAudioLinkImportModel(), isMock: model.isMock,
                                bottomContentInset: bottomInset)
        case .settings:
            SettingsPageView(bottomContentInset: bottomInset)
        }
    }

    private var windowControls: some View {
        HStack(spacing: 14) {
            playerPresentationControls
                .offset(y: 4)
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
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
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
                    .contentShape(Rectangle())
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
            browser: model.musicLibraryBrowser, panel: model.lyricsPanel, compact: compact,
            canImport: model.canBeginImport, onSelect: openPage, onNowPlaying: showNowPlaying,
            onImport: { expandBeforeAction { model.beginImport() } },
            onEdit: { expandBeforeAction { model.beginLyricsEditing() } }
        )
    }
}

private struct FloatingPlayerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
