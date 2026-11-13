import CoreServices
import Foundation
import Testing
import ShinAppleKit
@testable import ShinMusicScript

struct AudioFileImportTests {
    @Test("POSIX 安全路径校验接受规范导入路径（含中文/空格父目录），拒绝注入与非法文件名")
    func safePOSIXPathValidation() {
        let validUUIDPath = "/tmp/shin-import-\(UUID().uuidString).m4a"
        let validChineseParent = "/Users/demo/音乐 学习/ImportedAudio/shin-import-1234_A.M4A"
        #expect(MusicLibraryScriptSources.isSafePOSIXFilePath(validUUIDPath))
        #expect(MusicLibraryScriptSources.isSafePOSIXFilePath(validChineseParent))

        let rejected = [
            "relative/shin-import-1.m4a",
            "/tmp/shin-import-1.mp3",
            "/tmp/shin-import-1.m4a/",
            "/tmp/.m4a",
            "/tmp/测试音频.m4a",
            "/tmp/has space.m4a",
            "/tmp/bad\"quote/shin-import-1.m4a",
            "/tmp/bad\\slash/shin-import-1.m4a",
            "/tmp/bad\nline/shin-import-1.m4a",
            "/tmp/bad\rreturn/shin-import-1.m4a",
            "/tmp/bad\0null/shin-import-1.m4a",
            "/tmp/bad\u{0007}bell/shin-import-1.m4a"
        ]
        for path in rejected {
            #expect(!MusicLibraryScriptSources.isSafePOSIXFilePath(path), "预期拒绝路径：\(path)")
        }
    }

    @Test("导入音频脚本模板使用 15 秒超时并通过本机 Music 词典编译")
    func addAudioFileScriptCompiles() async throws {
        let source = MusicLibraryScriptSources.addAudioFile(posixPath: "/tmp/shin-import-001.m4a")
        #expect(source.contains("with timeout of 15 seconds"))
        #expect(source.contains("if application id \"com.apple.Music\" is not running then error number -600"))
        #expect(source.contains("add importedFile to library playlist 1"))
        try await MusicScriptTestExecution.compile(source)
    }

    @Test("8 元描述符正确解析为 MusicLibraryImportedTrack，非法响应或路径抛错")
    func parsesImportedTrackDescriptorAndRejectsInvalid() throws {
        let descriptor = NSAppleEventDescriptor(listDescriptor: ())
        descriptor.insert(NSAppleEventDescriptor(string: Fixtures.pidA), at: 1)
        descriptor.insert(NSAppleEventDescriptor(string: "测试导入曲目"), at: 2)
        descriptor.insert(NSAppleEventDescriptor(string: "演示歌手"), at: 3)
        descriptor.insert(NSAppleEventDescriptor(string: "演示专辑歌手"), at: 4)
        descriptor.insert(NSAppleEventDescriptor(string: "演示专辑"), at: 5)
        descriptor.insert(NSAppleEventDescriptor(double: 185.25), at: 6)
        descriptor.insert(NSAppleEventDescriptor(boolean: true), at: 7)
        descriptor.insert(NSAppleEventDescriptor(string: "/Users/demo/Music/Media/Track.m4a"), at: 8)

        let imported = try MusicLibraryDescriptorParser.importedTrack(
            descriptor,
            fallbackFilePath: "/tmp/shin-import-fallback.m4a"
        )
        #expect(imported.track.persistentID == Fixtures.pidA)
        #expect(imported.track.title == "测试导入曲目")
        #expect(imported.track.artist == "演示歌手")
        #expect(imported.track.albumArtist == "演示专辑歌手")
        #expect(imported.track.album == "演示专辑")
        #expect(imported.track.durationMs == 185_250)
        #expect(imported.track.isFavorite == true)
        #expect(imported.resolvedFileURL == URL(fileURLWithPath: "/Users/demo/Music/Media/Track.m4a").standardizedFileURL)

        let shortList = NSAppleEventDescriptor(listDescriptor: ())
        shortList.insert(NSAppleEventDescriptor(string: Fixtures.pidA), at: 1)
        #expect(throws: MusicScriptFailure.fieldUnavailable("library:importAudioFile")) {
            try MusicLibraryDescriptorParser.importedTrack(shortList, fallbackFilePath: "/tmp/shin-import-1.m4a")
        }

        let badIDList = NSAppleEventDescriptor(listDescriptor: ())
        badIDList.insert(NSAppleEventDescriptor(string: "not-hex-id"), at: 1)
        for index in 2...8 {
            badIDList.insert(NSAppleEventDescriptor(string: ""), at: index)
        }
        #expect(throws: MusicScriptFailure.fieldUnavailable("library:importAudioFile")) {
            try MusicLibraryDescriptorParser.importedTrack(badIDList, fallbackFilePath: "/tmp/shin-import-1.m4a")
        }

        #expect(throws: MusicScriptFailure.fieldUnavailable("library:list")) {
            try MusicLibraryDescriptorParser.importedTrack(
                NSAppleEventDescriptor(string: "not-a-list"),
                fallbackFilePath: "/tmp/shin-import-1.m4a"
            )
        }

        let reader = AppleScriptMusicLibraryReader()
        #expect(throws: MusicLibraryError.invalidRequest) {
            try reader.importAudioFile(posixPath: "/tmp/非法名称.m4a", cancellation: MusicLibraryCancellation())
        }
    }

    @Test("MusicLibraryCache.importAudioFile 转发路径并使已有 library 缓存失效")
    func cacheImportForwardsAndInvalidatesLibrarySnapshot() async throws {
        let reader = ImportCacheReaderFixture()
        let cache = MusicLibraryCache(reader: reader)

        // 先装载一次 library 快照，建立分页缓存。
        let initialPage = try await cache.loadTracks(in: .library, offset: 0, limit: 2)
        #expect(initialPage.tracks.count == 2)
        #expect(reader.readCount == 1)

        // 非法 URL / 非法文件名拒绝。
        await #expect(throws: MusicLibraryError.invalidRequest) {
            try await cache.importAudioFile(at: URL(string: "https://example.com/a.m4a")!)
        }
        await #expect(throws: MusicLibraryError.invalidRequest) {
            try await cache.importAudioFile(at: URL(fileURLWithPath: "/tmp/中文名字.m4a"))
        }

        let targetURL = URL(fileURLWithPath: "/tmp/shin-import-test01.m4a")
        let imported = try await cache.importAudioFile(at: targetURL)
        #expect(reader.importedPaths == [targetURL.standardizedFileURL.path])
        #expect(imported.track.persistentID == Fixtures.pidA)

        // 缓存失效后，旧分页后续页被拒绝，offset 0 会触发重新读取。
        await #expect(throws: MusicLibraryError.contentsChanged) {
            try await cache.loadTracks(in: .library, offset: 2, limit: 2)
        }
        _ = try await cache.loadTracks(in: .library, offset: 0, limit: 2)
        #expect(reader.readCount == 2)
    }

    @Test("dispose 后控制器的 importAudioFile 不得执行脚本")
    func disposedControllerRejectsImport() async {
        let controller = MusicScriptPlaybackController(executor: FakeMusicScriptExecutor(), startsSampler: false)
        controller.dispose()
        await #expect(throws: CancellationError.self) {
            try await controller.importAudioFile(at: URL(fileURLWithPath: "/tmp/shin-import-test01.m4a"))
        }
    }
}

private final class ImportCacheReaderFixture: MusicLibraryScriptReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var paths: [String] = []

    var readCount: Int { lock.withLock { reads } }
    var importedPaths: [String] { lock.withLock { paths } }

    func readPlaylists(cancellation: MusicLibraryCancellation) throws -> [MusicLibraryPlaylist] {
        MockMusicLibrary.playlists
    }

    func readTracks(in source: MusicLibrarySource, cancellation: MusicLibraryCancellation) throws -> [MusicLibraryTrack] {
        lock.withLock { reads += 1 }
        return MockMusicLibrary.tracks
    }

    func importAudioFile(posixPath: String, cancellation: MusicLibraryCancellation) throws -> MusicLibraryImportedTrack {
        lock.withLock { paths.append(posixPath) }
        let track = MusicLibraryTrack(
            persistentID: Fixtures.pidA,
            title: "导入测试曲目",
            durationMs: 180_000,
            isFavorite: false,
            dateAdded: Date()
        )
        return MusicLibraryImportedTrack(
            track: track,
            resolvedFileURL: URL(fileURLWithPath: posixPath).standardizedFileURL
        )
    }
}
