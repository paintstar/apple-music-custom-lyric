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
    private let artworkCache = NSCache<NSString, CachedArtwork>()

    init(reader: any MusicLibraryScriptReading = AppleScriptMusicLibraryReader()) {
        self.reader = reader
        artworkCache.countLimit = 24
        artworkCache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func loadPlaylists() async throws -> [MusicLibraryPlaylist] {
        let reader = reader
        return try await runCancellable { try reader.readPlaylists(cancellation: $0) }
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

    func artworkData(for trackRef: String) async throws -> Data? {
        guard let id = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else { throw MusicLibraryError.invalidRequest }
        try Task.checkCancellation()
        if let existing = artworkCache.object(forKey: trackRef as NSString) { return existing.data }
        let reader = reader
        let data = try await runCancellable { try reader.artworkData(persistentID: id, cancellation: $0) }
        artworkCache.setObject(CachedArtwork(data), forKey: trackRef as NSString, cost: data?.count ?? 1)
        return data
    }

    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool {
        guard let id = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else { throw MusicLibraryError.invalidRequest }
        let reader = reader
        let confirmed = try await runCancellable { try reader.setFavorite(persistentID: id, value: value, cancellation: $0) }
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

    func cancel() { lock.withLock { isCancelled = true } }

    func check() throws {
        if lock.withLock({ isCancelled }) { throw CancellationError() }
    }
}

/// 连缺失封面也缓存，避免无封面的可见行在布局变化时反复发送查询。
private final class CachedArtwork: NSObject {
    let data: Data?
    init(_ data: Data?) { self.data = data }
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

    public func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        do {
            return try await libraryCache.loadTracks(in: source, offset: offset, limit: limit)
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    public func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {
        guard let persistentID = MusicScriptMapping.persistentID(fromTrackRef: trackRef) else {
            throw MusicLibraryError.invalidRequest
        }
        try await performLibraryPlay(MusicLibraryScriptSources.play(persistentID: persistentID, in: source))
    }

    public func artworkData(for trackRef: String) async throws -> Data? {
        do {
            return try await libraryCache.artworkData(for: trackRef)
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }

    public func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool {
        do {
            return try await libraryCache.setFavorite(trackRef, value: value)
        } catch let failure as MusicScriptFailure {
            throw MusicScriptMapping.playbackError(for: failure)
        }
    }
}
