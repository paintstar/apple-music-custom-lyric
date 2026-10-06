import AppKit
import Foundation
import ShinAppleKit
import ShinMusicScript

// 封面仓库：persistent ID 为键的进程内缓存 + 每曲目一次后台取图。
// - 只在曲目键变化时取图（切歌才更新）；缓存命中直接展示，不重发脚本；
// - 取图在后台任务完成：封面脚本读取（适配器执行锁内，与采样串行）与
//   NSImage → CGImage 转换都不占主线程；跨隔离只传 Sendable 的 CGImage；
// - 有效性检查：迟到结果（读取期间切歌）按曲目录键双重校验丢弃，
//   绝不覆盖新曲目的占位状态（epoch + seq 防旧覆盖新的一般规则）；
// - 取不到封面（Mock / 无封面能力执行器 / 曲目无封面 / 读取失败）→
//   currentArtwork 为 nil，界面用「封面主色渐变占位」，不阻塞核心功能。
@MainActor
final class ArtworkStore: ObservableObject {

    /// 当前曲目封面；nil = 无封面（UI 显示渐变占位）。
    @Published private(set) var currentArtwork: NSImage?

    /// 进程内缓存（曲目录键 → 封面）。上限 24 张：本地使用场景足够，
    /// 超出由 NSCache 淘汰，取图成本仅为一次脚本读取。
    private let cache = NSCache<NSString, NSImage>()
    /// 最近一次发起取图的曲目键（nil = 尚无曲目 / 无可定位身份）。
    private var lastRequestedTrackKey: String?
    private var fetchTask: Task<Void, Never>?

    init() {
        cache.countLimit = 24
    }

    /// 快照驱动的封面更新入口（主线程；由 AppModel 订阅回调转发）。
    func handleTrackChange(_ snapshot: PlaybackSnapshot, controller: PlaybackController) {
        guard let trackKey = snapshot.trackKey else {
            lastRequestedTrackKey = nil
            fetchTask?.cancel()
            currentArtwork = nil
            return
        }
        guard trackKey != lastRequestedTrackKey else { return }
        lastRequestedTrackKey = trackKey
        if let cached = cache.object(forKey: trackKey as NSString) {
            currentArtwork = cached
            return
        }
        // 先落占位（渐变背景由视图层按 nil 呈现），不闪旧曲目封面。
        currentArtwork = nil
        fetchTask?.cancel()
        let expectedTrackKey = trackKey
        fetchTask = Task { [weak self] in
            // 后台：脚本读取（执行锁内同批身份校验）→ CGImage（Sendable 跨隔离）。
            let fetched: (trackKey: String, cgImage: CGImage)? = await Task.detached(
                priority: .utility
            ) { [controller] in
                guard let scriptController = controller as? MusicScriptPlaybackController,
                      let result = scriptController.fetchCurrentTrackArtwork() else { return nil }
                let key = SongBinding.trackKey(persistentID: result.persistentID)
                guard let cgImage = result.image.cgImage(
                    forProposedRect: nil, context: nil, hints: nil
                ) else { return nil }
                return (key, cgImage)
            }.value
            guard let self, !Task.isCancelled, let fetched else { return }
            // 迟到结果不覆盖新曲目：请求目标与当前目标一致才应用。
            guard fetched.trackKey == expectedTrackKey,
                  fetched.trackKey == self.lastRequestedTrackKey else { return }
            let image = NSImage(
                cgImage: fetched.cgImage,
                size: NSSize(width: fetched.cgImage.width, height: fetched.cgImage.height)
            )
            self.cache.setObject(image, forKey: fetched.trackKey as NSString)
            self.currentArtwork = image
        }
    }
}
