import Combine
import ShinAppleKit
import SwiftUI

/// 系统菜单调用同一套播放能力，状态仅使用适配器确认的快照。
@MainActor
struct SystemPlaybackCommands: Commands {
    let model: AppModel
    let menuRouter: MusicWindowMenuRouter
    let playback: PlaybackMenuState.State
    let window: MusicWindowMenuActions?

    var body: some Commands {
        CommandMenu("控制") {
            SystemPlaybackMenuContent(model: model, menuRouter: menuRouter, playback: playback,
                                      canRevealCurrentTrack: playback.hasCurrentTrack && window != nil,
                                      canGoBack: window?.goBack != nil)
        }
    }
}

private struct SystemPlaybackMenuContent: View {
    let model: AppModel
    let menuRouter: MusicWindowMenuRouter
    let playback: PlaybackMenuState.State
    let canRevealCurrentTrack: Bool
    let canGoBack: Bool

    var body: some View {
        Group {
            Button(playback.status == .playing ? "暂停" : "播放", action: model.togglePlayPause)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playback.canPlayPause(isMock: model.isMock))
            Button("停止", action: model.stopPlayback)
                .keyboardShortcut(".")
                .disabled(!canStop)
            Button("下一首", action: model.playNext)
                .keyboardShortcut(.rightArrow)
                .disabled(!canChangeTrack || !(playback.capabilities?.next ?? model.isMock))
            Button("上一首", action: model.playPrevious)
                .keyboardShortcut(.leftArrow)
                .disabled(!canChangeTrack || !(playback.capabilities?.previous ?? model.isMock))
            Button("前往当前歌曲") { menuRouter.actions?.revealCurrentTrack?() }
                .keyboardShortcut("l")
                .disabled(playback.isTerminating || !canRevealCurrentTrack)
            Divider()
            Button("提高音量") { model.playbackOptions.adjustVolume(increasing: true) }
                .keyboardShortcut(.upArrow)
                .disabled(!canUseOptions || !options.hasVolume)
            Button("降低音量") { model.playbackOptions.adjustVolume(increasing: false) }
                .keyboardShortcut(.downArrow)
                .disabled(!canUseOptions || !options.hasVolume)
            Divider()
            shufflePicker
            repeatPicker
            Divider()
            Button("返回") { menuRouter.actions?.goBack?() }
                .keyboardShortcut("[")
                .disabled(playback.isTerminating || !canGoBack)
        }
    }

    private var options: PlaybackMenuOptionsState { playback.options }

    private var canUseOptions: Bool { playback.canUseOptions }

    private var canChangeTrack: Bool { playback.canControlPlayback && !playback.isChangingTrack }

    private var canStop: Bool {
        guard canChangeTrack, playback.capabilities?.stop == true else { return false }
        switch playback.status {
        case .playing, .paused, .buffering, .seeking: return true
        default: return false
        }
    }

    private var shufflePicker: some View {
        Picker("随机播放", selection: Binding(
            get: { options.shuffleEnabled },
            set: { if let enabled = $0 { model.playbackOptions.setShuffleEnabled(enabled) } }
        )) {
            if options.shuffleEnabled == nil { Text("状态未知").tag(nil as Bool?).disabled(true) }
            Text("关闭").tag(Optional(false))
            Text("开启").tag(Optional(true))
        }
        .disabled(!canUseOptions || options.pendingShuffleChange)
    }

    private var repeatPicker: some View {
        Picker("重复播放", selection: Binding(
            get: { options.repeatMode },
            set: { if let mode = $0 { model.playbackOptions.setRepeatMode(mode) } }
        )) {
            if options.repeatMode == nil { Text("状态未知").tag(nil as PlaybackRepeatMode?).disabled(true) }
            Text("关闭").tag(Optional(PlaybackRepeatMode.off))
            Text("列表循环").tag(Optional(PlaybackRepeatMode.all))
            Text("单曲循环").tag(Optional(PlaybackRepeatMode.one))
        }
        .disabled(!canUseOptions || options.pendingRepeatChange)
    }
}

struct PlaybackMenuOptionsState: Equatable {
    let hasVolume: Bool
    let shuffleEnabled: Bool?
    let repeatMode: PlaybackRepeatMode?
    let pendingShuffleChange: Bool
    let pendingRepeatChange: Bool

    init(snapshot: PlaybackOptionsSnapshot, pendingVolume: Int?, pendingShuffle: Bool, pendingRepeat: Bool) {
        hasVolume = (pendingVolume ?? snapshot.volume) != nil
        shuffleEnabled = snapshot.shuffleEnabled
        repeatMode = snapshot.repeatMode
        pendingShuffleChange = pendingShuffle
        pendingRepeatChange = pendingRepeat
    }
}

/// 过滤位置、采样序号等菜单不关心的更新，避免正在展开的子菜单随播放刷新。
@MainActor
final class PlaybackMenuState: ObservableObject {
    struct State: Equatable {
        let status: PlayerStatus
        let capabilities: PlaybackCapabilities?
        let hasCurrentTrack: Bool
        let isReady: Bool
        let isChangingTrack: Bool
        let isTerminating: Bool
        let options: PlaybackMenuOptionsState

        init(snapshot: PlaybackSnapshot, setup: AppModel.SetupState, changingTrack: Bool, terminating: Bool,
             options: PlaybackMenuOptionsState) {
            status = snapshot.status
            capabilities = snapshot.capabilities
            hasCurrentTrack = snapshot.trackKey != nil
            isReady = setup == .ready
            isChangingTrack = changingTrack
            isTerminating = terminating
            self.options = options
        }

        var canUseOptions: Bool {
            guard !isTerminating, isReady else { return false }
            switch status {
            case .notRunning, .error, .loading: return false
            default: return true
            }
        }

        var canControlPlayback: Bool {
            guard canUseOptions else { return false }
            switch status {
            case .playing, .paused, .ended, .buffering, .seeking: return true
            // 停止后的歌曲仍属于当前清单，可以再次播放。
            case .idle: return hasCurrentTrack
            default: return false
            }
        }

        func canPlayPause(isMock: Bool) -> Bool {
            canControlPlayback && (capabilities?.playPause ?? isMock)
        }
    }

    @Published private(set) var state: State
    private var changes: AnyCancellable?

    init(model: AppModel) {
        let options = model.playbackOptions
        let initialOptions = PlaybackMenuOptionsState(snapshot: options.snapshot, pendingVolume: options.pendingVolume,
                                                       pendingShuffle: options.pendingShuffleChange,
                                                       pendingRepeat: options.pendingRepeatChange)
        state = State(snapshot: model.snapshot, setup: model.setup, changingTrack: model.isChangingTrack,
                      terminating: model.isTerminating, options: initialOptions)
        let optionChanges = options.$snapshot.combineLatest(options.$pendingVolume, options.$pendingShuffleChange,
                                                            options.$pendingRepeatChange)
            .map { snapshot, pendingVolume, pendingShuffle, pendingRepeat in
                PlaybackMenuOptionsState(snapshot: snapshot, pendingVolume: pendingVolume,
                                         pendingShuffle: pendingShuffle, pendingRepeat: pendingRepeat)
            }
            .removeDuplicates()
        changes = model.$snapshot.combineLatest(model.$setup, model.$isChangingTrack, model.$isTerminating)
            .combineLatest(optionChanges)
            .map { playback, options in
                let (snapshot, setup, changingTrack, terminating) = playback
                return State(snapshot: snapshot, setup: setup, changingTrack: changingTrack, terminating: terminating,
                             options: options)
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.state = $0 }
    }
}
