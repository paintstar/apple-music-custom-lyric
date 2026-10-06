import AppKit
import Foundation
import ShinAppleKit
import ShinAppServices
import ShinMusicScript

// AppModel 的展示计算、确认后的歌词跟随与启动工厂；权威快照仍由 AppModel 维护。

// MARK: - 展示辅助

@MainActor
extension AppModel {
    struct SeekPresentation {
        let sequence: Int
        let positionMs: Int64
        let expected: PlaybackSnapshot

        func matches(_ snapshot: PlaybackSnapshot) -> Bool {
            expected.sessionEpoch == snapshot.sessionEpoch && expected.trackEpoch == snapshot.trackEpoch
                && expected.trackKey == snapshot.trackKey
        }
    }

    /// 保持权威插值与松手后的展示目标分离。
    func estimatedPositionMs(nowMonotonicMs: Int64) -> PlaybackEstimate {
        playbackClock.estimate(nowMonotonicMs: nowMonotonicMs)
    }

    /// 无采样时刻的控制器以到达时间进入同一单调时钟域。
    static func playbackSample(_ snapshot: PlaybackSnapshot) -> PlaybackSample {
        PlaybackSample(positionMs: snapshot.positionMs,
                       sampledAtMonotonicMs: snapshot.sampledAtMonotonicMs != 0
                        ? snapshot.sampledAtMonotonicMs : monotonicNowMs(),
                       isPlaying: snapshot.status == .playing, trackEpoch: snapshot.trackEpoch)
    }

    func isCurrentTrack(_ expected: PlaybackSnapshot) -> Bool {
        let current = controller.snapshot()
        return current.sessionEpoch == expected.sessionEpoch && current.trackEpoch == expected.trackEpoch
            && current.trackKey == expected.trackKey
    }

    func resumeLyricsAfterSeek(_ confirmed: PlaybackSnapshot) {
        guard Self.canSeek(confirmed, isMock: isMock) else { return }
        if let display = lyricsCoordinator?.currentDisplay() { lyricsPanel?.apply(display: display) }
        lyricsPanel?.resumeFollowing()
    }

    /// 打开系统设置的「自动化」权限页（用户显式操作；不做任何自动重试）。
    func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func canSeek(_ snapshot: PlaybackSnapshot, isMock: Bool) -> Bool {
        guard let position = snapshot.positionMs, position >= 0,
              snapshot.capabilities?.seek ?? isMock else { return false }
        switch snapshot.status {
        case .playing, .paused, .ended: return true
        default: return false
        }
    }

    var currentTitle: String? {
        snapshot.title ?? selectedSong?.title
    }

    /// 歌手名（展示用）：快照携带的 artist（真实模式来自
    /// Music 脚本采样）优先；模拟模式回退到用户选中项。
    var currentArtist: String? {
        snapshot.artist ?? selectedSong?.artistName
    }

    var sliderDurationMs: Int64 {
        snapshot.durationMs
            ?? selectedSong?.durationMs
            ?? 1
    }

    /// 播放条环境提示（非错误）：Music 未运行 / 无曲目。
    var playbackHint: String? {
        switch snapshot.status {
        case .notRunning:
            return "「音乐」App 未运行：请打开音乐并播放歌曲。"
        case .noTrack:
            return "「音乐」运行中，但当前没有播放曲目：请选歌播放。"
        case .error:
            return "暂时无法读取播放状态，请检查「音乐」App。"
        default:
            return nil
        }
    }

    /// 原始快照文本（调试区）：显示适配器报告的原始位置/状态，便于人工核对。
    var rawSnapshotDescription: String {
        let position = snapshot.positionMs.map { "\($0) ms" } ?? "nil"
        let duration = snapshot.durationMs.map { "\($0) ms" } ?? "nil"
        let status = String(describing: snapshot.status)
        let trackKey = snapshot.trackKey ?? "nil"
        let epoch = snapshot.trackEpoch
        let code = snapshot.errorCode ?? "-"
        return
            "seq=\(snapshot.seq) session=\(snapshot.sessionEpoch) trackEpoch=\(epoch) " +
            "status=\(status) position=\(position) duration=\(duration) " +
            "track=\(trackKey) sampleAt=\(snapshot.sampledAtMonotonicMs) " +
            "rtt=\(snapshot.requestDurationMs)ms errorCode=\(code)"
    }
}

@MainActor
extension AppModel {
    enum SetupState: Equatable {
        case loading
        /// TCC 自动化权限被拒（快照报告 music:permissionDenied）。
        case automationDenied
        case ready
        case failed(String)
    }

    static func makeReal() -> AppModel {
        // v2 真实模式：Music 脚本适配器（ScriptingBridge 采样 + AppleScript 点播）。
        let controller = MusicScriptPlaybackController(
            executor: ScriptingBridgeExecutor(),
            libraryLocator: AppleScriptExecutor()
        )
        return AppModel(isMock: false, controller: controller, searchService: nil)
    }

    static func makeMock() -> AppModel {
        // Mock 契约队列使用默认时长，保证进度条可用；标题回退到选中的结果行。
        let controller = MockPlaybackController(defaultDurationMs: 240_000)
        return AppModel(
            isMock: true,
            controller: controller,
            searchService: MockCatalogSearchService()
        )
    }

    /// 宿主进程单调时钟毫秒（与 MusicScriptPlaybackController.monotonicNowMs
    /// 同一定义域；本进程内比较，跨进程不比）。
    static func monotonicNowMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// 当前可作为关联目标的曲目键（命名空间化；快照 trackRef/目录身份推导，
    /// 回退到用户明确选定项）。无可定位身份为 nil。
    var currentTrackKey: String? {
        snapshot.trackKey ?? selectedSong.map { SongBinding.trackKey(for: $0.identity) }
    }

    /// 能否发起导入：有明确曲目键且导入服务可用。
    var canBeginImport: Bool {
        importFlow != nil && currentTrackKey != nil
    }
}
