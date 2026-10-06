import Testing
import Foundation
import ShinAppleKit
@testable import ShinMusicScript

// MARK: - NSAppleScript 兜底路径的解析测试（描述符构造，不依赖真实 Music）

struct AppleScriptExecutorParsingTests {

    private static func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor(listDescriptor: ())
        // Apple Event 列表索引从 1 开始。
        for (index, item) in items.enumerated() {
            list.insert(item, at: index + 1)
        }
        return list
    }

    private static func okList(
        state: String = "playing",
        pid: String = Fixtures.pidA,
        title: String? = "测试曲目甲",
        artist: String? = "测试歌手乙",
        album: String? = "测试专辑丙",
        duration: NSAppleEventDescriptor = NSAppleEventDescriptor(double: 123.871002197266),
        position: NSAppleEventDescriptor = NSAppleEventDescriptor(double: 106.773002624512)
    ) -> NSAppleEventDescriptor {
        list([
            NSAppleEventDescriptor(string: "ok"),
            NSAppleEventDescriptor(string: state),
            NSAppleEventDescriptor(string: pid),
            title.map(NSAppleEventDescriptor.init(string:)) ?? NSAppleEventDescriptor.null(),
            artist.map(NSAppleEventDescriptor.init(string:)) ?? NSAppleEventDescriptor.null(),
            album.map(NSAppleEventDescriptor.init(string:)) ?? NSAppleEventDescriptor.null(),
            duration,
            position
        ])
    }

    @Test("快照列表解析：全字段读出；歌名含任意字符不受分隔符影响")
    func parsesFullSnapshot() {
        let descriptor = Self.okList(
            title: "测试曲目甲|带竖线 & emoji 🎵"
        )
        let outcome = AppleScriptExecutor.parseSnapshotList(descriptor)
        guard case .snapshot(let raw) = outcome else {
            Issue.record("应解析为 snapshot：\(outcome)")
            return
        }
        #expect(raw.playerStateCode == MusicScriptPlayerState.playing)
        #expect(raw.persistentID == Fixtures.pidA)
        #expect(raw.title == "测试曲目甲|带竖线 & emoji 🎵")
        #expect(raw.artist == "测试歌手乙")
        #expect(raw.album == "测试专辑丙")
        #expect(raw.durationSeconds == 123.871002197266)
        #expect(raw.positionSeconds == 106.773002624512)
    }

    @Test("快照列表解析：no-track 与 not-running 标记")
    func parsesSpecialMarkers() {
        let noTrack = Self.list([
            NSAppleEventDescriptor(string: "no-track"),
            NSAppleEventDescriptor(string: "paused")
        ])
        #expect(
            AppleScriptExecutor.parseSnapshotList(noTrack)
                == .noCurrentTrack(stateCode: MusicScriptPlayerState.paused)
        )
        #expect(
            AppleScriptExecutor.parseSnapshotList(NSAppleEventDescriptor(string: "not-running"))
                == .musicNotRunning
        )
    }

    @Test("快照列表解析：未知状态文本/项数错误 → 单字段不可用（不猜测）")
    func parsesFieldProblems() {
        let badState = Self.okList(state: "interdimensional")
        guard case .failed(let failure) = AppleScriptExecutor.parseSnapshotList(badState) else {
            Issue.record("应解析为 failed")
            return
        }
        #expect(failure == .fieldUnavailable("playerState"))

        let shortList = Self.list([
            NSAppleEventDescriptor(string: "ok"),
            NSAppleEventDescriptor(string: "playing")
        ])
        guard case .failed(let countFailure) = AppleScriptExecutor.parseSnapshotList(shortList) else {
            Issue.record("应解析为 failed")
            return
        }
        #expect(countFailure.errorCode.hasPrefix("music:fieldUnavailable:snapshot:"))
    }

    @Test("快照列表解析：nil 描述符 / 意外文本 → unknown")
    func parsesGarbage() {
        if case .failed(.unknown) = AppleScriptExecutor.parseSnapshotList(nil) {
        } else {
            Issue.record("nil 应解析为 failed(unknown)")
        }
        if case .failed(.unknown) = AppleScriptExecutor.parseSnapshotList(
            NSAppleEventDescriptor(string: "bogus")
        ) {
        } else {
            Issue.record("意外文本应解析为 failed(unknown)")
        }
    }

    @Test("整流测试：解析产物经控制器换算后位置/时长为整数毫秒")
    func parsedSnapshotFeedsController() {
        let executor = AppleScriptExecutor()
        _ = executor // 兜底执行器可正常构造（不触发真实脚本执行）
        let outcome = AppleScriptExecutor.parseSnapshotList(Self.okList())
        guard case .snapshot(let raw) = outcome, let position = raw.positionSeconds,
              let duration = raw.durationSeconds else {
            Issue.record("应解析为带数值字段的 snapshot")
            return
        }
        #expect(MusicScriptMapping.secondsToMs(position) == 106_773)
        #expect(MusicScriptMapping.secondsToMs(duration) == 123_871)
    }
}

// MARK: - SB 执行器构造与词典常量（不依赖真实 Music 事件）

struct ExecutorConstructionTests {

    @Test("ScriptingBridge 执行器可构造（目标 Music bundle id；不拉起应用）")
    func sbExecutorConstructs() {
        let executor = ScriptingBridgeExecutor()
        // 真实事件行为属 MANUAL 验证；此处仅验证构造与白名单常量。
        #if DEBUG
        _ = executor.isAvailable // SBApplication 构造在本机应成功
        #endif
        #expect(ScriptingBridgeExecutor.musicBundleIdentifier == "com.apple.Music")
    }

    @Test("player state FourCharCode 与 Music 脚本词典一致")
    func stateCodeConstants() {
        #expect(MusicScriptPlayerState.playing == 1_800_426_320) // 'kPSP'
        #expect(MusicScriptPlayerState.paused == 1_800_426_352) // 词典枚举 'kPSp'
        #expect(MusicScriptPlayerState.fromAppleScriptText("playing") == MusicScriptPlayerState.playing)
        #expect(MusicScriptPlayerState.fromAppleScriptText("paused") == MusicScriptPlayerState.paused)
        #expect(MusicScriptPlayerState.fromAppleScriptText("stopped") == MusicScriptPlayerState.stopped)
        #expect(
            MusicScriptPlayerState.fromAppleScriptText("fast forwarding")
                == MusicScriptPlayerState.fastForwarding
        )
        #expect(MusicScriptPlayerState.fromAppleScriptText("rewinding") == MusicScriptPlayerState.rewinding)
        #expect(MusicScriptPlayerState.fromAppleScriptText("unknown-state") == nil)
        #expect(MusicScriptPlayerState.describe(1) == "unknown(1)")
    }
}
