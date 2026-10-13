import Foundation
import ShinAppleKit
import ShinMusicScript

/// 所有窗口/按钮共用一份选项；按需读取，不创建常驻轮询器。
@MainActor
final class PlaybackOptionsModel: ObservableObject {
    @Published private(set) var snapshot = PlaybackOptionsSnapshot()
    /// 滑块松手后保留用户目标，直到 Music 读回；不写入权威快照。
    @Published private(set) var pendingVolume: Int?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingShuffleChange = false
    @Published private(set) var pendingRepeatChange = false
    @Published private(set) var shuffleErrorMessage: String?
    @Published private(set) var repeatErrorMessage: String?

    private let service: any PlaybackOptionsControlling
    private var visibleControls = Set<UUID>()
    private var request: Task<Bool, Never>?
    private var playbackRefresh: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var queuedVolume: Int?
    private var queuedModeActions: [ModeAction] = []

    var displayedVolume: Int? { pendingVolume ?? snapshot.volume }

    init(service: any PlaybackOptionsControlling) { self.service = service }
    deinit { request?.cancel(); playbackRefresh?.cancel() }

    func appear(_ id: UUID) {
        // 浮窗打开时主窗可能已可见，非激活面板也不会触发 App 激活通知。
        if visibleControls.insert(id).inserted { refresh() }
    }

    func disappear(_ id: UUID) {
        visibleControls.remove(id)
        if visibleControls.isEmpty { cancel() }
    }

    func refresh() { run(.read) }

    func toggleShuffle() {
        guard !pendingShuffleChange else { return }
        shuffleErrorMessage = nil
        pendingShuffleChange = true
        enqueue(.shuffle)
    }

    func cycleRepeat() {
        guard !pendingRepeatChange else { return }
        repeatErrorMessage = nil
        pendingRepeatChange = true
        enqueue(.repeatMode)
    }

    func setVolume(_ volume: Int) {
        guard (0...100).contains(volume) else {
            errorMessage = PlaybackOptionsError.invalidVolume.localizedDescription
            return
        }
        pendingVolume = volume
        if isBusy {
            // 原生滑块与方向键保持可用；只排队最近一次输入，避免积压 Apple Events。
            queuedVolume = volume
        } else {
            run(.volume(volume))
        }
    }

    /// 播放服务先建立实际列表并确认随机状态，再刷新控件；音量请求仍按原顺序完成。
    func refreshAfterPlayback() {
        playbackRefresh?.cancel()
        let lifecycle = lifecycleGeneration
        playbackRefresh = Task { [weak self] in
            guard let self else { return }
            while let request = self.request {
                _ = await request.value
                guard !Task.isCancelled, lifecycle == self.lifecycleGeneration else { return }
            }
            guard !Task.isCancelled, lifecycle == self.lifecycleGeneration else { return }
            self.refresh()
        }
    }

    func cancel() {
        lifecycleGeneration &+= 1
        generation &+= 1
        request?.cancel()
        playbackRefresh?.cancel()
        playbackRefresh = nil
        request = nil
        queuedVolume = nil
        queuedModeActions.removeAll()
        pendingShuffleChange = false
        pendingRepeatChange = false
        pendingVolume = nil
        isBusy = false
    }

    private enum Command: Sendable {
        case read, volume(Int), shuffle(Bool), repeatMode(PlaybackRepeatMode)

        func execute(on service: any PlaybackOptionsControlling) async throws -> PlaybackOptionsSnapshot {
            switch self {
            case .read: return try await service.readOptions()
            case let .volume(value): return try await service.setVolume(value)
            case let .shuffle(value): return try await service.setShuffleEnabled(value)
            case let .repeatMode(value): return try await service.setRepeatMode(value)
            }
        }
    }

    private enum ModeAction {
        case shuffle, repeatMode
        func command(for snapshot: PlaybackOptionsSnapshot) -> Command? {
            switch self {
            case .shuffle: return snapshot.shuffleEnabled.map { .shuffle(!$0) }
            case .repeatMode:
                return snapshot.repeatMode.map {
                    switch $0 {
                    case .off: .repeatMode(.all)
                    case .all: .repeatMode(.one)
                    case .one: .repeatMode(.off)
                    }
                }
            }
        }
    }

    private func enqueue(_ action: ModeAction) {
        // 每个按钮最多保留一次点击；首读或其他控件忙碌时，不丢掉用户的切换意图。
        queuedModeActions.append(action)
        guard !isBusy else { return }
        // 点击前读当前状态，避免使用主窗缓存去反转用户在 Music 中更改后的设置。
        start(.read)
    }

    private func run(_ command: Command) {
        guard !isBusy else { return }
        start(command)
    }

    private func start(_ command: Command) {
        generation &+= 1
        let generation = generation
        isBusy = true
        errorMessage = nil
        request = Task { [weak self, service] in
            do {
                let result = try await command.execute(on: service)
                guard let self, !Task.isCancelled, generation == self.generation else { return false }
                self.snapshot = result
                self.completeModeChange(command)
                self.finish()
                return true
            } catch {
                guard let self, !Task.isCancelled, generation == self.generation else { return false }
                // 执行失败保留最近确认值；Music 有实际读回时，以读回校正状态。
                if let failure = error as? MusicPlaybackOptionsReadbackFailure { self.snapshot = failure.snapshot }
                let message = error is CancellationError ? nil : Self.message(for: error)
                if let message { self.errorMessage = message }
                self.completeModeChange(command, errorMessage: message)
                // 失败后停止待执行模式，各按钮保留自己的失败原因，不被后续音量请求清掉。
                self.clearModeActions(errorMessage: message)
                if case .read = command {
                    self.shuffleErrorMessage = message
                    self.repeatErrorMessage = message
                }
                self.finish()
                return false
            }
        }
    }

    private func finish() {
        request = nil
        if let volume = queuedVolume {
            queuedVolume = nil
            start(.volume(volume))
            return
        }
        pendingVolume = nil
        while !queuedModeActions.isEmpty {
            let action = queuedModeActions.removeFirst()
            if let command = action.command(for: snapshot) {
                start(command)
                return
            }
            switch action {
            case .shuffle:
                pendingShuffleChange = false
                errorMessage = "无法读取随机播放状态，未执行切换。请检查「音乐」App 后重试。"
                shuffleErrorMessage = errorMessage
            case .repeatMode:
                pendingRepeatChange = false
                errorMessage = "无法读取循环播放状态，未执行切换。请检查「音乐」App 后重试。"
                repeatErrorMessage = errorMessage
            }
        }
        isBusy = false
    }

    private func completeModeChange(_ command: Command, errorMessage: String? = nil) {
        switch command {
        case .shuffle:
            pendingShuffleChange = false
            shuffleErrorMessage = errorMessage
        case .repeatMode:
            pendingRepeatChange = false
            repeatErrorMessage = errorMessage
        case .read, .volume: break
        }
    }

    private func clearModeActions(errorMessage: String?) {
        if pendingShuffleChange { shuffleErrorMessage = errorMessage }
        if pendingRepeatChange { repeatErrorMessage = errorMessage }
        queuedModeActions.removeAll()
        pendingShuffleChange = false
        pendingRepeatChange = false
    }

    private static func message(for error: Error) -> String {
        if let error = error as? PlaybackOptionsError { return error.localizedDescription }
        if let error = error as? MusicPlaybackOptionsReadbackFailure { return error.localizedDescription }
        if let error = error as? MusicScriptFailure {
            switch error {
            case .permissionDenied:
                return "需要允许 ShinApple 控制「音乐」App。请在系统设置 → 隐私与安全性 → 自动化中允许后重试。"
            case .musicNotRunning: return "「音乐」App 尚未运行，请打开音乐或从资料库选择歌曲后重试。"
            case .timeout: return "「音乐」App 响应超时，请稍后重试。"
            case .fieldUnavailable, .commandUnsupported: return "「音乐」App 暂时无法提供该播放选项，请稍后重试。"
            default: break
            }
        }
        return "播放选项未能更新，请检查「音乐」App 后重试。"
    }
}

extension PlaybackRepeatMode {
    var playbackLabel: String {
        switch self {
        case .off: return "循环关闭"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}
