import Foundation
import ShinAppleKit
import ShinMusicScript

/// 所有窗口/按钮共用一份选项；按需读取，不创建常驻轮询器。
@MainActor
final class PlaybackOptionsModel: ObservableObject {
    @Published private(set) var snapshot = PlaybackOptionsSnapshot()
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    private let service: any PlaybackOptionsControlling
    private var visibleControls = Set<UUID>()
    private var request: Task<Void, Never>?
    private var generation: UInt64 = 0

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

    func setVolume(_ volume: Int) { run(.volume(volume)) }

    func cancel() {
        generation &+= 1
        request?.cancel()
        request = nil
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
        generation &+= 1
        let generation = generation
        isBusy = true
        errorMessage = nil
        request = Task { [weak self, service] in
            do {
                let result = try await command.execute(on: service)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.snapshot = result
                self.isBusy = false
                self.request = nil
            } catch {
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.snapshot = PlaybackOptionsSnapshot()
                self.isBusy = false
                self.request = nil
                if !(error is CancellationError) { self.errorMessage = Self.message(for: error) }
            }
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
