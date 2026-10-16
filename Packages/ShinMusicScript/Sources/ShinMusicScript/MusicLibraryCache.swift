import AppKit
import Foundation
import ShinAppleKit

/// 内存中的单次资料库快照。分页只切同一份数组，刷新/换源时用代序号拒绝过期结果。
actor MusicLibraryCache {
    private let reader: any MusicLibraryScriptReading
    private let readQueue = DispatchQueue(label: "ShinMusicScript.library", qos: .utility)
    private var activeTrackRead: MusicLibraryCancellation?
    private var source: MusicLibrarySource?
    private var tracks: [MusicLibraryTrack] = []
    private var generation = 0
    private let artworkCache: LibraryArtworkCache

    init(reader: any MusicLibraryScriptReading = AppleScriptMusicLibraryReader(),
         artworkNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.reader = reader
        artworkCache = LibraryArtworkCache(now: artworkNow)
    }

    func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        let reader = reader
        return try await runCancellable { try reader.readPlaylists(cancellation: $0) }
    }

    func currentPlaybackSource() async throws -> MusicLibrarySource? {
        let reader = reader
        return try await runCancellable { try reader.currentPlaybackSource(cancellation: $0) }
    }

    /// 兼容单曲入口也必须取得真实来源的完整新快照；独立读取，不破坏浏览分页的缓存与代序号。
    func playbackTrackRefs(in requestedSource: MusicLibrarySource) async throws -> [String] {
        let reader = reader
        return try await runCancellable {
            try reader.readTracks(in: requestedSource, cancellation: $0).map(\.trackRef)
        }
    }

    func loadTracks(in requestedSource: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        guard offset >= 0, (1...500).contains(limit) else { throw MusicLibraryError.invalidRequest }
        try Task.checkCancellation()
        if offset == 0 {
            activeTrackRead?.cancel()
            let cancellation = MusicLibraryCancellation()
            activeTrackRead = cancellation
            defer { if activeTrackRead === cancellation { activeTrackRead = nil } }
            generation += 1
            let requestGeneration = generation
            source = nil
            tracks = []
            let reader = reader
            let loaded = try await runCancellable(cancellation: cancellation) {
                try reader.readTracks(in: requestedSource, cancellation: $0)
            }
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            tracks = loaded
            source = requestedSource
        }
        guard source == requestedSource else { throw MusicLibraryError.contentsChanged }
        let start = min(offset, tracks.count)
        let end = start + min(limit, tracks.count - start)
        return MusicLibraryTrackPage(tracks: Array(tracks[start..<end]), totalCount: tracks.count,
                                     nextOffset: end < tracks.count ? end : nil)
    }

    func artworkData(for trackRef: String, in source: MusicLibrarySource = .library) async throws -> Data? {
        guard let id = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else { throw MusicLibraryError.invalidRequest }
        try Task.checkCancellation()
        let key: String
        switch source {
        case .library: key = "library|\(trackRef)"
        case let .playlist(id): key = "playlist:\(id)|\(trackRef)"
        }
        let cache = artworkCache
        let reader = reader
        return try await runCancellable { cancellation in
            // 在串行读取队列中复查，合并同一行与分组封面的同时请求。
            if let existing = cache.value(for: key) { return existing.data }
            let raw = try reader.artworkData(persistentID: id, in: source, cancellation: cancellation)
            try cancellation.check()
            // 不能把无法解码的字节当作成功封面永久缓存。
            let data = raw.flatMap { NSImage(data: $0)?.isValid == true ? $0 : nil }
            try cancellation.check()
            cache.store(data, for: key)
            return data
        }
    }

    func setFavorite(_ trackRef: String, value: Bool, in source: MusicLibrarySource = .library) async throws -> Bool {
        guard let id = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else { throw MusicLibraryError.invalidRequest }
        let reader = reader
        let confirmed = try await runCancellable {
            try reader.setFavorite(persistentID: id, value: value, in: source, cancellation: $0)
        }
        for index in tracks.indices where tracks[index].trackRef == trackRef { tracks[index].isFavorite = confirmed }
        return confirmed
    }

    private func runCancellable<Value: Sendable>(
        cancellation: MusicLibraryCancellation = MusicLibraryCancellation(),
        _ operation: @escaping @Sendable (MusicLibraryCancellation) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                // 同步 Apple Events 只阻塞这一条 GCD 队列；排队任务不占 Swift 协作线程池。
                readQueue.async {
                    do {
                        try cancellation.check()
                        let result = try operation(cancellation)
                        try cancellation.check()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// GCD 闭包没有 Swift Task 上下文，字段间取消必须显式传递，不能依赖 Task.checkCancellation。
final class MusicLibraryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var cancellationHandlers: [@Sendable () -> Void] = []

    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let alreadyCancelled = lock.withLock {
            if isCancelled { return true }
            cancellationHandlers.append(handler)
            return false
        }
        if alreadyCancelled { handler() }
    }

    func cancel() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            guard !isCancelled else { return [] }
            isCancelled = true
            let handlers = cancellationHandlers
            cancellationHandlers.removeAll()
            return handlers
        }
        // 回调可释放其他锁或再次检查取消，不在本对象的锁内调用。
        handlers.forEach { $0() }
    }

    func check() throws {
        if lock.withLock({ isCancelled }) { throw CancellationError() }
    }
}

/// NSCache 自身保证线程安全，读取队列内复查与写入能合并重复视图请求。
private final class LibraryArtworkCache: @unchecked Sendable {
    private let entries = NSCache<NSString, CachedArtwork>()
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
        entries.countLimit = 24
        entries.totalCostLimit = 32 * 1_024 * 1_024
    }

    func value(for key: String) -> CachedArtwork? {
        guard let entry = entries.object(forKey: key as NSString), entry.isFresh(at: now()) else { return nil }
        return entry
    }

    func store(_ data: Data?, for key: String) {
        entries.setObject(CachedArtwork(data, now: now()), forKey: key as NSString, cost: data?.count ?? 1)
    }
}

/// 短暂合并缺失结果，不能把 Music 尚未准备好的云端封面永久当作无封面。
private final class CachedArtwork: NSObject, @unchecked Sendable {
    let data: Data?
    private let retryAfter: ContinuousClock.Instant?
    // 小于界面首次重试间隔（1 秒），抑制重复视图查询而不吞掉主动重试。
    private static let missingLifetime: Duration = .milliseconds(500)

    init(_ data: Data?, now: ContinuousClock.Instant) {
        self.data = data
        retryAfter = data == nil ? now.advanced(by: Self.missingLifetime) : nil
    }

    func isFresh(at now: ContinuousClock.Instant) -> Bool { retryAfter.map { now < $0 } ?? true }
}

/// 官方 NSWorkspace 打开方式：仅当 Music 尚未运行时启动，不激活窗口，不发播放命令。
@MainActor
enum MusicBackgroundLauncher {
    static func prepare() async throws {
        try Task.checkCancellation()
        let identifier = ScriptingBridgeExecutor.musicBundleIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            throw PlaybackError.initializationFailed("未找到「音乐」App。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try Task.checkCancellation()
    }
}

extension MusicScriptPlaybackController: MusicLibraryBrowsing {
    public func prepareMusicInBackground() async throws {
        try await MusicBackgroundLauncher.prepare()
    }

    public func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        do {
            return try await libraryCache.loadPlaylists()
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    public func currentPlaybackSource() async throws -> MusicLibrarySource? {
        do {
            return try await libraryCache.currentPlaybackSource()
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    public func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        do {
            return try await libraryCache.loadTracks(in: source, offset: offset, limit: limit)
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    public func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {
        guard MusicScriptMapping.persistentID(fromTrackRef: trackRef) != nil else {
            throw MusicLibraryError.invalidRequest
        }
        let trackRefs = try await libraryCache.playbackTrackRefs(in: source)
        try Task.checkCancellation()
        try await playTracks(trackRefs, startingAt: trackRef, in: source, shuffleEnabled: nil)
    }

    public func playTracks(_ trackRefs: [String], startingAt trackRef: String, in source: MusicLibrarySource,
                           shuffleEnabled: Bool?) async throws {
        let ids = try trackRefs.map { ref in
            guard let id = MusicScriptMapping.persistentID(fromTrackRef: ref) else { throw MusicLibraryError.invalidRequest }
            return id
        }
        guard let id = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else { throw MusicLibraryError.invalidRequest }
        try await performContextPlay(ids, startingAt: id, in: source, shuffleEnabled: shuffleEnabled)
    }

    public func shuffleTracks(_ trackRefs: [String], in source: MusicLibrarySource) async throws {
        let ids = try trackRefs.map { ref in
            guard let id = MusicScriptMapping.persistentID(fromTrackRef: ref) else { throw MusicLibraryError.invalidRequest }
            return id
        }
        try await performContextShuffle(ids, in: source)
    }

    /// 建立筛选列表时只占串行命令队列，各批次之间允许播放采样读取。
    func performContextPlay(_ ids: [String], startingAt id: String, in source: MusicLibrarySource,
                            shuffleEnabled: Bool?) async throws {
        try await performContextCommand { context, cancellation in
            try context.play(ids, startingAt: id, in: source, shuffleEnabled: shuffleEnabled, checkCancellation: cancellation)
        }
    }

    func performContextShuffle(_ ids: [String], in source: MusicLibrarySource) async throws {
        try await performContextCommand { context, cancellation in
            try context.shuffle(ids, in: source, checkCancellation: cancellation)
        }
    }

    public func artworkData(for trackRef: String) async throws -> Data? {
        try await artworkData(for: trackRef, in: .library)
    }

    public func artworkData(for trackRef: String, in source: MusicLibrarySource) async throws -> Data? {
        do {
            return try await libraryCache.artworkData(for: trackRef, in: source)
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    public func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool {
        try await setFavorite(trackRef, value: value, in: .library)
    }

    public func setFavorite(_ trackRef: String, value: Bool, in source: MusicLibrarySource) async throws -> Bool {
        do {
            return try await libraryCache.setFavorite(trackRef, value: value, in: source)
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }
}
