import SwiftUI
import ShinAppleKit

/// 列表行的稳定字符串 id（与 CatalogIdentity 相等语义一致；
/// SwiftUI List/ForEach 的 id 键路径要求 Hashable，域模型保持最小契约不动）。
extension SongSummary {
    var identityKey: String {
        "\(identity.storefront)/\(identity.catalogSongId)"
    }
}

// 正在播放页（Apple Music macOS Now Playing 式）：
// - 铺底：封面高斯模糊 + 暗色遮罩（无封面/Mock 走渐变占位，不参与动画）；
// - 主区：大封面（左）+ 歌名/歌手 + 歌词区（右，复用歌词面板全部状态机）；
// - 顶部：状态横幅（初始化/授权被拒/失败）与环境提示（Music 未运行/无曲目）；
// - Mock 模式：搜索选歌区保留在本页顶部（Mock 同样享受新视觉与渐变占位）。
// 文字在暗色遮罩上恒为浅色（两种系统外观下对比度一致），侧边栏/设置页
// 仍跟随系统明暗。

struct NowPlayingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var artworkStore: ArtworkStore
    @State private var isMockSearchExpanded = false

    var body: some View {
        ZStack {
            ArtworkBackdrop(artwork: artworkStore.currentArtwork, trackKey: model.snapshot.trackKey)
            VStack(spacing: 0) {
                PlaybackStatusView()
                if model.isSearchAvailable {
                    mockSearchSection
                        .padding(.horizontal, 28)
                }
                // GeometryReader 只读取状态/搜索区分配后剩余的高度。
                GeometryReader { geometry in
                    HStack(spacing: max(28, geometry.size.width * 0.045)) {
                        coverColumn
                            .frame(width: min(360, geometry.size.width * 0.38))
                        LyricsPanelView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(height: geometry.size.height)
                    .padding(.horizontal, max(28, geometry.size.width * 0.055))
                }
                .padding(.vertical, 24)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var coverColumn: some View {
        PlayerCoverColumnLayout {
            PlayerArtwork(artwork: artworkStore.currentArtwork, trackKey: model.snapshot.trackKey)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 14)
            VStack(spacing: 20) {
                PlayerTrackInfo()
                PlaybackControlsView()
            }
        }
    }

    // MARK: - Mock 搜索（仅模拟模式）

    @ViewBuilder
    private var mockSearchSection: some View {
        if model.isSearchAvailable {
            DisclosureGroup("模拟曲库搜索", isExpanded: $isMockSearchExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("搜索模拟曲库（输入关键词）", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                    if model.isSearching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("搜索中……")
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let message = model.searchMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    resultList
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// 模拟曲库结果列表（原 ContentView 结果列表：点击行装载并播放）。
    @ViewBuilder
    private var resultList: some View {
        if model.results.isEmpty {
            Text(model.lastSearchHadNoResults
                ? "没有找到与关键词匹配的歌曲。"
                : "输入关键词开始搜索；点击结果行播放。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.results, id: \.identityKey) { (song: SongSummary) in
                        resultRow(song)
                    }
                }
            }
            .frame(height: 100)
        }
    }

    private func resultRow(_ song: SongSummary) -> some View {
        Button {
            model.play(song)
            isMockSearchExpanded = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .help(song.title)
                    Text(song.artistName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(song.artistName)
                }
                Spacer()
                Text(formatDuration(song.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.selectedSong?.identity == song.identity {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.appleMusicPink)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatDuration(_ ms: Int64?) -> String {
        guard let ms, ms >= 0 else { return "--:--" }
        let totalSeconds = ms / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// 先测量歌曲信息与控制的真实高度，再把余下空间分配给正方形封面。
/// 字体、错误消息和窗口高度变化都不会靠猜测预留高度挤走播放按钮。
private struct PlayerCoverColumnLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let details = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let gap = min(56, max(16, bounds.height * 0.07))
        let side = min(320, bounds.width * 0.90, max(0, bounds.height - details.height - gap - 24))
        let top = bounds.minY + max(0, (bounds.height - side - gap - details.height) / 2)
        subviews[0].place(at: CGPoint(x: bounds.midX, y: top), anchor: .top,
                          proposal: ProposedViewSize(width: side, height: side))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: top + side + gap), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: details.height))
    }
}
