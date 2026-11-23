import Foundation
import ShinAppleData
import ShinAppleKit

/// 歌词面板生词下划线标记查询扩展：仅在文档就绪时异步读取，序列号与文档 ID 双重防过期。
@MainActor
extension LyricsPanelModel {

    /// 是否处于切歌过渡态（旧内容置灰展示 + 提示条）。
    var isTransitioning: Bool {
        if case .transitioning = state { return true }
        return false
    }

    /// 内容变化动画键（视图淡入用）：文档集合变化时改变，纯组内高亮变化不改变。
    /// 值类型字符串便于 SwiftUI `.animation(value:)` 直接观察。
    var contentChangeKey: String {
        switch state {
        case let .ready(document):
            return "ready:\(document.id):\(document.revision)"
        case let .untimedOnly(document):
            return "untimed:\(document.id):\(document.revision)"
        case let .transitioning(retained, _):
            return "transitioning:\(retained.id)"
        case .unavailable:
            return "unavailable"
        case .noTrack:
            return "noTrack"
        case .loading:
            return "loading"
        case .unbound:
            return "unbound"
        }
    }

    /// 偏移调整（正数延后 / 负数提前，0.1 秒步进）。
    /// 立即按新偏移重算当前组；持久化由协调器异步完成（失败经 AppModel 提示）。
    func adjustDelay(byMs deltaMs: Int64) {
        guard canAdjustDelay, let coordinator else { return }
        _ = coordinator.setDelay(syncDisplay.userDelayMs + deltaMs)
    }

    /// 偏移归零。
    func resetDelay() {
        guard let coordinator else { return }
        _ = coordinator.setDelay(0)
    }

    /// 偏移控制是否可用：仅在「已关联且有打轴行」时提供。
    var canAdjustDelay: Bool {
        guard case .ready = state else { return false }
        return coordinator != nil
    }

    /// 点击歌词行 → 应请求的播放位置（毫秒；引擎已按 [0,duration] 裁剪）。
    /// 无歌词/未知行/未打轴行返回 nil，调用方不发起跳转。
    func seekPosition(forLineId id: UUID) -> Int64? {
        coordinator?.seekPositionMs(forLineId: id)
    }

    /// 当前展示的歌词文档 id（ready / untimedOnly 状态下非空）。
    /// 编辑器打开入口使用（编辑对象在打开时固定为该文档）。
    /// 过渡期间为 nil：置灰展示的旧文档不作为编辑/解除关联目标。
    var currentDocumentId: UUID? { currentDocument?.id }

    var currentDocument: LyricDocument? {
        switch state {
        case let .ready(document), let .untimedOnly(document):
            return document
        case .unavailable, .noTrack, .loading, .unbound, .transitioning:
            return nil
        }
    }

    /// 前台恢复（scenePhase → active）：立即按最近权威快照重算。
    /// 协调器从不用计时器累加，重算即从真实位置重新出发。
    func refreshSyncFromForeground() {
        coordinator?.refresh()
    }

    func clearStudyMarks() {
        marksSequence += 1
        marksTask?.cancel()
        marksTask = nil
        if !documentOccurrences.isEmpty {
            documentOccurrences = []
        }
    }

    func reloadStudyMarks() {
        marksSequence += 1
        marksTask?.cancel()
        marksTask = nil
        guard let store, let targetDocumentId = currentDocumentId else {
            if !documentOccurrences.isEmpty {
                documentOccurrences = []
            }
            return
        }
        let expectedSequence = marksSequence
        marksTask = Task { @MainActor [weak self] in
            do {
                let loaded = try await store.vocabularyOccurrences(forDocumentId: targetDocumentId)
                guard !Task.isCancelled, let self,
                      self.marksSequence == expectedSequence,
                      self.currentDocumentId == targetDocumentId else { return }
                if self.documentOccurrences != loaded {
                    self.documentOccurrences = loaded
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.marksSequence == expectedSequence else { return }
                if self.currentDocumentId != targetDocumentId, !self.documentOccurrences.isEmpty {
                    self.documentOccurrences = []
                }
            }
        }
    }
}
