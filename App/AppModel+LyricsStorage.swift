import AppKit
import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// AppModel 的歌词库构建与保存位置切换。
// 权威快照与 @Published 属性声明仍由 AppModel.swift 维护；本扩展只做
// 「由一个 store 重建歌词服务全家」与「运行期切换保存位置」两件事。

@MainActor
extension AppModel {

    /// 由一个 store 重建歌词服务全家（面板/协调器/导入/编辑/库管理）。
    /// 首次初始化与保存位置切换共用；调用方负责先持有 store 与目录。
    func installLyricsServiceGraph(store: GRDBLyricsStore, note: String) {
        autoFetch?.invalidateCurrentRun()
        lyricsDatabaseNote = note
        let panel = LyricsPanelModel(store: store)
        // 同步协调器：显示变化桥接主线程推给面板；
        // 偏移持久化失败以中文提示呈现；延迟写入真实歌词库。
        let coordinator = PlaybackLyricsCoordinator(
            onDisplayChange: { [weak self] _ in
                Task { @MainActor in
                    guard let self, let display = self.lyricsCoordinator?.currentDisplay() else { return }
                    self.lyricsPanel?.apply(display: display)
                }
            },
            onDelayPersistError: { [weak self] error in
                Task { @MainActor in
                    self?.playbackMessage = "偏移保存失败：\(ErrorText.describe(error))"
                }
            },
            delayWriter: PlaybackLyricsCoordinator.standardDelayWriter(store: store)
        )
        lyricsCoordinator = coordinator
        // 初始化期间可能没有新采样（例如暂停）；先补齐已有快照，关联结果才有效。
        coordinator.update(snapshot: snapshot)
        panel.attach(coordinator: coordinator)
        lyricsPanel = panel
        updateLyricsScrollSuspension()
        let flow = ImportFlowModel(store: store)
        flow.onDidConfirm = { [weak self] in
            self?.refreshLyricsPanel()
        }
        importFlow = flow
        // 编辑器：保存成功后同样刷新面板，译文/待复核即时生效。
        let editor = LyricsEditorModel(store: store)
        editor.onDidCommit = { [weak self] in
            self?.refreshLyricsPanel()
        }
        lyricsEditor = editor
        // 本地歌词库：删除/换绑/备份导入后刷新面板与概览。
        let libraryModel = LyricsLibraryModel(store: store)
        libraryModel.onLibraryChanged = { [weak self] in
            self?.refreshLyricsPanel()
        }
        library = libraryModel
        // 歌单自动获取：落位/清理后刷新面板；启动就绪后自动跑一轮。
        let autoFetchModel = AutoFetchModel(
            store: store,
            library: controller as? MusicLibraryBrowsing,
            fetchService: isMock ? MockLyricsFetchService() : LiveLyricsFetchService()
        )
        autoFetchModel.onLibraryChanged = { [weak self] in
            self?.refreshLyricsPanel()
        }
        autoFetch = autoFetchModel
    }

    private func resumeAutoFetchIfCurrent(_ previous: AutoFetchModel?) {
        if autoFetch === previous { previous?.resume() }
    }

    /// 切换歌词库保存位置。directory = nil 表示恢复默认目录。
    /// 安全序列：校验目标目录 → 目标为空且源库有数据时在线备份（一致性快照）
    /// → 打开新库 → 关闭进行中的导入/编辑窗口并重建服务全家 → 持久化偏好。
    /// 任何一步失败：旧库、旧模型与偏好全部保持原状，仅更新结果说明。
    /// 旧位置的数据库文件始终不修改、不删除（留作安全副本，由用户手动清理）。
    func switchLyricsStorage(to directory: URL?) async {
        guard !isSwitchingStorage else { return }
        guard !isMock else {
            storageSwitchMessage = "模拟模式使用一次性临时目录，不支持更改保存位置。"
            return
        }
        isSwitchingStorage = true
        defer { isSwitchingStorage = false }

        let targetDirectory: URL
        let isDefaultTarget: Bool
        do {
            if let directory {
                targetDirectory = directory
                isDefaultTarget = false
            } else {
                targetDirectory = try LyricsDatabase.defaultRealDirectory()
                isDefaultTarget = true
            }
            try LyricsDatabase.ensureUsableDirectory(targetDirectory)
        } catch {
            storageSwitchMessage = "无法使用所选位置：\(ErrorText.describe(error))"
            return
        }
        if targetDirectory.path == lyricsDatabaseDirectory?.path {
            storageSwitchMessage = "已在当前保存位置：\(targetDirectory.path)"
            LyricsDatabase.storeOverride(isDefaultTarget ? nil : targetDirectory)
            return
        }
        let previousAutoFetch = autoFetch
        do {
            try await previousAutoFetch?.suspendAndWait()
        } catch {
            previousAutoFetch?.resume()
            storageSwitchMessage = "无法安全停止自动获取，已继续使用原位置：\(ErrorText.describe(error))"
            return
        }
        defer { resumeAutoFetchIfCurrent(previousAutoFetch) }

        let targetPath = targetDirectory.appendingPathComponent("lyrics.sqlite").path
        let targetHasDatabase = FileManager.default.fileExists(atPath: targetPath)

        // 目标为空且源库有数据 → 在线备份搬运（源库全程可用）。
        // 目标已有数据库 → 直接使用（不合并，导入不覆盖旧数据的同一原则）。
        if !targetHasDatabase, let oldStore = lyricsStore, await oldStore.hasAnyContent() {
            do {
                let path = targetPath
                try await Task.detached(priority: .userInitiated) {
                    try oldStore.backupDatabase(toFileAt: path)
                }.value
            } catch {
                storageSwitchMessage = "迁移数据失败，已继续使用原位置（原数据未受影响）：\(ErrorText.describe(error))"
                return
            }
        }

        // 打开新库。失败时若目标文件是本轮刚备份出的副本则清掉，避免下次被
        // 误当作「目标已有库」；旧的一切保持原状。
        let newStore: GRDBLyricsStore
        do {
            let path = targetPath
            newStore = try await Task.detached(priority: .userInitiated) {
                try GRDBLyricsStore(path: path)
            }.value
        } catch {
            if !targetHasDatabase {
                try? FileManager.default.removeItem(atPath: targetPath)
            }
            storageSwitchMessage = "打开新位置失败，已继续使用原位置：\(ErrorText.describe(error))"
            return
        }

        // 关闭可能打开的导入/编辑窗口（其中的未保存草稿会随旧模型释放），
        // 然后在新库上重建服务全家并强制当前歌曲重新装载。
        isImportPresented = false
        isLyricsEditorPresented = false
        lyricsStore = newStore
        lyricsDatabaseDirectory = targetDirectory
        installLyricsServiceGraph(store: newStore, note: LyricsDatabase.locationNote(
            for: targetDirectory, isDefault: isDefaultTarget
        ))
        resetLyricsTrackCache()
        LyricsDatabase.storeOverride(isDefaultTarget ? nil : targetDirectory)
        storageSwitchMessage = targetHasDatabase
            ? "已切换到：\(targetDirectory.path)（该位置已有歌词库，直接使用，未与旧位置合并）。"
            : "已切换到：\(targetDirectory.path)。旧位置的数据文件已保留作安全副本，确认无误后可手动清理。"
        refreshLyricsPanel()
    }
}
