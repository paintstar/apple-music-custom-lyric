import Foundation
import ShinAppleKit
import ShinAppServices
import ShinLyricsEngine

/// 悬浮歌词只投影已确认的同步结果，不建立新索引、时钟或资料库查询。
enum FloatingLyricsPresentation: Equatable {
    struct Line: Identifiable, Equatable {
        let id: UUID
        let text: String
        let translation: String?
        let translationNeedsReview: Bool
    }

    case current(lines: [Line])
    case waiting(interval: LyricsWaitingInterval)
    case message(String)

    @MainActor
    static func resolve(
        snapshot: PlaybackSnapshot, panel: LyricsPanelModel?,
        display: PlaybackLyricsDisplay, showsTranslations: Bool
    ) -> FloatingLyricsPresentation {
        if let environment = environmentMessage(snapshot) { return .message(environment) }
        guard let panel else { return .message("歌词服务初始化中……") }
        switch panel.state {
        case .ready(let document):
            guard panel.displayedTrackKey == snapshot.trackKey,
                  panel.displayedTrackEpoch == snapshot.trackEpoch else {
                return .message("正在载入当前歌词……")
            }
            return resolveReady(document: document, snapshot: snapshot, display: display,
                                showsTranslations: showsTranslations)
        case .loading, .transitioning:
            return .message("正在载入当前歌词……")
        case .noTrack:
            return .message("当前没有播放歌曲")
        case .unbound:
            return .message("当前曲目没有本地歌词")
        case .untimedOnly:
            return .message("歌词尚未添加时间轴")
        case .unavailable:
            return .message("本地歌词暂不可用，请在主窗口重试")
        }
    }

    private static func environmentMessage(_ snapshot: PlaybackSnapshot) -> String? {
        switch snapshot.status {
        case .notRunning: return "「音乐」App 未运行"
        case .noTrack, .idle: return "当前没有播放歌曲"
        case .error: return "暂时无法读取播放状态"
        case .loading: return "正在读取播放状态……"
        default:
            return snapshot.trackKey == nil ? "当前没有播放歌曲" : nil
        }
    }

    private static func resolveReady(
        document: LyricDocument, snapshot: PlaybackSnapshot, display: PlaybackLyricsDisplay,
        showsTranslations: Bool
    ) -> FloatingLyricsPresentation {
        guard let position = snapshot.positionMs, position >= 0 else {
            return .message("暂时无法读取播放位置")
        }
        switch display.content {
        case .current(let ids):
            guard !ids.isEmpty, Set(ids).count == ids.count else { return .message("暂无当前歌词") }
            var lines: [Line] = []
            for id in ids {
                guard let line = document.lines.first(where: { $0.id == id }),
                      line.startMs != nil, !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .message("暂无当前歌词")
                }
                let translation = showsTranslations ? line.translations[LyricsSyncConstants.translationLanguage] : nil
                let translationText = translation?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? translation?.text : nil
                lines.append(Line(id: id, text: line.text, translation: translationText,
                                  translationNeedsReview: translationText != nil && translation?.needsReview == true))
            }
            return .current(lines: lines)
        case .noCurrentLine, .cleared:
            if let interval = display.waitingInterval,
               interval.startMs >= 0, interval.endMs > interval.startMs,
               position >= interval.startMs, position < interval.endMs,
               snapshot.durationMs.map({ interval.endMs < $0 }) ?? true,
               document.lines.contains(where: {
                   $0.id == interval.nextLineId && $0.startMs != nil
                       && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               }) {
                return .waiting(interval: interval)
            }
            return .message("暂无当前歌词")
        case .idle:
            return .message("正在载入当前歌词……")
        }
    }
}
