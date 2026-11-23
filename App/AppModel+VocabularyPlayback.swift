import Foundation
import ShinAppleData
import ShinAppleKit

/// 生词本原声例句点播与定位跳转扩展。
@MainActor
extension AppModel {
    /// 点击生词本内的原声例句跳转播放。
    /// - Returns: `nil` 表示已发出定位播放指令；非空字符串为失败或限制的中文说明。
    func playVocabularyOccurrence(_ occurrence: VocabularyOccurrence) async -> String? {
        guard !isTerminating else { return "应用正在退出，无法播放。" }

        let targetTrackKey = await resolveVocabularyTrackKey(for: occurrence)
        guard let targetTrackKey else {
            return "该生词缺少可定位的本机曲目身份，请在「音乐」中打开对应歌曲。"
        }

        let currentSnapshot = controller.snapshot()
        let activeTrackKey = currentSnapshot.trackKey ?? currentTrackKey

        if activeTrackKey == targetTrackKey && Self.canSeek(currentSnapshot, isMock: isMock) {
            let targetMs = resolvedVocabularyTargetMs(for: occurrence, isCurrentTrack: true)
            return await playAndSeekCurrentTrack(snapshot: currentSnapshot, targetMs: targetMs)
        }

        guard case .scriptPersistentID = SongBinding.trackIdentity(fromTrackKey: targetTrackKey) else {
            return "该生词缺少可定位的本机曲目身份，请在「音乐」中打开对应歌曲。"
        }

        let targetMs = resolvedVocabularyTargetMs(
            for: occurrence,
            isCurrentTrack: activeTrackKey == targetTrackKey
        )
        return await switchAndPlayVocabularyTrack(trackKey: targetTrackKey, targetMs: targetMs)
    }

    private func resolveVocabularyTrackKey(for occurrence: VocabularyOccurrence) async -> String? {
        if let hint = occurrence.trackKeyHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            return hint
        }
        guard let docId = occurrence.lyricDocumentId, let store = lyricsStore else {
            return nil
        }
        let bindings = (try? await store.bindings(referencing: docId)) ?? []
        return bindings.first { $0.persistentID != nil }?.trackKey
    }

    private func resolvedVocabularyTargetMs(
        for occurrence: VocabularyOccurrence,
        isCurrentTrack: Bool
    ) -> Int64? {
        if isCurrentTrack,
           let lineId = occurrence.lineId,
           let syncedMs = lyricsCoordinator?.seekPositionMs(forLineId: lineId) {
            return syncedMs
        }
        return occurrence.startMsSnapshot
    }

    private func playAndSeekCurrentTrack(
        snapshot: PlaybackSnapshot,
        targetMs: Int64?
    ) async -> String? {
        do {
            if snapshot.status != .playing {
                try await controller.play()
                guard !isTerminating else { return nil }
            }
            let readySnapshot = controller.snapshot()
            if let targetMs, Self.canSeek(readySnapshot, isMock: isMock) {
                try await controller.seek(positionMs: targetMs)
                guard !isTerminating else { return nil }
            }
            let confirmed = controller.snapshot()
            applySnapshot(confirmed)
            resumeLyricsAfterSeek(confirmed)
            return targetMs == nil ? "该原声例句暂无时间轴标记，已继续播放对应歌曲。" : nil
        } catch let error as PlaybackError {
            return mapVocabularyPlaybackError(error)
        } catch is CancellationError {
            return nil
        } catch {
            return "播放失败：\(ErrorText.describe(error))"
        }
    }

    private func switchAndPlayVocabularyTrack(
        trackKey: String,
        targetMs: Int64?
    ) async -> String? {
        do {
            try await controller.playTrackRef(trackKey)
            guard !isTerminating else { return nil }
            let switchedSnapshot = controller.snapshot()
            applySnapshot(switchedSnapshot)

            guard switchedSnapshot.trackKey == trackKey else {
                return targetMs == nil
                    ? "已发送播放请求，请等待「音乐」切换曲目。"
                    : "已请求切换曲目，但尚未确认切到目标歌曲，暂未能定位到例句位置。"
            }

            if let targetMs, Self.canSeek(switchedSnapshot, isMock: isMock) {
                try await controller.seek(positionMs: targetMs)
                guard !isTerminating else { return nil }
                let seekedSnapshot = controller.snapshot()
                applySnapshot(seekedSnapshot)
                resumeLyricsAfterSeek(seekedSnapshot)
            } else {
                resumeLyricsAfterSeek(switchedSnapshot)
            }
            return targetMs == nil ? "该原声例句暂无时间轴标记，已从歌曲开头开始播放。" : nil
        } catch let error as PlaybackError {
            return mapVocabularyPlaybackError(error)
        } catch is CancellationError {
            return nil
        } catch {
            return "播放失败：\(ErrorText.describe(error))"
        }
    }

    private func mapVocabularyPlaybackError(_ error: PlaybackError) -> String? {
        switch error {
        case .unauthorized:
            handlePlaybackError(.unauthorized)
            return "尚未授予「音乐」App 自动化访问权限，请在系统设置中开启后重试。"
        case .configurationMissing:
            return "应用配置不可用，无法控制播放。"
        case .userCancelled:
            return nil
        case .musicNotRunning:
            return "「音乐」App 未运行：请打开音乐并选歌播放。"
        case .network:
            return "网络失败，请检查连接。"
        case .trackUnavailable:
            return "在本机音乐资料库中未找到该曲目，可能已被移除或需要手动播放。"
        case .initializationFailed(let reason):
            return "播放器初始化失败：\(reason)"
        case .unknown(let raw):
            return "播放失败：\(raw)"
        }
    }
}
