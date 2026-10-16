import AppKit
import Foundation
import ShinAppleKit
import ShinMusicScript

// 封面仓库：persistent ID 为键的进程内缓存 + 每曲目有限后台取图。
// - 曲目键变化时发起取图；暂不可用时有限重试，缓存命中直接展示；
// - 取图在后台任务完成：独立封面实例读取与
//   NSImage → CGImage 转换都不占主线程；跨隔离只传 Sendable 的 CGImage；
// - 有效性检查：迟到结果（读取期间切歌）按曲目录键双重校验丢弃，
//   绝不覆盖新曲目的占位状态（epoch + seq 防旧覆盖新的一般规则）；
// - 取不到封面（Mock / 无封面能力执行器 / 曲目无封面 / 读取失败）→
//   currentArtwork 为 nil，界面用「封面主色渐变占位」，不阻塞核心功能。
@MainActor
final class ArtworkStore: ObservableObject {
    struct FetchedArtwork: Sendable {
        let trackKey: String
        let cgImage: CGImage
    }

    typealias Loader = @Sendable (PlaybackController) async -> FetchedArtwork?

    /// 当前曲目封面；nil = 无封面（UI 显示渐变占位）。
    @Published private(set) var currentArtwork: NSImage?

    /// 进程内缓存（曲目录键 → 封面）。上限 24 张：本地使用场景足够，
    /// 超出由 NSCache 淘汰，取图成本仅为一次脚本读取。
    private let cache = NSCache<NSString, NSImage>()
    /// 最近一次发起取图的曲目键（nil = 尚无曲目 / 无可定位身份）。
    private var lastRequestedTrackKey: String?
    private var fetchTask: Task<Void, Never>?
    private let retryDelays: [Duration]
    private let load: Loader

    init(retryDelays: [Duration] = ArtworkLoadingPolicy.retryDelays,
         load: @escaping Loader = ArtworkStore.loadArtwork) {
        self.retryDelays = retryDelays
        self.load = load
        cache.countLimit = 24
    }

    deinit { fetchTask?.cancel() }

    /// 快照驱动的封面更新入口（主线程；由 AppModel 订阅回调转发）。
    func handleTrackChange(_ snapshot: PlaybackSnapshot, controller: PlaybackController) {
        guard let trackKey = snapshot.trackKey else {
            lastRequestedTrackKey = nil
            fetchTask?.cancel()
            fetchTask = nil
            currentArtwork = nil
            return
        }
        guard trackKey != lastRequestedTrackKey else { return }
        lastRequestedTrackKey = trackKey
        fetchTask?.cancel()
        if let cached = cache.object(forKey: trackKey as NSString) {
            currentArtwork = cached
            return
        }
        // 先落占位（渐变背景由视图层按 nil 呈现），不闪旧曲目封面。
        currentArtwork = nil
        let expectedTrackKey = trackKey
        let retryDelays = retryDelays
        let load = load
        fetchTask = Task { [weak self] in
            for attempt in 0...retryDelays.count {
                if attempt > 0 {
                    do { try await Task.sleep(for: retryDelays[attempt - 1]) } catch { return }
                }
                guard !Task.isCancelled else { return }
                let fetched = await load(controller)
                guard !Task.isCancelled else { return }
                guard let fetched, fetched.trackKey == expectedTrackKey else { continue }
                guard let self, fetched.trackKey == self.lastRequestedTrackKey else { return }
                let image = NSImage(
                    cgImage: fetched.cgImage,
                    size: NSSize(width: fetched.cgImage.width, height: fetched.cgImage.height)
                )
                self.cache.setObject(image, forKey: fetched.trackKey as NSString)
                self.currentArtwork = image
                return
            }
        }
    }

    nonisolated private static func loadArtwork(controller: PlaybackController) async -> FetchedArtwork? {
        // 取消传播给后台任务，排队等待取图时取消的旧请求不会再读 Music。
        let request = Task.detached(priority: .utility) { [controller] () -> FetchedArtwork? in
            guard !Task.isCancelled, let scriptController = controller as? MusicScriptPlaybackController,
                  let result = scriptController.fetchCurrentTrackArtwork(shouldCancel: { Task.isCancelled }),
                  !Task.isCancelled else { return nil }
            let key = SongBinding.trackKey(persistentID: result.persistentID)
            guard let cgImage = result.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return FetchedArtwork(trackKey: key, cgImage: cgImage)
        }
        return await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }
}
