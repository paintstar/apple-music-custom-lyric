import SwiftUI
import ShinAppleKit

/// 浏览操作绑定到当前主窗口，菜单项与窗口内按钮共用同一份状态。
struct MusicWindowMenuActions: Equatable {
    var windowID: ObjectIdentifier
    var destination: MusicLibraryDestination?
    var playlists: [MusicLibraryPlaylist]
    var playlistSort: MusicLibraryPlaylistSort?
    var isPlaybackListVisible: Bool
    var areLyricsVisible: Bool
    var isStatusBarVisible: Bool
    var isFullScreen = false
    var selectDestination: (MusicLibraryDestination) -> Void
    var changePlaylistSort: (MusicLibraryPlaylistSort) -> Void
    var findInList: (() -> Void)?
    var togglePlaybackList: () -> Void
    var toggleLyrics: () -> Void
    var toggleStatusBar: (() -> Void)?
    var revealCurrentTrack: (() -> Void)?
    var goBack: (() -> Void)?
    var toggleFullScreen: (() -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID && lhs.destination == rhs.destination
            && lhs.playlists == rhs.playlists && lhs.playlistSort == rhs.playlistSort
            && lhs.isPlaybackListVisible == rhs.isPlaybackListVisible
            && lhs.areLyricsVisible == rhs.areLyricsVisible && lhs.isStatusBarVisible == rhs.isStatusBarVisible
            && lhs.isFullScreen == rhs.isFullScreen
            && (lhs.findInList == nil) == (rhs.findInList == nil)
            && (lhs.toggleStatusBar == nil) == (rhs.toggleStatusBar == nil)
            && (lhs.revealCurrentTrack == nil) == (rhs.revealCurrentTrack == nil)
            && (lhs.goBack == nil) == (rhs.goBack == nil)
            && (lhs.toggleFullScreen == nil) == (rhs.toggleFullScreen == nil)
    }
}

/// 系统菜单跟随当前主窗，失去焦点的窗口不能覆盖新主窗的菜单状态。
@MainActor
final class MusicWindowMenuRouter: ObservableObject {
    @Published private var publishedActions: MusicWindowMenuActions?
    private weak var window: NSWindow?
    private var owner: ObjectIdentifier?

    var actions: MusicWindowMenuActions? { window?.isKeyWindow == true ? publishedActions : nil }

    func publish(_ actions: MusicWindowMenuActions?, from owner: ObjectIdentifier, window: NSWindow?) {
        guard let window, window.isKeyWindow else {
            clear(from: owner)
            return
        }
        self.owner = owner
        self.window = window
        var windowActions = actions
        windowActions?.isFullScreen = window.styleMask.contains(.fullScreen)
        if window.styleMask.contains(.resizable) || window.styleMask.contains(.fullScreen) {
            windowActions?.toggleFullScreen = { [weak window] in
                guard let window, window.isKeyWindow else { return }
                window.toggleFullScreen(nil)
            }
        }
        if windowActions != publishedActions { publishedActions = windowActions }
    }

    func clear(from owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        window = nil
        if publishedActions != nil { publishedActions = nil }
    }
}

/// 监听资料库变化，复用窗口探针。播放位置变化不会重新发布菜单状态。
struct MusicWindowMenuObserver: View {
    @ObservedObject var browser: MusicLibraryBrowserModel
    var accessor: PlayerWindowAccessor
    let makeActions: (MusicLibraryBrowserModel) -> MusicWindowMenuActions?

    var body: some View {
        var updated = accessor
        updated.menuActions = accessor.menuRouter == nil ? nil : makeActions(browser)
        return updated
    }
}

struct SystemViewCommands: Commands {
    let window: MusicWindowMenuActions?

    var body: some Commands {
        // 扩展系统「显示」菜单，用实际主窗处理全屏。
        CommandGroup(after: .toolbar) {
            SystemViewMenuContent(window: window)
        }
        // 替换系统全屏所在的命令组，避免不同系统版本出现重复入口。
        CommandGroup(replacing: .sidebar) {
            Button(window?.isFullScreen == true ? "退出全屏幕" : "进入全屏幕") { window?.toggleFullScreen?() }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(window?.toggleFullScreen == nil)
        }
    }
}

private struct SystemViewMenuContent: View {
    let window: MusicWindowMenuActions?

    var body: some View {
        Group {
            Menu("播放列表视图") {
                ForEach(window?.playlists ?? []) { playlist in
                    destinationButton(playlist.name, .playlist(playlist.id))
                }
            }
            .disabled(window?.playlists.isEmpty != false)
            destinationButton("歌曲视图", .songs)
            destinationButton("专辑视图", .albums)
            destinationButton("艺人视图", .artists)
            Divider()
            Menu("排序方式") {
                if let window, let sort = window.playlistSort {
                    Picker("排序依据", selection: Binding(get: { sort.field }, set: { field in
                        window.changePlaylistSort(MusicLibraryPlaylistSort(field: field, ascending: field != .dateAdded))
                    })) {
                        ForEach(MusicLibraryPlaylistSort.Field.allCases, id: \.self) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    Picker("排列方向", selection: Binding(get: { sort.ascending }, set: { ascending in
                        window.changePlaylistSort(MusicLibraryPlaylistSort(field: sort.field, ascending: ascending))
                    })) {
                        Text(sort.field == .returnedOrder ? "正向" : "升序").tag(true)
                        Text(sort.field == .returnedOrder ? "反向" : "降序").tag(false)
                    }
                }
            }
            .disabled(window?.playlistSort == nil)
            Button("在当前列表中查找") { window?.findInList?() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(window?.findInList == nil)
            Divider()
            Button(window?.isPlaybackListVisible == true ? "隐藏当前播放列表" : "显示当前播放列表") {
                window?.togglePlaybackList()
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(window == nil)
            Button(window?.areLyricsVisible == true ? "隐藏歌词" : "显示歌词") {
                window?.toggleLyrics()
            }
            .keyboardShortcut("u", modifiers: [.command, .control])
            .disabled(window == nil)
            Button(window?.isStatusBarVisible == true ? "隐藏状态栏" : "显示状态栏") {
                window?.toggleStatusBar?()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(window?.toggleStatusBar == nil)
        }
    }

    private func destinationButton(_ title: String, _ destination: MusicLibraryDestination) -> some View {
        Toggle(title, isOn: Binding(get: { window?.destination == destination }, set: { _ in
            window?.selectDestination(destination)
        }))
        .disabled(window == nil)
    }
}

/// 单独观察资料库模型，暂停播放时加载完成的歌单也会立即出现在窄窗口导航中。
struct MusicLibraryNavigationMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: MusicLibraryBrowserModel
    var panel: LyricsPanelModel?
    var compact = false
    let canImport: Bool
    let onSelect: (SidebarPage) -> Void
    let onNowPlaying: () -> Void
    let onImport: () -> Void
    let onEdit: () -> Void
    @AppStorage(LyricsPanelView.translationsSettingKey) private var showTranslations = true
    @State private var unlinkRequest: LyricsUnlinkRequest?

    var body: some View {
        Group {
            if let panel {
                SyncLyricsMenu(
                    panel: panel, showTranslations: $showTranslations,
                    onUnlink: requestUnlink, onEdit: onEdit,
                    leadingItems: navigationItems, trailingItems: settingsItems, compact: compact,
                    accessibilityLabel: "播放器菜单", help: "资料库、歌词选项、学习与设置"
                )
            } else {
                PlaybackMenu(items: navigationItems + LyricsMenuActions.items(
                    panel: nil, showTranslations: $showTranslations, onUnlink: requestUnlink, onEdit: onEdit
                ) + settingsItems, iconSize: compact ? 14 : PlaybackControlSizing.iconSize,
                             width: compact ? 28 : PlaybackControlSizing.optionSide,
                             height: compact ? 30 : PlaybackControlSizing.optionSide,
                             accessibilityLabel: "播放器菜单", help: "资料库、歌词选项、学习与设置")
            }
        }
        .modifier(LyricsUnlinkConfirmation(request: $unlinkRequest))
    }

    private func requestUnlink() { unlinkRequest = LyricsUnlinkRequest(model: model) }

    private var navigationItems: [PlaybackMenu.Item] {
        var items = [PlaybackMenu.Item(title: "资料库")]
        for destination in [MusicLibraryDestination.search, .recent, .artists, .albums, .songs] {
            items.append(.init(title: destination.title, symbol: destination.symbol,
                               action: { onSelect(.music(destination)) }))
        }
        items += [.separator, .init(title: "播放列表")]
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
            .separator,
            .init(title: "当前歌词")
        ]
        return items
    }

    private var settingsItems: [PlaybackMenu.Item] {
        [.separator, .init(title: "设置", symbol: "gearshape", action: { onSelect(.settings) })]
    }
}

extension MusicLibraryBrowserModel {
    func hasTrackRow(_ trackKey: String) -> Bool {
        if isFolder || ((destination == .artists || destination == .albums) && selectedGroupID == nil) { return false }
        return displayedTracks.contains { $0.trackRef == trackKey }
    }
}
