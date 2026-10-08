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

    private let service: any PlaybackOptionsControlling
    private var visibleControls = Set<UUID>()
    private var request: Task<Bool, Never>?
    private var generation: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var queuedVolume: Int?

    var displayedVolume: Int? { pendingVolume ?? snapshot.volume }

    init(service: any PlaybackOptionsControlling) { self.service = service }
    deinit { request?.cancel() }

    func appear(_ id: UUID) {
        let wasEmpty = visibleControls.isEmpty
        visibleControls.insert(id)
        if wasEmpty { refresh() }
    }

    func disappear(_ id: UUID) {
        visibleControls.remove(id)
        if visibleControls.isEmpty { cancel() }
    }

    func refresh() { run(.read) }

    func toggleShuffle() {
        guard let enabled = snapshot.shuffleEnabled else { refresh(); return }
        run(.shuffle(!enabled))
    }

    func cycleRepeat() {
        guard let mode = snapshot.repeatMode else { refresh(); return }
        switch mode {
        case .off: run(.repeatMode(.all))
        case .all: run(.repeatMode(.one))
        case .one: run(.repeatMode(.off))
        }
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

    /// 主页播放先等待选项确认，再启动列表；等待期间仍允许提交最新音量。
    func preparePlayback(shuffleEnabled: Bool) async -> Bool {
        let lifecycle = lifecycleGeneration
        while let request {
            _ = await request.value
            guard !Task.isCancelled, lifecycle == lifecycleGeneration else { return false }
        }
        guard !Task.isCancelled, lifecycle == lifecycleGeneration else { return false }
        run(.shuffle(shuffleEnabled))
        guard let request else { return false }
        let succeeded = await request.value
        guard !Task.isCancelled, lifecycle == lifecycleGeneration else { return false }
        guard succeeded, errorMessage == nil, snapshot.shuffleEnabled == shuffleEnabled else {
            if errorMessage == nil { errorMessage = "未能确认随机播放状态，请重试后再播放。" }
            return false
        }
        return true
    }

    func cancel() {
        lifecycleGeneration &+= 1
        generation &+= 1
        request?.cancel()
        request = nil
        queuedVolume = nil
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
                self.finish()
                return true
            } catch {
                guard let self, !Task.isCancelled, generation == self.generation else { return false }
                // 保留最近确认值；失败不会让滑块消失或随机/循环变成未知。
                if !(error is CancellationError) { self.errorMessage = Self.message(for: error) }
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
        } else {
            pendingVolume = nil
            isBusy = false
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? PlaybackOptionsError { return error.localizedDescription }
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
