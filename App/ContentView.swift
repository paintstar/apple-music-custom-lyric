import SwiftUI
import ShinAppleKit

/// 浏览位置与展示模式独立；窄窗临时显示小播放器，放大后恢复原浏览位置。
struct ContentView: View {
    private enum Presentation: String { case browser, nowPlaying, compact }
    private static let lyricsRailWidth: CGFloat = 260
    private static let floatingPlayerMargin: CGFloat = 16
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var windowController = PlayerWindowController()
    @State private var selection: SidebarPage = .music(.recent)
    @State private var presentation = Presentation(
        rawValue: UserDefaults.standard.string(forKey: "player.presentationMode") ?? ""
    ) ?? .browser
    @State private var compactReturn = Presentation(
        rawValue: UserDefaults.standard.string(forKey: "player.compactReturnMode") ?? ""
    ) ?? .browser
    @AppStorage("player.hasSavedPresentation") private var hasSavedPresentation = false
    @State private var windowWidth: CGFloat = 1180
    @State private var floatingPlayerHeight: CGFloat = 0
    @AppStorage("player.showLibraryLyrics") private var showsLibraryLyrics = true
    var floatingLyricsWindow: FloatingLyricsWindowController?

    var body: some View {
        GeometryReader { geometry in
            let usesCompact = presentation == .compact || geometry.size.width < PlayerWindowController.compactBreakpoint
            let hasSidebar = presentation == .browser && geometry.size.width >= 900
            let availableWidth = geometry.size.width - (hasSidebar ? SidebarView.width : 0)
            let hasLyrics = presentation == .browser && showsLibraryLyrics && availableWidth >= 740
            HStack(spacing: 0) {
                if hasSidebar {
                    SidebarView(selection: $selection, browser: model.musicLibraryBrowser,
                                onEditLyrics: { model.beginLyricsEditing() },
                                onNowPlaying: { showNowPlaying() },
                                topContentInset: geometry.safeAreaInsets.top)
                }
                if usesCompact {
                    CompactPlayerView(artworkStore: model.artworkStore, topControls: AnyView(compactWindowControls))
                } else if presentation == .nowPlaying {
                    NowPlayingView(artworkStore: model.artworkStore)
                } else {
                    browserArea(hasLyrics: hasLyrics, availableWidth: availableWidth)
                }
            }
            .ignoresSafeArea(.container, edges: hasSidebar || usesCompact ? .top : [])
            .background(VisualEffectBackground(material: .contentBackground))
            .background(PlayerWindowAccessor(controller: windowController))
            .overlay(alignment: .top) {
                if presentation != .browser && !usesCompact {
                    windowControls
                        .padding(.leading, 76)
                        .offset(y: -geometry.safeAreaInsets.top)
                }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in windowWidth = width }
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
        .onChange(of: model.isImportPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLyricsFetchPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLibraryPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: model.isLyricsEditorPresented) { _, shown in expandForSheet(shown) }
        .onChange(of: selection) { _, page in
            if case let .music(destination) = page { model.musicLibraryBrowser.select(destination) }
        }
        .onChange(of: presentation) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "player.presentationMode")
        }
        .onChange(of: compactReturn) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "player.compactReturnMode")
        }
        .onReceive(NotificationCenter.default.publisher(for: .shinSelectLibraryPage)) { _ in openPage(.library) }
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
                                    .frame(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide)))
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
            MusicLibraryBrowserView(browser: model.musicLibraryBrowser, page: $selection, bottomContentInset: bottomInset)
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
                } else {
                    compactReturn = presentation
                    presentation = .compact
                    windowController.showCompact(reduceMotion: reduceMotion)
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
            compact: compact,
            canImport: model.canBeginImport,
            canEdit: model.canBeginLyricsEditing,
            onSelect: openPage,
            onNowPlaying: showNowPlaying,
            onImport: { expandBeforeAction { model.beginImport() } },
            onEdit: { expandBeforeAction { model.beginLyricsEditing() } }
        )
    }

    private func openPage(_ page: SidebarPage) {
        returnToBrowser()
        selection = page
    }

    private func returnToBrowser() {
        if presentation == .compact || windowWidth < PlayerWindowController.compactBreakpoint {
            windowController.showExpanded(reduceMotion: reduceMotion)
        }
        presentation = .browser
    }

    private func showNowPlaying() {
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

/// 单独观察资料库模型，暂停播放时加载完成的歌单也会立即出现在窄窗口导航中。
private struct MusicLibraryNavigationMenu: View {
    @ObservedObject var browser: MusicLibraryBrowserModel
    var compact = false
    let canImport: Bool
    let canEdit: Bool
    let onSelect: (SidebarPage) -> Void
    let onNowPlaying: () -> Void
    let onImport: () -> Void
    let onEdit: () -> Void

    var body: some View {
        PlaybackMenu(items: menuItems, iconSize: compact ? 14 : PlaybackControlSizing.iconSize,
                     width: compact ? 28 : PlaybackControlSizing.optionSide,
                     height: compact ? 30 : PlaybackControlSizing.optionSide,
                     accessibilityLabel: "播放器菜单", help: "资料库、学习与设置")
    }

    private var menuItems: [PlaybackMenu.Item] {
        var items = [PlaybackMenu.Item(title: "资料库")]
        for destination in [MusicLibraryDestination.search, .recent, .artists, .albums, .songs, .favorites] {
            items.append(.init(title: destination.title, symbol: destination.symbol,
                               action: { onSelect(.music(destination)) }))
        }
        for playlist in browser.playlists {
            items.append(.init(title: playlist.name, symbol: playlist.isFolder ? "folder" : "music.note.list",
                               action: { onSelect(.music(.playlist(playlist.id))) }))
        }
        items += [
            .separator,
            .init(title: "完整播放器", symbol: "play.rectangle", action: onNowPlaying),
            .separator,
            .init(title: "学习"),
            .init(title: "学习歌曲与备份", symbol: "books.vertical", action: { onSelect(.library) }),
            .init(title: "导入本地歌词", symbol: "square.and.arrow.down", isEnabled: canImport, action: onImport),
            .init(title: "编辑当前歌词", symbol: "square.and.pencil", isEnabled: canEdit, action: onEdit),
            .separator,
            .init(title: "设置", symbol: "gearshape", action: { onSelect(.settings) })
        ]
        return items
    }
}
