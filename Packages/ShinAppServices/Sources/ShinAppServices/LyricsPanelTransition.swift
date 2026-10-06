import Foundation
import ShinAppleKit

// MARK: - 歌词面板切歌过渡策略

/// 切歌过渡决策（纯函数，无 IO；App 层 LyricsPanelModel 持有状态并执行副作用，
/// 决策规则集中在此以便单测覆盖）。
///
/// 切歌时保留上一首的阅读内容并标明过渡状态，直到新内容就绪：
/// - 无曲目（trackKey == nil）→ 普通加载路径（noTrack 空态，无需过渡）；
/// - 同曲目刷新（编辑保存、解除关联后重查等）→ 普通加载路径，
///   且调用方应保留当前内容直到结果到达（不闪「正在查询」）；
/// - 换曲目且上一状态有可展示文档（已打轴或全未打轴）→ 过渡态：
///   旧文档保留展示（置灰 + 顶部提示条），新关联结果到位后整体替换；
/// - 换曲目但上一状态无可展示文档（loading/unbound/unavailable/noTrack）→
///   普通加载路径（本来就没有内容可保留，不存在闪空白）。
public enum LyricsPanelTransition {

    /// 可保留展示的内容（过渡期间置灰显示的那份文档）。
    public enum RetainedContent: Equatable, Sendable {
        /// 至少一行已打轴：过渡期间静态展示，不参与高亮。
        case timed(document: LyricDocument)
        /// 全部行未打轴：过渡期间静态展示。
        case untimed(document: LyricDocument)

        public var document: LyricDocument {
            switch self {
            case let .timed(document): return document
            case let .untimed(document): return document
            }
        }

        public var isUntimedOnly: Bool {
            if case .untimed = self { return true }
            return false
        }
    }

    /// 过渡决策结果。
    public enum Decision: Equatable, Sendable {
        /// 走普通加载路径（可指定「加载期间保留当前内容」：同曲目刷新用，
        /// 避免已有内容的文档在重查时闪「正在查询」）。
        case loadDirectly(keepCurrentWhileLoading: Bool)
        /// 进入过渡态：保留旧内容展示，同时后台加载新曲目关联。
        case retainAndLoad(RetainedContent)
    }

    /// 决策一次刷新应进入的展示阶段。
    ///
    /// - Parameters:
    ///   - previousTrackKey: 当前展示内容所属的曲目键（nil = 面板尚未展示任何曲目内容）。
    ///   - displayedContent: 上一状态可保留的文档（nil = 无内容可保留）。
    ///   - newTrackKey: 本次刷新的目标曲目键（nil = 无当前曲目）。
    public static func decide(
        previousTrackKey: String?,
        displayedContent: RetainedContent?,
        newTrackKey: String?
    ) -> Decision {
        guard let newTrackKey else {
            return .loadDirectly(keepCurrentWhileLoading: false)
        }
        guard newTrackKey != previousTrackKey else {
            // 同曲目刷新：已有内容则保留展示直到结果到达（不闪加载态）。
            return .loadDirectly(keepCurrentWhileLoading: displayedContent != nil)
        }
        guard let content = displayedContent else {
            return .loadDirectly(keepCurrentWhileLoading: false)
        }
        return .retainAndLoad(content)
    }
}
