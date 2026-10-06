import Foundation
import ShinAppServices
import ShinLyricsProvider

// AppModel 的在线歌词获取：手动获取与待确认处理入口。
// 权威快照与核心状态声明仍由 AppModel.swift 维护；本扩展只做
// 「打开获取弹窗（目标固定）→ 取词完成 → 转入既有导入预览」的编排。

@MainActor
extension AppModel {

    /// 打开在线获取弹窗：目标与匹配基准在打开时固定（与 beginImport 同语义，
    /// 切歌不影响进行中的获取）。
    func beginOnlineFetch() {
        guard let trackKey = currentTrackKey else { return }
        presentFetchSheet(
            target: ImportSessionTarget(
                trackKey: trackKey,
                titleHint: snapshot.title ?? selectedSong?.title,
                artistHint: selectedSong?.artistName,
                durationHintMs: snapshot.durationMs ?? selectedSong?.durationMs
            ),
            matchQuery: LyricsMatchQuery(
                title: snapshot.title ?? selectedSong?.title ?? "",
                artist: selectedSong?.artistName,
                durationMs: snapshot.durationMs ?? selectedSong?.durationMs
            ),
            onDelivered: { [weak self] lyrics, provenance, target in
                self?.handleFetchedLyrics(lyrics, provenance: provenance, target: target)
            }
        )
    }

    /// 从待确认队列发起获取（低置信候选由用户亲自搜索确认；确认导入后该项
    /// 自动出队，且因 matchKind = userConfirmed 不再参与自动删除）。
    func beginOnlineFetch(for item: PendingAutoFetchItem) {
        presentFetchSheet(
            target: ImportSessionTarget(
                trackKey: item.trackKey,
                titleHint: item.title,
                artistHint: item.artist,
                durationHintMs: nil
            ),
            matchQuery: LyricsMatchQuery(title: item.title, artist: item.artist, durationMs: nil),
            onDelivered: { [weak self] lyrics, provenance, target in
                self?.handleFetchedLyrics(lyrics, provenance: provenance, target: target)
                Task { await self?.autoFetch?.resolvePending(trackKey: item.trackKey) }
            }
        )
    }

    /// 打开获取弹窗的共用装配（真实/Mock 服务、目标固定、完成回调）。
    func presentFetchSheet(
        target: ImportSessionTarget,
        matchQuery: LyricsMatchQuery,
        onDelivered: @escaping (NeteaseLyrics, FetchProvenance, ImportSessionTarget) -> Void
    ) {
        let service: any LyricsFetchServicing = isMock
            ? MockLyricsFetchService() : LiveLyricsFetchService()
        let fetchModel = NeteaseLyricsFetchModel(
            service: service, matchQuery: matchQuery, target: target
        )
        fetchModel.onDelivered = { lyrics, provenance in
            onDelivered(lyrics, provenance, target)
        }
        lyricsFetchModel = fetchModel
        isLyricsFetchPresented = true
    }

    /// 取词完成：合成双语 LRC，关获取弹窗、开导入预览（既有 ingest → 确认链路，
    /// 用户确认才写库；写库文档带来源注记）。
    func handleFetchedLyrics(
        _ lyrics: NeteaseLyrics,
        provenance: FetchProvenance,
        target: ImportSessionTarget
    ) {
        guard let flow = importFlow else { return }
        let merged = BilingualLRCSynthesizer.synthesize(
            originalLRC: lyrics.originalLRC,
            translatedLRC: lyrics.translatedLRC
        )
        isLyricsFetchPresented = false
        isImportPresented = true
        Task {
            await flow.openSession(target: target, provenance: provenance)
            await flow.ingestFetchedText(merged)
        }
    }
}
