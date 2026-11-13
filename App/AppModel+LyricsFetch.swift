import Foundation
import ShinAppleKit
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
        let artistHint = onlineFetchArtistHint(for: trackKey)
        presentFetchSheet(
            target: ImportSessionTarget(
                trackKey: trackKey,
                titleHint: snapshot.title ?? selectedSong?.title,
                artistHint: artistHint,
                durationHintMs: snapshot.durationMs ?? selectedSong?.durationMs
            ),
            matchQuery: LyricsMatchQuery(
                title: snapshot.title ?? selectedSong?.title ?? "",
                artist: artistHint,
                durationMs: snapshot.durationMs ?? selectedSong?.durationMs
            ),
            onDelivered: { [weak self] lyrics, provenance, target in
                self?.handleFetchedLyrics(lyrics, provenance: provenance, target: target)
            }
        )
    }

    /// 以当前播放快照为准；回退目录信息时核实身份，避免把上一首歌的歌手带入搜索。
    private func onlineFetchArtistHint(for trackKey: String) -> String? {
        if let artist = snapshot.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            return artist
        }
        guard let selectedSong, SongBinding.trackKey(for: selectedSong.identity) == trackKey else { return nil }
        let artist = selectedSong.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? nil : artist
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
        let merged = BilingualLRCSynthesizer.synthesizeWithStatus(
            originalLRC: lyrics.originalLRC,
            translatedLRC: lyrics.translatedLRC
        )
        isLyricsFetchPresented = false
        isImportPresented = true
        Task {
            await flow.openSession(target: target, provenance: provenance, fetchedLyrics: merged)
        }
    }

    // MARK: - 手动导入与从链接导入音频及后续歌词串联

    static func makeDefaultAudioLinkImporter(
        isMock: Bool,
        controller: PlaybackController
    ) -> any AudioLinkImporting {
        let fileImporter: @Sendable (URL) async throws -> MusicLibraryImportedTrack = { [weak controller] url in
            guard let browser = controller as? any MusicLibraryBrowsing else {
                throw MusicLibraryError.unsupported
            }
            return try await browser.importAudioFile(at: url)
        }
        return isMock
            ? MockAudioLinkImportService(importer: fileImporter)
            : LiveAudioLinkImportService(importer: fileImporter)
    }

    /// 打开导入窗口：目标在打开时从当前曲目键固定（不随后续播放变化）。
    func beginImport() {
        guard !isTerminating, let trackKey = currentTrackKey else { return }
        let target = ImportSessionTarget(
            trackKey: trackKey,
            titleHint: snapshot.title ?? selectedSong?.title,
            artistHint: selectedSong?.artistName,
            durationHintMs: snapshot.durationMs ?? selectedSong?.durationMs
        )
        openManualImportSession(target: target)
    }

    func openManualImportSession(target: ImportSessionTarget) {
        guard !isTerminating, let flow = importFlow else { return }
        isImportPresented = true
        importTask?.cancel()
        importTask = Task { [weak self] in
            guard self?.isTerminating == false, !Task.isCancelled else { return }
            await flow.openSession(target: target)
        }
    }

    /// 懒创建并复用链接导入模型。
    @discardableResult
    func ensureAudioLinkImportModel() -> AudioLinkImportModel {
        if let existing = audioLinkImportModel {
            return existing
        }
        let created = AudioLinkImportModel(service: audioLinkImporter)
        created.onImportSucceeded = { [weak self] _ in
            self?.musicLibraryBrowser.refreshAfterLibraryImport()
        }
        created.onFetchOnlineLyrics = { [weak self] track in
            self?.beginOnlineFetch(for: track)
        }
        created.onImportManualLyrics = { [weak self] track in
            self?.beginManualImport(for: track)
        }
        audioLinkImportModel = created
        return created
    }

    /// 切到链接导入主页面前准备模型状态：运行中保留当前进度；已结束状态重置旧结果。
    func prepareAudioLinkImportPage() {
        guard !isTerminating else { return }
        ensureAudioLinkImportModel().prepareForReopen()
    }

    /// 打开链接导入主页面（通过通知通知主窗口切换到侧栏「导入 → 从链接导入音频」）。
    func beginAudioLinkImport() {
        guard !isTerminating else { return }
        prepareAudioLinkImportPage()
        NotificationCenter.default.post(name: .shinSelectAudioLinkImportPage, object: nil)
    }

    /// 为新入库曲目发起网易云在线搜词（固定该曲目的 trackRef，不随当前播放变化）。
    func beginOnlineFetch(for track: MusicLibraryTrack) {
        guard !isTerminating else { return }
        let target = ImportSessionTarget(
            trackKey: track.trackRef,
            titleHint: track.title,
            artistHint: track.artist,
            durationHintMs: track.durationMs
        )
        let matchQuery = LyricsMatchQuery(
            title: track.title,
            artist: track.artist,
            durationMs: track.durationMs
        )
        presentFetchSheet(
            target: target,
            matchQuery: matchQuery,
            onDelivered: { [weak self] lyrics, provenance, deliveredTarget in
                self?.handleFetchedLyrics(lyrics, provenance: provenance, target: deliveredTarget)
            }
        )
    }

    /// 为新入库曲目打开本地歌词文件/文本导入窗口。
    func beginManualImport(for track: MusicLibraryTrack) {
        guard !isTerminating, importFlow != nil else { return }
        let target = ImportSessionTarget(
            trackKey: track.trackRef,
            titleHint: track.title,
            artistHint: track.artist,
            durationHintMs: track.durationMs
        )
        openManualImportSession(target: target)
    }
}

extension Notification.Name {
    static let shinSelectAudioLinkImportPage = Notification.Name("shin.selectAudioLinkImportPage")
}
