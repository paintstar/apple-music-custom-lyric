import SwiftUI
import ShinAppleKit

/// 歌曲资料库、学习资料与设置共用导航；完整播放器属于展示模式，不替代浏览位置。
enum SidebarPage: Hashable {
    case music(MusicLibraryDestination)
    case library
    case settings
}

struct SidebarView: View {
    static let width: CGFloat = 216
    @Binding var selection: SidebarPage
    @ObservedObject var browser: MusicLibraryBrowserModel
    @EnvironmentObject private var model: AppModel
    let onEditLyrics: () -> Void
    let onNowPlaying: () -> Void
    var topContentInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topContentInset + 12).accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    musicRow(.search)
                    sectionTitle("资料库")
                    musicRow(.recent)
                    musicRow(.artists)
                    musicRow(.albums)
                    musicRow(.songs)
                    musicRow(.favorites)
                    sectionTitle("播放列表")
                    if browser.playlists.isEmpty {
                        Text(browser.isLoading ? "正在读取播放列表……" : "暂无可读取的播放列表")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                    ForEach(browser.playlists) { playlist in
                        row(.music(.playlist(playlist.id)), title: playlist.name,
                            symbol: playlist.isFolder ? "folder" : "music.note.list")
                    }
                    sectionTitle("学习")
                    row(.library, title: "学习歌曲与备份", symbol: "text.book.closed")
                    actionRow("编辑当前歌词", symbol: "square.and.pencil", action: onEditLyrics)
                        .disabled(!model.canBeginLyricsEditing)
                    Divider().padding(.vertical, 10)
                    actionRow("完整播放器", symbol: "play.square", action: onNowPlaying)
                    row(.settings, title: "设置", symbol: "gearshape")
                    if model.isMock {
                        Label("模拟模式", systemImage: "ladybug")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
        }
        .background {
            VisualEffectBackground(material: .sidebar)
                .overlay {
                    LinearGradient(colors: [.blue.opacity(0.035), .teal.opacity(0.07)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.10), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .padding(8)
        .frame(width: Self.width)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }

    private func musicRow(_ destination: MusicLibraryDestination) -> some View {
        row(.music(destination), title: destination.title, symbol: destination.symbol)
    }

    private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title: title, symbol: symbol, isSelected: false)
        }
        .buttonStyle(.plain)
    }

    private func row(_ page: SidebarPage, title: String, symbol: String) -> some View {
        let isSelected = selection == page
        return Button { selection = page } label: {
            rowLabel(title: title, symbol: symbol, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(title)
    }

    private func rowLabel(title: String, symbol: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).frame(width: 20)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.body.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.appleMusicPink : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}
