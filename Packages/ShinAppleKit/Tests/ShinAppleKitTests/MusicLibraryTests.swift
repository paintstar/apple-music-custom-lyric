import Foundation
import Testing
@testable import ShinAppleKit

struct MusicLibraryTests {
    @Test("Mock 资料库分页不漏曲目，非法分页拒绝，空歌单可区分")
    func pagesAndEmptyPlaylist() async throws {
        let player = MockPlaybackController()
        try await player.prepareMusicInBackground()
        let first = try await player.loadTracks(in: .library, offset: 0, limit: 2)
        let second = try await player.loadTracks(in: .library, offset: first.nextOffset!, limit: 2)
        #expect(first.tracks + second.tracks == MockMusicLibrary.tracks)
        #expect(first.totalCount == 4 && second.nextOffset == nil)
        let empty = try await player.loadTracks(in: .playlist(id: "B000000000000004"), offset: 0, limit: 200)
        #expect(empty.tracks.isEmpty && empty.totalCount == 0 && empty.nextOffset == nil)
        await #expect(throws: MusicLibraryError.invalidRequest) {
            try await player.loadTracks(in: .library, offset: -1, limit: 200)
        }
        await #expect(throws: MusicLibraryError.invalidRequest) {
            try await player.loadTracks(in: .library, offset: 0, limit: Int.max)
        }
    }

    @Test("Mock 点歌保留原歌单上下文与脚本身份，下一首不会跳到资料库顺序")
    func playbackUsesPlaylistContext() async throws {
        let player = MockPlaybackController()
        let source = MusicLibrarySource.playlist(id: "B000000000000002")
        #expect(try await player.currentPlaybackSource() == nil)
        try await player.playTrack(MockMusicLibrary.tracks[1].trackRef, in: source)
        #expect(try await player.currentPlaybackSource() == source)
        #expect(player.snapshot().trackRef == MockMusicLibrary.tracks[1].trackRef)
        try await player.next()
        #expect(try await player.currentPlaybackSource() == source)
        #expect(player.snapshot().trackRef == MockMusicLibrary.tracks[3].trackRef)
        try await player.previous()
        #expect(player.snapshot().trackRef == MockMusicLibrary.tracks[1].trackRef)
        #expect(try await player.currentPlaybackSource() == source)
        await #expect(throws: MusicLibraryError.sourceUnavailable) {
            try await player.playTrack(MockMusicLibrary.tracks[2].trackRef, in: source)
        }
        #expect(player.snapshot().trackRef == MockMusicLibrary.tracks[1].trackRef)
        #expect(try await player.currentPlaybackSource() == source)
        player.setMockQueue([])
        #expect(try await player.currentPlaybackSource() == nil)
    }

    @Test("Mock 喜爱修改只影响指定曲目，刷新后保留；封面缺失不假造")
    func favoriteAndArtwork() async throws {
        let player = MockPlaybackController()
        let target = MockMusicLibrary.tracks[0].trackRef
        #expect(try await player.setFavorite(target, value: false) == false)
        let page = try await player.loadTracks(in: .library, offset: 0, limit: 200)
        #expect(page.tracks[0].isFavorite == false)
        #expect(page.tracks[2].isFavorite == true)
        #expect(try await player.artworkData(for: target) == nil)
        await #expect(throws: MusicLibraryError.sourceUnavailable) {
            try await player.setFavorite("untrusted-input", value: true)
        }
    }
}
