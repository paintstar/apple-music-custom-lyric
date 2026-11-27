import Foundation
import ShinAppleData
import ShinAppleKit
import ShinAppServices
import ShinLyricsEngine

enum VocabularyOccurrencePlaybackOutcome: Equatable {
    case played
    case requiresQueueConfirmation(VocabularyPlaybackConfirmation)
    case information(String)
    case warning(String)
    case cancelled
}

struct VocabularyPlaybackConfirmation: Equatable {
    let id = UUID()
    let trackTitle: String?
    fileprivate let occurrence: VocabularyOccurrence
    fileprivate let trackKey: String
    fileprivate let storeIdentity: ObjectIdentifier
    fileprivate let expected: PlaybackSnapshot
}

/// 生词本原声例句定位。播放控制器在实际执行时核对曲目与队列。
@MainActor
extension AppModel {
    func playVocabularyOccurrence(_ occurrence: VocabularyOccurrence) async -> VocabularyOccurrencePlaybackOutcome {
        guard !isTerminating else { return .warning("应用正在退出，无法播放。") }
        guard !isSwitchingStorage, !Task.isCancelled else { return .cancelled }
        guard !isChangingTrack, pendingSeek == nil else {
            return .information("请等当前播放操作完成后再试。")
        }

        let store = lyricsStore
        let trackKey = await resolveVocabularyTrackKey(
            for: occurrence, in: store, currentTrackKey: controller.snapshot().trackKey
        )
        guard isVocabularyPlaybackCurrent(store) else { return .cancelled }
        guard let trackKey else {
            return .warning("该例句缺少可定位的本机曲目身份，请在「音乐」中打开对应歌曲。")
        }

        return await playResolvedVocabularyOccurrence(occurrence, trackKey: trackKey, in: store)
    }

    func confirmVocabularyPlayback(_ confirmation: VocabularyPlaybackConfirmation) async -> VocabularyOccurrencePlaybackOutcome {
        guard let store = lyricsStore, ObjectIdentifier(store) == confirmation.storeIdentity,
              isVocabularyPlaybackCurrent(store) else { return .cancelled }
        guard canReplaceVocabularyQueue(expected: confirmation.expected) else {
            return .information(Self.vocabularyQueueChangedMessage)
        }

        let original = confirmation.occurrence
        do {
            let occurrences = try await store.vocabularyOccurrences(forEntryId: original.entryId)
            guard isVocabularyPlaybackCurrent(store) else { return .cancelled }
            guard let occurrence = occurrences.first(where: { $0.id == original.id }),
                  occurrence.lyricDocumentId == original.lyricDocumentId,
                  occurrence.lineId == original.lineId,
                  await resolveVocabularyTrackKey(
                    for: occurrence, in: store, currentTrackKey: confirmation.expected.trackKey
                  ) == confirmation.trackKey else {
                return .information("例句出处已变化，请重新点播。")
            }
            return await playResolvedVocabularyOccurrence(
                occurrence, trackKey: confirmation.trackKey, in: store, replacingQueueFor: confirmation.expected
            )
        } catch {
            guard !(error is CancellationError), isVocabularyPlaybackCurrent(store) else { return .cancelled }
            return .warning("读取例句出处失败：\(ErrorText.describe(error))")
        }
    }

    private static let vocabularyQueueChangedMessage = "当前播放已变化，请重新点播例句。"

    private func canReplaceVocabularyQueue(expected: PlaybackSnapshot) -> Bool {
        !isChangingTrack && pendingSeek == nil && isCurrentTrack(expected)
    }

    private func playResolvedVocabularyOccurrence(
        _ occurrence: VocabularyOccurrence, trackKey: String, in store: GRDBLyricsStore?,
        replacingQueueFor expected: PlaybackSnapshot? = nil
    ) async -> VocabularyOccurrencePlaybackOutcome {
        let targetMs = await resolveVocabularyPosition(for: occurrence, trackKey: trackKey, in: store)
        guard isVocabularyPlaybackCurrent(store) else { return .cancelled }
        if let expected, !canReplaceVocabularyQueue(expected: expected) {
            return .information(Self.vocabularyQueueChangedMessage)
        }
        guard !isChangingTrack, pendingSeek == nil else {
            return .information("请等当前播放操作完成后再试。")
        }
        let mayChangeTrack = expected != nil || controller.snapshot().trackKey != trackKey

        do {
            let result = try await sendVocabularyCommand(
                trackKey: trackKey, targetMs: targetMs, expected: expected, mayChangeTrack: mayChangeTrack
            )
            guard isVocabularyPlaybackCurrent(store) else { return .cancelled }
            if result == .queueProtected, expected == nil, let store {
                return await makeVocabularyPlaybackConfirmation(occurrence, trackKey: trackKey, in: store)
            }
            return handleVocabularyPlaybackResult(result, trackKey: trackKey, targetMs: targetMs)
        } catch {
            guard !(error is CancellationError), isVocabularyPlaybackCurrent(store) else { return .cancelled }
            if let error = error as? PlaybackError { return mapVocabularyPlaybackError(error) }
            return .warning("播放失败：\(ErrorText.describe(error))")
        }
    }

    private func sendVocabularyCommand(
        trackKey: String, targetMs: Int64?, expected: PlaybackSnapshot?, mayChangeTrack: Bool
    ) async throws -> VocabularyPlaybackResult {
        var transportRequest: Int?
        if mayChangeTrack {
            // 控制器确认新曲的位置前仍可能显示旧曲，应禁止旧曲的跳转入队。
            transportSequence += 1
            transportRequest = transportSequence
            isChangingTrack = true
        }
        defer {
            if let transportRequest, transportRequest == transportSequence { isChangingTrack = false }
        }
        if let expected {
            return try await controller.playVocabularyExample(trackKey: trackKey, positionMs: targetMs, replacingQueueFor: expected)
        }
        return try await controller.playVocabularyExample(trackKey: trackKey, positionMs: targetMs)
    }

    private func makeVocabularyPlaybackConfirmation(
        _ occurrence: VocabularyOccurrence, trackKey: String, in store: GRDBLyricsStore
    ) async -> VocabularyOccurrencePlaybackOutcome {
        let expected = controller.snapshot()
        guard expected.trackKey != trackKey else { return .information(Self.vocabularyQueueChangedMessage) }
        let hintedTrack = VocabularyBookModel.nonEmptyTrimmed(occurrence.trackKeyHint)
        let titleHint = VocabularyBookModel.nonEmptyTrimmed(occurrence.trackTitleHint)
        let title: String?
        if hintedTrack == trackKey, let titleHint {
            title = titleHint
        } else {
            let binding = try? await store.binding(forTrackKey: trackKey)
            title = VocabularyBookModel.nonEmptyTrimmed(binding?.titleHint) ?? (hintedTrack == nil ? titleHint : nil)
        }
        guard isVocabularyPlaybackCurrent(store) else { return .cancelled }
        guard canReplaceVocabularyQueue(expected: expected) else { return .information(Self.vocabularyQueueChangedMessage) }
        return .requiresQueueConfirmation(VocabularyPlaybackConfirmation(
            trackTitle: title, occurrence: occurrence, trackKey: trackKey,
            storeIdentity: ObjectIdentifier(store), expected: expected
        ))
    }

    private func isVocabularyPlaybackCurrent(_ store: GRDBLyricsStore?) -> Bool {
        !Task.isCancelled && !isTerminating && !isSwitchingStorage && lyricsStore === store
    }

    private func resolveVocabularyTrackKey(
        for occurrence: VocabularyOccurrence, in store: GRDBLyricsStore?, currentTrackKey: String?
    ) async -> String? {
        if let hint = occurrence.trackKeyHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           canPlayVocabularyTrack(hint) {
            return hint
        }
        guard let documentId = occurrence.lyricDocumentId, let store else { return nil }
        let bindings = (try? await store.bindings(referencing: documentId)) ?? []
        let playableKeys = bindings.map(\.trackKey).filter { canPlayVocabularyTrack($0) }
        return playableKeys.first { $0 == currentTrackKey } ?? playableKeys.first
    }

    private func canPlayVocabularyTrack(_ key: String) -> Bool {
        switch SongBinding.trackIdentity(fromTrackKey: key) {
        case .scriptPersistentID: return true
        case .catalog: return isMock
        case nil: return false
        }
    }

    private func resolveVocabularyPosition(
        for occurrence: VocabularyOccurrence, trackKey: String, in store: GRDBLyricsStore?
    ) async -> Int64? {
        guard let documentId = occurrence.lyricDocumentId, let lineId = occurrence.lineId else {
            return occurrence.startMsSnapshot
        }
        let current = controller.snapshot()
        if current.trackKey == trackKey,
           lyricsPanel?.displayedTrackKey == trackKey, lyricsPanel?.displayedTrackEpoch == current.trackEpoch,
           let document = lyricsPanel?.currentDocument, document.id == documentId {
            if let position = lyricsCoordinator?.seekPositionMs(forLineId: lineId) { return position }
            if document.lines.contains(where: { $0.id == lineId && $0.startMs == nil }) { return nil }
        }
        guard let store else { return occurrence.startMsSnapshot }
        let association = try? await LyricsAssociationService(store: store).associationState(forTrackKey: trackKey)
        switch association {
        case .available(let document, let binding) where document.id == documentId:
            guard let line = document.lines.first(where: { $0.id == lineId }) else {
                return occurrence.startMsSnapshot
            }
            return line.startMs.map {
                LyricsTimelineIndex.effectiveStartMs(
                    lineStartMs: $0, sourceOffsetMs: document.sourceOffsetMs, userDelayMs: binding.userDelayMs
                )
            }
        case .untimedOnly(let document) where document.id == documentId && document.lines.contains(where: { $0.id == lineId }):
            return nil
        default:
            return occurrence.startMsSnapshot
        }
    }

    private func handleVocabularyPlaybackResult(
        _ result: VocabularyPlaybackResult, trackKey: String, targetMs: Int64?
    ) -> VocabularyOccurrencePlaybackOutcome {
        switch result {
        case .queueProtected:
            return .information(Self.vocabularyQueueChangedMessage)
        case .targetNotReady:
            return .warning("暂未确认例句的播放位置，请等「音乐」加载后重试。")
        case .played:
            let current = controller.snapshot()
            guard current.trackKey == trackKey else {
                return .warning("暂未读到对应歌曲的播放状态，请稍后重试。")
            }
            applySnapshot(current, restartingClock: targetMs != nil)
            // 跟随状态的滚动由协调器生成。手动浏览时才显式恢复跟随。
            if targetMs != nil, lyricsPanel?.browseMode == .manual {
                resumeLyricsAfterSeek(current)
            }
            return targetMs == nil ? .information("该例句暂无时间标记，已播放对应歌曲。") : .played
        }
    }

    private func mapVocabularyPlaybackError(_ error: PlaybackError) -> VocabularyOccurrencePlaybackOutcome {
        switch error {
        case .unauthorized:
            handlePlaybackError(.unauthorized)
            return .warning("尚未授予「音乐」App 自动化访问权限，请在系统设置中开启后重试。")
        case .configurationMissing:
            return .warning("应用配置不可用，无法控制播放。")
        case .userCancelled:
            return .cancelled
        case .musicNotRunning:
            return .warning("「音乐」App 未运行，请打开音乐并选歌播放。")
        case .network:
            return .warning("网络失败，请检查连接。")
        case .trackUnavailable:
            return .warning("在本机音乐资料库中未找到该曲目，可能已被移除或需要手动播放。")
        case .initializationFailed(let reason):
            return .warning("播放器初始化失败：\(reason)")
        case .unknown(let raw):
            return .warning("播放失败：\(raw)")
        }
    }
}
