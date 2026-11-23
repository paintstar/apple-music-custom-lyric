import Foundation
import ShinAppleData
import ShinAppleKit
import ShinAppServices

// AI 学习预览与划词/整句学习宿主逻辑：从主窗口歌词面板发起注音/译文预览与词句学习。

@MainActor
extension AppModel {
    /// 初始化歌词划词与整句学习协调模型（切库或重建服务时替换并失效旧实例）。
    func installLyricsStudy(store: GRDBLyricsStore) {
        lyricsStudy?.invalidate()
        lyricsStudy = LyricsStudyModel(
            store: store,
            isMock: isMock,
            trackHintProvider: { [weak self] in
                guard let self else { return (nil, nil, nil) }
                return (self.currentTrackKey, self.currentTitle, self.currentArtist)
            },
            onVocabularyChanged: { [weak self] in
                self?.lyricsPanel?.reloadStudyMarks()
                NotificationCenter.default.post(name: .shinVocabularyDidChange, object: store)
            },
            onDocumentNoteSaved: { [weak self] in
                self?.refreshLyricsPanel()
            }
        )
    }

    /// 能否打开 AI 注音 / 译文预览：本地库可用、面板有当前文档且未处于切换/挂起中。
    var canBeginAIStudyPreview: Bool {
        lyricsStore != nil
            && lyricsPanel?.currentDocument != nil
            && lyricsPanel?.isAutoScrollSuspended != true
            && !isSwitchingStorage
    }

    /// 打开当前歌词文档的 AI 注音 / 译文预览 sheet。
    func beginAIStudyPreview() {
        guard !isTerminating,
              !isSwitchingStorage,
              let store = lyricsStore,
              let document = lyricsPanel?.currentDocument else {
            return
        }
        let previewModel = AIStudyPreviewModel(
            store: store,
            document: document,
            songTitle: currentTitle,
            artist: currentArtist,
            commitTarget: .storedDocument(
                documentId: document.id,
                expectedRevision: document.revision
            ),
            isMock: isMock,
            onApplied: { [weak self] in
                guard let self else { return }
                self.isAIStudyPreviewPresented = false
                self.refreshLyricsPanel()
            }
        )
        aiStudyPreviewModel = previewModel
        isAIStudyPreviewPresented = true
    }

    /// sheet 关闭后的统一收尾：取消残留任务并恢复同步滚动。
    func finishAIStudyPreview() {
        aiStudyPreviewModel?.invalidate()
        aiStudyPreviewModel = nil
        updateLyricsScrollSuspension()
    }

    /// 能否打开 AI 提炼本曲重点词汇预习卡。
    var canBeginAIKeyPoints: Bool {
        canBeginAIStudyPreview
    }

    /// 打开当前歌词文档的 AI 提炼本曲重点词汇预习卡 sheet。
    func beginAIKeyPoints() {
        guard !isTerminating,
              !isSwitchingStorage,
              let store = lyricsStore,
              let document = lyricsPanel?.currentDocument else {
            return
        }
        aiKeyPointsModel?.invalidate()
        let keyPointsModel = AIKeyPointsModel(
            store: store,
            document: document,
            songTitle: currentTitle,
            artist: currentArtist,
            trackKeyHint: currentTrackKey,
            isMock: isMock,
            onVocabularyChanged: { [weak self, weak store] in
                self?.lyricsPanel?.reloadStudyMarks()
                if let store {
                    NotificationCenter.default.post(name: .shinVocabularyDidChange, object: store)
                }
            }
        )
        aiKeyPointsModel = keyPointsModel
        isAIKeyPointsPresented = true
    }

    /// 重点词汇预习卡关闭后的统一收尾。
    func finishAIKeyPoints() {
        aiKeyPointsModel?.invalidate()
        aiKeyPointsModel = nil
        updateLyricsScrollSuspension()
    }
}

extension Notification.Name {
    static let shinSelectSettingsPage = Notification.Name("shin.selectSettingsPage")
}
