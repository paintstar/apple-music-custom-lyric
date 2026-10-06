import SwiftUI
import ShinAppleKit

/// 同步自官方「音乐」App 的资料库浏览；所有行都来自公开脚本读取的记录。
struct MusicLibraryBrowserView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: MusicLibraryBrowserModel
    @Binding var page: SidebarPage
    var bottomContentInset: CGFloat = 24
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                if let error = browser.errorMessage {
                    recoverableMessage(error)
                }
                if let error = browser.playbackError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                content(width: geometry.size.width)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task { browser.startIfNeeded() }
    }

    private func toolbar(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            if browser.selectedGroupID != nil {
                Button { browser.selectGroup(nil) } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32)
                }
                .background(.ultraThinMaterial, in: Circle())
                .help("返回\(browser.destination.title)")
                .accessibilityLabel("返回\(browser.destination.title)")
            }
            Spacer(minLength: 8)
            if browser.isLoading {
                ProgressView().controlSize(.small)
                    .help("正在同步全部歌曲，完成后搜索与分类会包含完整资料库")
            }
            Button { browser.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
            }
            .background(.ultraThinMaterial, in: Circle())
            .help("重新同步音乐资料库")
            .accessibilityLabel("刷新音乐资料库")
            .disabled(browser.isLoading)
            searchField.frame(width: min(260, width * 0.52))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, width < 500 ? 16 : 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(browser.destination == .search ? "搜索资料库" : "在当前列表中查找", text: $browser.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("搜索已同步音乐资料库")
            if !browser.searchText.isEmpty {
                Button { browser.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("清除搜索")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.primary.opacity(0.035), in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.75).allowsHitTesting(false) }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if browser.isLoading && browser.tracks.isEmpty && !browser.isFolder {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在同步「音乐」资料库……").foregroundStyle(.secondary)
                Text("加载歌曲和播放列表，不会开始播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    libraryHeader(width: width)
                        .id("library-header")
                    if browser.isFolder {
                        folderRows
                    } else if (browser.destination == .artists || browser.destination == .albums)
                                && browser.selectedGroupID == nil {
                        groupGrid(width: width)
                    } else if browser.displayedTracks.isEmpty {
                        emptyState
                    } else {
                        tableHeader
                        // 封面和表头高度不同，不能参与歌曲行的惰性高度估算。
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(browser.displayedTracks) { track in
                                MusicLibraryTrackRow(browser: browser, track: track,
                                                     isSelected: browser.selectedTrackID == track.id,
                                                     isCurrent: model.snapshot.trackKey == track.trackRef,
                                                     isPlaying: model.snapshot.status == .playing,
                                                     onSelect: { browser.selectedTrackID = track.id },
                                                     onPlay: { browser.play(track) })
                                    .id(track.id)
                            }
                        }
                    }
                    syncFooter
                }
                .background(LibraryScrollPositionRecorder(browser: browser).allowsHitTesting(false))
                .padding(.horizontal, width < 500 ? 16 : 28)
                .padding(.bottom, bottomContentInset)
            }
        }
    }

    private func libraryHeader(width: CGFloat) -> some View {
        let side = min(220, max(96, width * 0.25))
        return HStack(alignment: .bottom, spacing: width < 500 ? 18 : 30) {
            Group {
                if browser.destination == .favorites {
                    Color.white.opacity(0.90).overlay {
                        Image(systemName: "star.fill").resizable().scaledToFit()
                            .frame(width: side * 0.48, height: side * 0.48)
                            .foregroundStyle(Color.appleMusicPink)
                    }
                } else {
                    MusicLibraryArtworkView(browser: browser, trackRef: browser.displayedTracks.first?.trackRef,
                                            symbol: browser.destination.symbol)
                }
            }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(browser.title)
                    .font(width < 500 ? .title2.bold() : .largeTitle.bold())
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(browser.isFolder ? "播放列表文件夹" : "\(browser.displayedTracks.count) 首歌曲")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if browser.destination == .search {
                    Text("搜索已同步的歌曲、艺人和专辑。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let first = browser.displayedTracks.first, !browser.isFolder {
                    Button {
                        browser.play(first)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.appleMusicPink)
                    .disabled(browser.isPlayingRequest)
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 24)
        .padding(.bottom, 32)
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("歌曲").frame(maxWidth: .infinity, alignment: .leading)
            Text("时长").frame(width: 44, alignment: .trailing)
            Color.clear.frame(width: 24)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 38)
        .padding(.trailing, 8)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(browser.lacksFavoriteMetadata ? "当前资料库没有提供喜爱标记。" : "这里还没有歌曲。")
                .font(.headline)
            Text(emptyExplanation).foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var emptyExplanation: String {
        if !browser.searchText.isEmpty { return "没有找到匹配内容。可以换一个关键词，或继续同步资料库中的其他歌曲。" }
        if browser.destination == .favorites { return "在「音乐」App 中标记喜爱后，刷新这里即可查看。" }
        if browser.isPartial { return "当前分类中暂无已同步歌曲，继续同步可读取更多内容。" }
        return "在「音乐」App 中添加歌曲或播放列表后，点击右上角刷新。"
    }

    private func groupGrid(width: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width < 500 ? 120 : 150), spacing: 20)], spacing: 24) {
            ForEach(browser.groups) { group in
                Button { browser.selectGroup(group.id) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        MusicLibraryArtworkView(browser: browser, trackRef: group.tracks.first?.trackRef,
                                                symbol: browser.destination.symbol)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: browser.destination == .artists ? 80 : 10))
                        Text(group.title).font(.headline).lineLimit(1)
                        Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help(group.title)
                .id("group:\(group.id)")
            }
        }
        .scrollTargetLayout()
    }

    private var folderRows: some View {
        VStack(spacing: 0) {
            ForEach(browser.childPlaylists) { playlist in
                Button { page = .music(.playlist(playlist.id)) } label: {
                    Label(playlist.name, systemImage: playlist.isFolder ? "folder" : "music.note.list")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                Divider()
            }
            if browser.childPlaylists.isEmpty {
                Text("这个文件夹中没有可读取的播放列表。")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
        }
    }

    private var syncFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !browser.isFolder {
                Text(browser.isPartial
                     ? "正在同步 \(browser.tracks.count) / \(browser.totalCount) 首 · 搜索与分类将自动补全"
                     : "已同步 \(browser.tracks.count) 首 · 来自「音乐」App")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if browser.hasMore {
                    Button(browser.isLoading ? "正在同步……" : "继续同步歌曲") { browser.loadMore() }
                        .disabled(browser.isLoading)
                }
            }
        }
        .padding(.top, 24)
    }

    private func recoverableMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout)
            HStack {
                Button("重试") { browser.reload() }.disabled(browser.isLoading)
                Button("自动化权限设置") { model.openAutomationSettings() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.orange.opacity(0.10))
    }
}
