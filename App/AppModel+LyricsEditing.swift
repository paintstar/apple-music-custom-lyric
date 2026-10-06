import Foundation
import ShinAppServices

// 歌词编辑器宿主逻辑：AppModel 的编辑器扩展。
// 独立成文件以保持 AppModel 主体聚焦播放与装配；
// 编辑对象在打开时按当前文档 id 固定，编辑期间切歌不影响草稿。

@MainActor
extension AppModel {

    /// 能否打开编辑器：编辑服务可用且当前面板展示着某个文档。
    var canBeginLyricsEditing: Bool {
        lyricsEditor != nil && lyricsPanel?.currentDocumentId != nil
    }

    /// 打开歌词编辑器（从歌词面板入口：编辑当前展示的文档）。
    /// 编辑期间挂起同步视图自动定位（转 MANUAL 浏览），
    /// 编辑器不与自动滚动抢焦点。
    func beginLyricsEditing() {
        guard let documentId = lyricsPanel?.currentDocumentId else {
            return
        }
        beginLyricsEditing(documentId: documentId)
    }

    /// 打开歌词编辑器（从歌词库入口：编辑指定文档）。
    /// 先收起歌词库页，避免同屏两个 sheet 争抢呈现。
    func beginLyricsEditing(documentId: UUID) {
        guard let editor = lyricsEditor else {
            return
        }
        isLibraryPresented = false
        isLyricsEditorPresented = true
        Task {
            await editor.open(documentId: documentId)
        }
    }

    /// 请求关闭编辑器呈现（确认「放弃修改」之后或无修改时调用；
    /// sheet onDismiss 统一收尾编辑会话）。
    func requestCloseLyricsEditor() {
        isLyricsEditorPresented = false
    }

    /// sheet 关闭后的统一收尾：结束编辑会话并恢复同步视图自动定位能力
    /// （恢复后按阅读空闲时间回到当前歌词）。
    func finishLyricsEditing() {
        updateLyricsScrollSuspension()
        guard let editor = lyricsEditor else { return }
        Task {
            await editor.close()
        }
    }

    func updateLyricsScrollSuspension() {
        lyricsPanel?.setAutoScrollSuspended(isImportPresented || isLyricsEditorPresented)
    }

    /// 解除当前曲目的歌词关联（文档保留在库中）。
    func unlinkCurrentLyrics() {
        guard let trackKey = currentTrackKey else { return }
        let epoch = snapshot.trackEpoch
        Task { [weak self] in
            guard let self, self.currentTrackKey == trackKey, self.snapshot.trackEpoch == epoch else { return }
            await self.lyricsPanel?.unlink(trackKey: trackKey, trackEpoch: epoch)
        }
    }
}
