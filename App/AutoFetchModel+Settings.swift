import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// AutoFetchModel 的设置装载与设置变更。
// 核心刷新管线（快照 diff / 删除管线 / 获取队列）在 AutoFetchModel.swift；
// 本扩展只承载设置页直接驱动的交互方法（开关、勾选、状态装载）。

@MainActor
extension AutoFetchModel {

    /// 设置页 onAppear / 启动时装载当前状态（设置、待确认、审计、歌单列表）。
    func reloadState() async {
        let revision = stateRevision
        let loadedSettings = await repository.loadSettings()
        let loadedPending = await repository.pendingItems()
        let loadedAudit = Array(await repository.auditEntries().prefix(20))
        var loadedPlaylists = playlists
        if loadedPlaylists.isEmpty, let library {
            loadedPlaylists = (try? await library.loadPlaylists()) ?? []
        }
        guard revision == stateRevision, !isSuspended else { return }
        settings = loadedSettings
        pendingItems = loadedPending
        recentAudit = loadedAudit
        playlists = loadedPlaylists
    }

    /// 总开关。停用只停监控（已获取的歌词保留）；启用立即跑一轮。
    func setEnabled(_ enabled: Bool) async {
        guard !isSuspended else { return }
        invalidateCurrentRun()
        let revision = stateRevision
        let previous = settings
        var next = previous
        next.isEnabled = enabled
        settings = next
        do {
            try await repository.saveSettings(next)
            guard !isSuspended, revision == stateRevision else { return }
            settings = next
            if enabled {
                await refreshNow()
            } else {
                lastRunSummary = "已停用自动获取（已获取的歌词保留，不再监控变化）。"
            }
        } catch {
            guard revision == stateRevision, !isSuspended else { return }
            settings = previous
            actionMessage = "保存设置失败：\(ErrorText.describe(error))"
        }
    }

    /// 勾选/取消勾选一个歌单。取消只停监控并清快照，不动已获取歌词
    /// （默认语义；如需清理见设置页说明）。勾选后立即建立基准并刷新。
    func togglePlaylist(_ playlistID: String) async {
        guard !isSuspended else { return }
        invalidateCurrentRun()
        let revision = stateRevision
        let previous = settings
        var next = previous
        if let index = next.playlistIDs.firstIndex(of: playlistID) {
            next.playlistIDs.remove(at: index)
        } else {
            next.playlistIDs.append(playlistID)
        }
        settings = next
        do {
            try await repository.saveSettings(next)
            guard !isSuspended, revision == stateRevision else { return }
            settings = next
            if !next.playlistIDs.contains(playlistID) {
                await repository.removeSnapshot(playlistID: playlistID)
                guard !isSuspended, revision == stateRevision else { return }
            }
            if next.isEnabled {
                await refreshNow()
            }
        } catch {
            guard revision == stateRevision, !isSuspended else { return }
            settings = previous
            actionMessage = "保存设置失败：\(ErrorText.describe(error))"
        }
    }
}
