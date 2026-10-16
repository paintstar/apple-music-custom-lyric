import AppKit
import Foundation
import SwiftUI
import ShinAppleKit

/// 原创图像、内存服务与可控迟到结果，不发送 Music Apple Events。
enum ArtworkUICheck {
    @MainActor static func runChecks() async throws {
        try await checkRetryAndCache()
        try await checkRetryLimitAndCancellation()
        try await checkLateResult()
        try await checkVisibleSourceAndRefresh()
        print("PASS 封面：缺失恢复、有限重试、成功缓存、切歌取消、迟到保护、真实来源和刷新重试")
    }

    private static func require(_ condition: Bool, _ message: String = "封面回归断言失败") {
        precondition(condition, message)
    }

    @MainActor private static func eventually(_ message: String, _ predicate: () async -> Bool) async throws {
        for _ in 0..<600 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure(message)
    }

    @MainActor private static func checkRetryAndCache() async throws {
        let fixture = ArtworkFixture(outputs: [nil, image(for: "AA110001"), nil])
        let store = ArtworkStore(retryDelays: [.milliseconds(10), .milliseconds(20)]) { _ in await fixture.load() }
        let controller = MockPlaybackController()
        let first = snapshot("AA110001")
        store.handleTrackChange(first, controller: controller)
        try await eventually("首次缺失后应补试并恢复封面") { store.currentArtwork != nil }
        require(await fixture.readCount == 2)
        for _ in 0..<20 { store.handleTrackChange(first, controller: controller) }
        try await Task.sleep(for: .milliseconds(30))
        require(await fixture.readCount == 2, "同曲快照不能重发成功封面查询")
        store.handleTrackChange(snapshot("BB220002"), controller: controller)
        try await eventually("切歌应开始新读取") { await fixture.readCount == 3 }
        store.handleTrackChange(first, controller: controller)
        require(store.currentArtwork != nil, "返回已缓存曲目应直接显示")
        try await Task.sleep(for: .milliseconds(40))
        require(await fixture.readCount == 3, "命中缓存也必须取消上一首待重试请求")
    }

    @MainActor private static func checkRetryLimitAndCancellation() async throws {
        let fixture = ArtworkFixture(outputs: [])
        let store = ArtworkStore(retryDelays: [.milliseconds(10), .milliseconds(10)]) { _ in await fixture.load() }
        let controller = MockPlaybackController()
        let first = snapshot("AA110001")
        store.handleTrackChange(first, controller: controller)
        try await eventually("缺失封面应完成有限补试") { await fixture.readCount == 3 }
        for _ in 0..<30 { store.handleTrackChange(first, controller: controller) }
        try await Task.sleep(for: .milliseconds(40))
        require(await fixture.readCount == 3, "稳定缺失不能被播放采样反复触发")
        store.handleTrackChange(snapshot("BB220002"), controller: controller)
        try await eventually("第二首应独立开始读取") { await fixture.readCount == 4 }
        store.handleTrackChange(PlaybackSnapshot(), controller: controller)
        try await Task.sleep(for: .milliseconds(40))
        require(await fixture.readCount == 4 && store.currentArtwork == nil, "清空曲目应取消后续补试")
    }

    @MainActor private static func checkLateResult() async throws {
        let fixture = ArtworkFixture(outputs: [image(for: "AA110001"), image(for: "BB220002")], suspendsFirst: true)
        let store = ArtworkStore(retryDelays: []) { _ in await fixture.load() }
        let controller = MockPlaybackController()
        store.handleTrackChange(snapshot("AA110001"), controller: controller)
        try await eventually("旧请求应暂停") { await fixture.readCount == 1 }
        store.handleTrackChange(snapshot("BB220002"), controller: controller)
        try await eventually("新曲目封面应先显示") { store.currentArtwork != nil }
        let secondImage = store.currentArtwork
        await fixture.releaseFirst()
        try await Task.sleep(for: .milliseconds(30))
        require(store.currentArtwork === secondImage, "已取消旧请求即使迟到也不能覆盖新封面")
        store.handleTrackChange(PlaybackSnapshot(), controller: controller)
    }

    @MainActor private static func checkVisibleSourceAndRefresh() async throws {
        let service = ArtworkBrowsingFixture()
        let suite = "ShinAppleArtworkCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = MusicLibraryBrowserModel(service: service, sortDefaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 60, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MusicLibraryArtworkView(browser: browser, trackRef: artworkTrack.trackRef))
        window.orderBack(nil)
        defer { window.close(); browser.cancelForTermination() }
        try await eventually("可见封面应从资料库发起请求") { await service.sources.count == 1 }
        let version = browser.artworkRequestVersion
        browser.reload()
        require(browser.artworkRequestVersion == version + 1)
        try await eventually("相同曲目仍挂载时刷新应重启封面请求") { await service.sources.count == 2 }
        browser.select(.playlist("BB220002"))
        try await eventually("同曲目换来源也应重新请求") { await service.sources.last == .playlist(id: "BB220002") }
        let otherSource = MusicLibrarySource.playlist(id: "CC330003")
        _ = await browser.artworkData(for: artworkTrack.trackRef, in: otherSource)
        require(await service.sources.last == otherSource, "当前列表显式来源不能被浏览目的地覆盖")
        let count = await service.sources.count
        browser.cancelForTermination()
        _ = await browser.artworkData(for: artworkTrack.trackRef, in: otherSource)
        require(await service.sources.count == count, "终止后不能继续发送封面请求")
    }

    private static func snapshot(_ id: String) -> PlaybackSnapshot {
        PlaybackSnapshot(trackEpoch: 1, title: "原创封面测试", status: .playing,
                         trackRef: SongBinding.trackKey(persistentID: id))
    }

    nonisolated private static func image(for id: String) -> ArtworkStore.FetchedArtwork {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return ArtworkStore.FetchedArtwork(trackKey: SongBinding.trackKey(persistentID: id), cgImage: context.makeImage()!)
    }
}

private actor ArtworkFixture {
    private var outputs: [ArtworkStore.FetchedArtwork?]
    private let suspendsFirst: Bool
    private var first: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0

    init(outputs: [ArtworkStore.FetchedArtwork?], suspendsFirst: Bool = false) {
        self.outputs = outputs
        self.suspendsFirst = suspendsFirst
    }

    func load() async -> ArtworkStore.FetchedArtwork? {
        readCount += 1
        let output = outputs.isEmpty ? nil : outputs.removeFirst()
        if readCount == 1 && suspendsFirst { await withCheckedContinuation { first = $0 } }
        return output
    }

    func releaseFirst() { first?.resume(); first = nil }
}

private let artworkTrack = MusicLibraryTrack(persistentID: "AA110001", title: "原创封面测试")

private actor ArtworkBrowsingFixture: MusicLibraryBrowsing {
    private(set) var sources: [MusicLibrarySource] = []
    func prepareMusicInBackground() async throws {}
    func loadPlaylists() async throws -> [MusicLibraryPlaylist] { [] }
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        MusicLibraryTrackPage(tracks: [artworkTrack], totalCount: 1, nextOffset: nil)
    }
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {}
    func setFavorite(_ trackRef: String, value: Bool) async throws -> Bool { value }
    func artworkData(for trackRef: String, in source: MusicLibrarySource) async throws -> Data? {
        sources.append(source)
        return nil
    }
}
