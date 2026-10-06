import CoreServices
import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct MusicLibraryDescriptorTests {
    private func columns() -> [MusicLibraryScriptSources.TrackColumn: [NSAppleEventDescriptor]] {
        [
            .persistentID: [NSAppleEventDescriptor(string: Fixtures.pidA), NSAppleEventDescriptor(string: Fixtures.pidB)],
            .title: [NSAppleEventDescriptor(string: "原创|雨声\n\"新页\""), NSAppleEventDescriptor(string: "原创第二首")],
            .artist: [NSAppleEventDescriptor(string: "演示歌手"), .null()],
            .albumArtist: [NSAppleEventDescriptor(string: "演示合集"), .null()],
            .album: [NSAppleEventDescriptor(string: "沿途"), .null()],
            .duration: [NSAppleEventDescriptor(double: 123.4567), NSAppleEventDescriptor(double: .greatestFiniteMagnitude)],
            .favorite: [NSAppleEventDescriptor(boolean: false), .null()],
            .dateAdded: [NSAppleEventDescriptor(date: Date(timeIntervalSince1970: 1_700_000_000)), .null()]
        ]
    }

    @Test("批量列解析保留特殊字符/专辑艺人，未知字段不冒充 false/0")
    func parsesColumnsWithoutDelimiterLoss() throws {
        let input = columns()
        let tracks = try MusicLibraryDescriptorParser.tracks(columns: input, finalIDs: input[.persistentID]!)
        #expect(tracks.count == 2)
        #expect(tracks[0].title == "原创|雨声\n\"新页\"")
        #expect(tracks[0].albumArtist == "演示合集")
        #expect(tracks[0].durationMs == 123_457)
        #expect(tracks[0].isFavorite == false)
        #expect(tracks[0].dateAdded == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(tracks[1].durationMs == nil && tracks[1].isFavorite == nil && tracks[1].dateAdded == nil)
    }

    @Test("列长度变化、ID重排或非法ID拒绝整批，不拼错曲目数据")
    func rejectsMixedSnapshots() {
        var input = columns()
        let ids = input[.persistentID]!
        #expect(throws: MusicLibraryError.contentsChanged) {
            try MusicLibraryDescriptorParser.tracks(columns: input, finalIDs: Array(ids.reversed()))
        }
        input[.artist] = []
        #expect(throws: MusicLibraryError.contentsChanged) {
            try MusicLibraryDescriptorParser.tracks(columns: input, finalIDs: ids)
        }
        input = columns()
        input[.persistentID] = [NSAppleEventDescriptor(string: "not-a-persistent-id"), ids[1]]
        #expect(throws: MusicLibraryError.contentsChanged) {
            try MusicLibraryDescriptorParser.tracks(columns: input, finalIDs: input[.persistentID]!)
        }
    }

    @Test("公开脚本只允许固定字段/程序与十六进制身份，不接纳用户文本")
    func scriptInputsAreValidated() throws {
        let attack = "\" & do shell script \"example"
        #expect(throws: MusicLibraryError.invalidRequest) {
            try MusicLibraryScriptSources.trackColumn(.title, in: .playlist(id: attack))
        }
        #expect(throws: MusicLibraryError.invalidRequest) {
            try MusicLibraryScriptSources.play(persistentID: attack, in: .library)
        }
        #expect(throws: MusicLibraryError.invalidRequest) {
            try MusicLibraryScriptSources.favorite(persistentID: attack, value: true)
        }
        let source = try MusicLibraryScriptSources.play(persistentID: Fixtures.pidA, in: .playlist(id: Fixtures.pidB))
        #expect(source.contains("user playlists whose persistent ID"))
        #expect(source.contains("tracks of targetPlaylist whose persistent ID"))
        #expect(source.contains("with timeout of 4 seconds"))
        #expect(!source.contains("activate"))
    }
}

struct MusicLibraryCacheTests {
    @Test("内存分页复用单次一致快照，换源时旧后续页必须拒绝")
    func pagesUseOneSnapshot() async throws {
        let reader = LibraryReaderFixture()
        let cache = MusicLibraryCache(reader: reader)
        let first = try await cache.loadTracks(in: .library, offset: 0, limit: 2)
        let second = try await cache.loadTracks(in: .library, offset: 2, limit: 2)
        #expect(first.tracks + second.tracks == MockMusicLibrary.tracks)
        #expect(reader.reads == 1)
        _ = try await cache.loadTracks(in: .playlist(id: Fixtures.pidB), offset: 0, limit: 2)
        await #expect(throws: MusicLibraryError.contentsChanged) {
            try await cache.loadTracks(in: .library, offset: 2, limit: 2)
        }
    }

    @Test("切换来源取消旧批读取，串行队列继续新源且旧结果不覆盖后续页")
    func staleLoadCannotReplaceNewSource() async throws {
        let reader = LibraryReaderFixture(delayLibrary: true)
        defer { reader.release() }
        let cache = MusicLibraryCache(reader: reader)
        let first = Task { try await cache.loadTracks(in: .library, offset: 0, limit: 2) }
        try await waitUntil { reader.reads > 0 }
        let nextSource = MusicLibrarySource.playlist(id: Fixtures.pidB)
        _ = try await cache.loadTracks(in: nextSource, offset: 0, limit: 2)
        reader.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        let next = try await cache.loadTracks(in: nextSource, offset: 2, limit: 2)
        #expect(next.tracks == Array(MockMusicLibrary.tracks.suffix(2)))
    }

    @Test("显式取消传入GCD读取工作，已取消结果不会成为分页缓存")
    func cancellationReachesReader() async throws {
        let reader = LibraryReaderFixture(delayLibrary: true)
        let cache = MusicLibraryCache(reader: reader)
        let request = Task { try await cache.loadTracks(in: .library, offset: 0, limit: 2) }
        try await waitUntil { reader.reads > 0 }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        await #expect(throws: MusicLibraryError.contentsChanged) {
            try await cache.loadTracks(in: .library, offset: 2, limit: 2)
        }
    }

    @Test("同步读取只占单条队列，已取消的排队封面不再调用读取器")
    func cancelledQueuedArtworkNeverReads() async throws {
        let reader = LibraryReaderFixture(delayLibrary: true)
        defer { reader.release() }
        let cache = MusicLibraryCache(reader: reader)
        let blocker = Task { try await cache.loadTracks(in: .library, offset: 0, limit: 2) }
        try await waitUntil { reader.reads > 0 }
        let artwork = Task { try await cache.artworkData(for: MockMusicLibrary.tracks[0].trackRef) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.artworkReads == 0)
        artwork.cancel()
        reader.release()
        _ = try await blocker.value
        await #expect(throws: CancellationError.self) { try await artwork.value }
        #expect(reader.artworkReads == 0)
    }

    @Test("无封面也缓存，喜爱设置以后端读回为准并修正当前分页缓存")
    func artworkAndFavoriteReadback() async throws {
        let reader = LibraryReaderFixture()
        let cache = MusicLibraryCache(reader: reader)
        let target = MockMusicLibrary.tracks[2].trackRef
        _ = try await cache.loadTracks(in: .library, offset: 0, limit: 2)
        #expect(try await cache.artworkData(for: target) == nil)
        #expect(try await cache.artworkData(for: target) == nil)
        #expect(reader.artworkReads == 1)
        #expect(try await cache.setFavorite(target, value: true) == false)
        let later = try await cache.loadTracks(in: .library, offset: 2, limit: 2)
        #expect(later.tracks.count == 2 && later.tracks[0].isFavorite == false)
        // 第二次读取 offset 0 会刷新，不用它验证已更新的缓存。
        #expect(reader.favoriteWrites == 1)
    }

    @Test("dispose 后库点播任务不得执行脚本")
    func disposedPlaybackDoesNotExecuteScript() async {
        let controller = MusicScriptPlaybackController(executor: FakeMusicScriptExecutor(), startsSampler: false)
        controller.dispose()
        await #expect(throws: CancellationError.self) {
            try await controller.performLibraryPlay("故意不可编译；必须在执行前取消")
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("后台读取未在测试时限内开始")
    }
}

private final class LibraryReaderFixture: MusicLibraryScriptReading, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var readCount = 0
    private var artworkReadCount = 0
    private var favoriteWriteCount = 0
    private let delayLibrary: Bool

    init(delayLibrary: Bool = false) { self.delayLibrary = delayLibrary }
    var reads: Int { lock.withLock { readCount } }
    var artworkReads: Int { lock.withLock { artworkReadCount } }
    var favoriteWrites: Int { lock.withLock { favoriteWriteCount } }
    func release() { lock.withLock { released = true } }
    func readPlaylists(cancellation: MusicLibraryCancellation) throws -> [MusicLibraryPlaylist] { MockMusicLibrary.playlists }

    func readTracks(in source: MusicLibrarySource, cancellation: MusicLibraryCancellation) throws -> [MusicLibraryTrack] {
        lock.withLock { readCount += 1 }
        if delayLibrary, source == .library {
            while !lock.withLock({ released }) {
                try cancellation.check()
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        return MockMusicLibrary.tracks
    }

    func artworkData(persistentID: String, cancellation: MusicLibraryCancellation) throws -> Data? {
        lock.withLock { artworkReadCount += 1 }
        return nil
    }

    func setFavorite(persistentID: String, value: Bool, cancellation: MusicLibraryCancellation) throws -> Bool {
        lock.withLock { favoriteWriteCount += 1 }
        return false // 故意模拟后端拒绝保持喜爱，验证调用方以读回值为准。
    }
}
