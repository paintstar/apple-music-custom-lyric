import AppKit
import CoreServices
import Foundation
import ShinAppleKit
import Testing
@testable import ShinMusicScript

struct ArtworkCacheTests {
    @Test("短期缺失合并重复请求，过期后能读取已准备好的封面", arguments: [false, true])
    func unavailableArtworkCanRecover(invalidBytes: Bool) async throws {
        let data = makeArtworkData()
        let reader = ArtworkCacheReader(first: invalidBytes ? Data("invalid-image".utf8) : nil, later: data)
        let clock = ArtworkCacheClock()
        let cache = MusicLibraryCache(reader: reader, artworkNow: { clock.now })
        #expect(try await cache.artworkData(for: trackRef) == nil)
        #expect(try await cache.artworkData(for: trackRef) == nil)
        #expect(reader.reads == 1)
        clock.advance()
        #expect(try await cache.artworkData(for: trackRef) == data)
        #expect(try await cache.artworkData(for: trackRef) == data)
        #expect(reader.reads == 2)
    }

    @Test("主资料库的缺失不阻止真实歌单成员封面，脚本保持真实来源")
    func playlistArtworkIsNotLimitedToLibrary() async throws {
        let reader = ArtworkCacheReader(first: nil, later: makeArtworkData())
        let cache = MusicLibraryCache(reader: reader)
        let source = MusicLibrarySource.playlist(id: "BB220002")
        #expect(try await cache.artworkData(for: trackRef) == nil)
        #expect(try await cache.artworkData(for: trackRef, in: source) != nil)
        #expect(reader.sources == [.library, source])
        let script = try MusicLibraryScriptSources.artwork(persistentID: "AA110001", in: source)
        #expect(script.contains("user playlist") && script.contains("BB220002"))
        #expect(!script.contains("library playlist"))
        #expect(!script.contains("count of") && !script.contains("set targetTrack"))
        try await MusicScriptTestExecution.compile(script)
    }

    @Test("封面仅接受SDK已知二进制图像描述符，未知或过大数据保持缺失")
    func artworkDescriptorFormats() throws {
        let data = makeArtworkData()
        for type: DescType in [typeData, typeTIFF, typeJPEG, typeGIF, typePict] {
            let descriptor = try #require(NSAppleEventDescriptor(descriptorType: type, data: data))
            #expect(AppleScriptMusicLibraryReader.artworkData(from: descriptor) == data)
        }
        #expect(AppleScriptMusicLibraryReader.artworkData(from: NSAppleEventDescriptor(string: "not-image")) == nil)
        let empty = try #require(NSAppleEventDescriptor(descriptorType: typeData, data: Data()))
        #expect(AppleScriptMusicLibraryReader.artworkData(from: empty) == nil)
        let oversized = try #require(NSAppleEventDescriptor(descriptorType: typeData, data: Data(count: 8 * 1_024 * 1_024 + 1)))
        #expect(AppleScriptMusicLibraryReader.artworkData(from: oversized) == nil)
    }

    @Test("多个可见位置同时请求同一封面只读取一次")
    func duplicateRequestsShareSerializedCache() async throws {
        let data = makeArtworkData()
        let reader = ArtworkCacheReader(first: data, later: data)
        let cache = MusicLibraryCache(reader: reader)
        try await withThrowingTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { try await cache.artworkData(for: trackRef) } }
            for try await value in group { #expect(value == data) }
        }
        #expect(reader.reads == 1)
    }

    @Test("读取期间取消的图像不进入成功缓存")
    func cancellationDoesNotCacheArtwork() async throws {
        let data = makeArtworkData()
        let reader = ArtworkCacheReader(first: data, later: data, blocksFirst: true)
        defer { reader.release() }
        let cache = MusicLibraryCache(reader: reader)
        let request = Task { try await cache.artworkData(for: trackRef) }
        for _ in 0..<200 where reader.reads == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reader.reads == 1)
        request.cancel()
        reader.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await cache.artworkData(for: trackRef) == data)
        #expect(reader.reads == 2)
    }
}

private final class ArtworkCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { current } }
    func advance() { lock.withLock { current = current.advanced(by: .seconds(1)) } }
}

private let trackRef = SongBinding.trackKey(persistentID: "AA110001")

private func makeArtworkData() -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.5, blue: 0.8, alpha: 1), atX: 0, y: 0)
    return bitmap.representation(using: .png, properties: [:])!
}

private final class ArtworkCacheReader: MusicLibraryScriptReading, @unchecked Sendable {
    private let condition = NSCondition()
    private let first: Data?
    private let later: Data?
    private let blocksFirst: Bool
    private var released = false
    private var recordedSources: [MusicLibrarySource] = []

    init(first: Data?, later: Data?, blocksFirst: Bool = false) {
        self.first = first
        self.later = later
        self.blocksFirst = blocksFirst
    }

    var reads: Int { condition.withLock { recordedSources.count } }
    var sources: [MusicLibrarySource] { condition.withLock { recordedSources } }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func readPlaylists(cancellation: MusicLibraryCancellation) throws -> [MusicLibraryPlaylist] { [] }
    func readTracks(in source: MusicLibrarySource, cancellation: MusicLibraryCancellation) throws -> [MusicLibraryTrack] { [] }

    func artworkData(persistentID: String, in source: MusicLibrarySource, cancellation: MusicLibraryCancellation) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        recordedSources.append(source)
        let isFirst = recordedSources.count == 1
        while isFirst && blocksFirst && !released { condition.wait() }
        return isFirst ? first : later
    }
}
