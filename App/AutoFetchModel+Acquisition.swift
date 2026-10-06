import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices
import ShinLyricsProvider

// 单曲获取与自动导入：每次异步返回后检查运行有效性，提交时再在事务内重验。
@MainActor
extension AutoFetchModel {
    /// 搜索单曲候选并按置信度落位/入待确认队列。
    func fetchAndImport(track: MusicLibraryTrack, run: AutoFetchRun) async -> FetchOutcome {
        do {
            let ranked = try await searchCandidates(for: track)
            guard run.isValid else { return .skipped }
            guard let top = ranked.first else {
                try await repository.enqueuePending(pendingItem(for: track, top: nil), isValid: { run.isValid })
                return .pending
            }
            guard top.score.isAutoHighEligible else {
                try await repository.enqueuePending(pendingItem(for: track, top: top), isValid: { run.isValid })
                await repository.appendAudit(AutoFetchAuditEntry(
                    action: .pending,
                    trackKey: track.trackRef,
                    title: track.title,
                    detail: "最佳候选《\(top.candidate.title)》\(top.candidate.artistLine) "
                        + "未达高置信门槛（\(top.score.confidence.displayName)），待确认"
                ), isValid: { run.isValid })
                return .pending
            }
            guard try await autoImport(track: track, top: top, run: run) else { return .skipped }
            guard run.isValid else { return .skipped }
            await repository.appendAudit(AutoFetchAuditEntry(
                action: .imported,
                trackKey: track.trackRef,
                title: track.title,
                detail: "高置信匹配《\(top.candidate.title)》\(top.candidate.artistLine)，"
                    + "已落位（自动获取，未核对）"
            ), isValid: { run.isValid })
            return .imported
        } catch let error as NeteaseLyricsError {
            guard run.isValid else { return .skipped }
            await appendFailure(track: track, detail: error.userMessage, run: run)
            return .failed
        } catch {
            guard run.isValid else { return .skipped }
            await appendFailure(track: track, detail: "导入失败：\(ErrorText.describe(error))", run: run)
            return .failed
        }
    }

    /// 曲目的展示/搜索用歌手（优先曲艺人，回退专辑艺人）。
    private func artist(of track: MusicLibraryTrack) -> String? {
        track.artist ?? track.albumArtist
    }

    /// 按曲目信息搜索并打分排序。
    private func searchCandidates(for track: MusicLibraryTrack) async throws -> [RankedCandidate] {
        let artist = artist(of: track)
        let keyword = artist.map { "\(track.title) \($0)" } ?? track.title
        let query = LyricsMatchQuery(
            title: track.title, artist: artist, durationMs: track.durationMs
        )
        let candidates = try await fetchService.searchSongs(query: keyword)
        return LyricsMatchRanker.rank(candidates: candidates, query: query)
    }

    /// 待确认记录（含最佳候选摘要，帮助用户判断）。
    private func pendingItem(
        for track: MusicLibraryTrack, top: RankedCandidate?
    ) -> PendingAutoFetchItem {
        PendingAutoFetchItem(
            trackKey: track.trackRef,
            title: track.title,
            artist: artist(of: track),
            topCandidateTitle: top?.candidate.title,
            topCandidateArtist: top?.candidate.artistLine
        )
    }

    /// 高置信候选自动落位：每首一个独立导入会话（自动管线专用实例，
    /// 不与用户手动导入互抢），走与手动导入完全相同的解析/校验/事务提交。
    private func autoImport(
        track: MusicLibraryTrack, top: RankedCandidate, run: AutoFetchRun
    ) async throws -> Bool {
        let artist = artist(of: track)
        let lyrics = try await fetchService.fetchLyrics(songId: top.candidate.songId)
        try run.check()
        let merged = BilingualLRCSynthesizer.synthesize(
            originalLRC: lyrics.originalLRC,
            translatedLRC: lyrics.translatedLRC
        )
        let importService = ImportWorkflowService(store: store)
        let target = ImportSessionTarget(
            trackKey: track.trackRef,
            titleHint: track.title,
            artistHint: artist,
            durationHintMs: track.durationMs
        )
        let provenance = FetchProvenance(
            provider: "netease",
            externalRef: top.candidate.externalRef,
            matchKind: .autoHigh,
            queryTitle: track.title,
            queryArtist: artist
        )
        try await importService.openImportSession(target: target, provenance: provenance)
        try run.check()
        let preview = try await importService.ingest(
            fileData: Data(merged.utf8), filename: nil
        )
        try run.check()
        if preview.pairedTimestampsAvailable {
            _ = await importService.setBilingualMode(.pairedTimestamps)
        }
        try run.check()
        return try await importService.confirmImportIfUnbound(isValid: { run.isValid }) != nil
    }

    /// 获取/导入失败统一记审计（用户可在设置页核对失败原因）。
    private func appendFailure(track: MusicLibraryTrack, detail: String, run: AutoFetchRun) async {
        await repository.appendAudit(AutoFetchAuditEntry(
            action: .failed,
            trackKey: track.trackRef,
            title: track.title,
            detail: "获取失败：\(detail)"
        ), isValid: { run.isValid })
    }

}
