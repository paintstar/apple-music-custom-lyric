import Testing
import Foundation
import ShinAppleKit
@testable import ShinMusicScript

// MARK: - 纯映射测试（秒→毫秒、状态、错误、trackRef 解析）

struct MusicScriptMappingTests {

    @Test("秒→毫秒：词典 float32 秒按毫秒精度换算")
    func secondsToMsConvertsRounded() {
        #expect(MusicScriptMapping.secondsToMs(123.871002197266) == 123_871)
        #expect(MusicScriptMapping.secondsToMs(106.773002624512) == 106_773)
        #expect(MusicScriptMapping.secondsToMs(0.9995) == 1_000)
        #expect(MusicScriptMapping.secondsToMs(0) == 0)
    }

    @Test("秒→毫秒：非有限值 → nil（未知不是 0）；负值按起点噪声裁到 0")
    func secondsToMsHandlesUnknownAndNegative() {
        #expect(MusicScriptMapping.secondsToMs(Double.nan) == nil)
        #expect(MusicScriptMapping.secondsToMs(Double.infinity) == nil)
        #expect(MusicScriptMapping.secondsToMs(Double.greatestFiniteMagnitude) == nil)
        #expect(MusicScriptMapping.secondsToMs(-0.001) == 0)
        #expect(MusicScriptMapping.secondsToMs(-5) == 0)
    }

    @Test("状态码映射：词典五枚举 → domain；未知/缺失返回 nil")
    func stateCodeMapping() {
        #expect(MusicScriptMapping.status(forStateCode: MusicScriptPlayerState.playing) == .playing)
        #expect(MusicScriptMapping.status(forStateCode: MusicScriptPlayerState.paused) == .paused)
        #expect(MusicScriptMapping.status(forStateCode: MusicScriptPlayerState.stopped) == .idle)
        #expect(
            MusicScriptMapping.status(forStateCode: MusicScriptPlayerState.fastForwarding) == .seeking
        )
        #expect(MusicScriptMapping.status(forStateCode: MusicScriptPlayerState.rewinding) == .seeking)
        #expect(MusicScriptMapping.status(forStateCode: nil) == nil)
        #expect(MusicScriptMapping.status(forStateCode: 12345) == nil)
    }

    @Test("执行器失败 → domain 错误：权限拒绝/未运行/定位不到/超时分类明确")
    func failureMapping() {
        #expect(
            MusicScriptMapping.playbackError(for: .permissionDenied) == PlaybackError.unauthorized
        )
        #expect(
            MusicScriptMapping.playbackError(for: .musicNotRunning) == PlaybackError.musicNotRunning
        )
        #expect(
            MusicScriptMapping.playbackError(for: .trackNotFound) == PlaybackError.trackUnavailable
        )
        #expect(
            MusicScriptMapping.playbackError(for: .timeout)
                == PlaybackError.unknown("music:timeout")
        )
        #expect(
            MusicScriptMapping.playbackError(for: .fieldUnavailable("name"))
                == PlaybackError.unknown("music:fieldUnavailable:name")
        )
    }

    @Test("Apple Event 错误码分类：-1743 权限、-1712 超时、-600 未运行、-1728 对象缺失")
    func appleEventCodeMapping() {
        #expect(
            MusicScriptErrorMapper.failure(appleEventCode: -1743, detail: "x")
                == .permissionDenied
        )
        #expect(MusicScriptErrorMapper.failure(appleEventCode: -1712, detail: "x") == .timeout)
        #expect(MusicScriptErrorMapper.failure(appleEventCode: -600, detail: "x") == .musicNotRunning)
        #expect(
            MusicScriptErrorMapper.failure(appleEventCode: -1728, detail: "currentTrack")
                == .fieldUnavailable("currentTrack")
        )
        #expect(MusicScriptErrorMapper.failure(appleEventCode: -1, detail: "x") == .unknown("-1:x"))
    }

    @Test("trackRef 解析：命名空间 + 十六进制白名单；其余拒绝")
    func trackRefParsing() {
        #expect(MusicScriptMapping.persistentID(fromTrackRef: Fixtures.refA) == Fixtures.pidA)
        // 错误命名空间（旧 catalog 前缀）拒绝：目录 ID 不是 persistent ID。
        #expect(MusicScriptMapping.persistentID(fromTrackRef: "apple-music:catalog:us:1") == nil)
        // 白名单外字符拒绝（注入面收敛）。
        #expect(MusicScriptMapping.persistentID(fromTrackRef: "music-script:persistent:AB$CD") == nil)
        #expect(
            MusicScriptMapping.persistentID(fromTrackRef: "music-script:persistent:") == nil
        )
        #expect(
            MusicScriptMapping.persistentID(fromTrackRef: String(repeating: "A", count: 65)) == nil
        )
    }
}

// MARK: - SongBinding v2 trackKey（契约侧回归）

struct TrackKeyV2Tests {

    @Test("v2 trackKey：music-script:persistent:<id> 命名空间；v1 目录键保持不变")
    func trackKeyNamespaces() {
        #expect(SongBinding.trackKey(persistentID: Fixtures.pidA) == "music-script:persistent:\(Fixtures.pidA)")
        let catalog = CatalogIdentity(storefront: "cn", catalogSongId: "123")
        #expect(
            SongBinding.trackKey(for: catalog) == "apple-music:catalog:cn:123"
        )
    }

    @Test("trackIdentity 解析：两个命名空间可解析；非法键 nil")
    func trackIdentityParsing() {
        let script = SongBinding.trackIdentity(fromTrackKey: Fixtures.refA)
        #expect(script == .scriptPersistentID(Fixtures.pidA))
        let catalog = SongBinding.trackIdentity(
            fromTrackKey: "apple-music:catalog:cn:123"
        )
        #expect(catalog == .catalog(CatalogIdentity(storefront: "cn", catalogSongId: "123")))
        #expect(SongBinding.trackIdentity(fromTrackKey: "no-namespace") == nil)
        #expect(SongBinding.trackIdentity(fromTrackKey: "music-script:persistent:AB$") == nil)
        #expect(
            SongBinding.trackIdentity(fromTrackKey: "apple-music:catalog:cn:") == nil
        )
    }

    @Test("v1 目录身份仍可自动播放定位属旧路线；v2 历史绑定语义：保留资料、不可自动定位")
    func scriptBindingConstruction() {
        let documentId = UUID()
        let binding = SongBinding(
            persistentID: Fixtures.pidA,
            lyricDocumentId: documentId,
            titleHint: "测试曲目甲"
        )
        #expect(binding.track == nil)
        #expect(binding.persistentID == Fixtures.pidA)
        #expect(binding.trackKey == Fixtures.refA)
    }
}
