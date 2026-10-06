import Foundation
import ShinAppleKit

// 纯时间轴索引与查询引擎：负责偏移换算与当前行查询。
// 只回答「给定歌词文档和当前播放时间，应当显示什么」；
// 不认识 播放 SDK / SwiftUI / 系统事件 / 数据库 / 网络。
// SDK 报告的播放位置是权威时间，本引擎只做纯查询，不用计时器累加。

/// 歌词时间轴索引。对文档打轴行按有效起点（effectiveStartMs）构建有序时间组，
/// 构建一次、查询用二分查找。值类型，线程安全。
///
/// 偏移换算的唯一定义点在本类型（渲染/跳转/导出将来都复用）：
///
///     effectiveStartMs = line.startMs - document.sourceOffsetMs + userDelayMs
///
/// - `sourceOffsetMs` 只从文档读取，绝不二次应用，也绝不写回任何 `line.startMs`（不烘焙）。
/// - `userDelayMs` 由调用方传入（正数 = 歌词延后显示）；调整后用 `withUserDelayMs(_:)`
///   重建索引，文档模型保持不变。
/// - 等价查询坐标：`lyricsClockMs = playbackMs + sourceOffsetMs - userDelayMs`，
///   与上式互为逆运算（行生效当且仅当 `行原始 startMs <= lyricsClockMs`）。
public struct LyricsTimelineIndex: Equatable, Sendable {
    /// 文档内已打轴行的原始快照（保持文档来源顺序；未打轴行不进入引擎）。
    private struct TimedEntry: Equatable, Sendable {
        let rawStartMs: Int64
        let id: UUID
        let text: String
    }

    /// 有序时间组：同 effectiveStartMs 的行同组；组内保持来源顺序。
    private struct Group: Equatable, Sendable {
        let startMs: Int64
        /// 组内全部是空白行 → 清屏边界。
        let isClear: Bool
        let lines: [LyricsTimelineLine]
    }

    /// 文档 sourceOffsetMs 的只读快照；文件 offset 与用户延迟分开保存。
    public let sourceOffsetMs: Int64
    /// 用户延迟（整数毫秒；正数 = 延后）。
    public let userDelayMs: Int64

    private let entries: [TimedEntry]
    private let groups: [Group]
    private let waitingIntervals: [LyricsWaitingInterval]
    private let effectiveStartById: [UUID: Int64]

    /// 按文档与当前用户延迟构建时间组索引。
    /// `startMs == nil` 的未打轴行永不参与高亮；纯文本/全部未打轴文档得到空索引。
    public init(document: LyricDocument, userDelayMs: Int64) {
        var timed: [TimedEntry] = []
        timed.reserveCapacity(document.lines.count)
        for line in document.lines {
            guard let start = line.startMs else { continue }
            timed.append(TimedEntry(rawStartMs: start, id: line.id, text: line.text))
        }
        self.init(sourceOffsetMs: document.sourceOffsetMs, userDelayMs: userDelayMs, entries: timed)
    }

    private init(sourceOffsetMs: Int64, userDelayMs: Int64, entries: [TimedEntry]) {
        self.sourceOffsetMs = sourceOffsetMs
        self.userDelayMs = userDelayMs
        self.entries = entries
        let groups = Self.buildGroups(entries: entries, sourceOffsetMs: sourceOffsetMs, userDelayMs: userDelayMs)
        self.groups = groups
        self.waitingIntervals = Self.buildWaitingIntervals(groups: groups)
        var byId: [UUID: Int64] = [:]
        byId.reserveCapacity(entries.count)
        for entry in entries {
            byId[entry.id] = Self.effectiveStartMs(
                lineStartMs: entry.rawStartMs,
                sourceOffsetMs: sourceOffsetMs,
                userDelayMs: userDelayMs
            )
        }
        self.effectiveStartById = byId
    }

    // MARK: - 偏移公式（唯一定义点）

    /// 偏移公式唯一定义点：`startMs - sourceOffsetMs + userDelayMs`。
    /// 渲染、点击跳转与导出必须共享此公式，不得各自实现方向不同的逻辑。
    public static func effectiveStartMs(lineStartMs: Int64, sourceOffsetMs: Int64, userDelayMs: Int64) -> Int64 {
        lineStartMs - sourceOffsetMs + userDelayMs
    }

    /// 等价查询坐标：`playbackMs + sourceOffsetMs - userDelayMs`。
    /// 与 `effectiveStartMs` 互为逆运算：某行生效当且仅当
    /// `行原始 startMs <= lyricsClockMs`（区间规则同左闭右开）。
    public static func lyricsClockMs(playbackMs: Int64, sourceOffsetMs: Int64, userDelayMs: Int64) -> Int64 {
        playbackMs + sourceOffsetMs - userDelayMs
    }

    // MARK: - 索引信息

    /// 没有任何打轴行（纯文本/空文档）时为 true；此时任何查询都返回无当前行。
    public var isEmpty: Bool { groups.isEmpty }
    /// 有序时间组数量（同一有效起点算一组）。
    public var groupCount: Int { groups.count }
    /// 参与高亮的打轴行数量（未打轴行不计入）。
    public var timedLineCount: Int { entries.count }

    /// 用新的用户延迟重建索引；公式只应用一次，不产生累计烘焙。
    public func withUserDelayMs(_ newDelayMs: Int64) -> LyricsTimelineIndex {
        LyricsTimelineIndex(sourceOffsetMs: sourceOffsetMs, userDelayMs: newDelayMs, entries: entries)
    }

    /// 某行未裁剪的有效起点；未知 id 或未打轴行返回 nil。
    public func effectiveStartMs(forLineId id: UUID) -> Int64? {
        effectiveStartById[id]
    }

    // MARK: - 当前行查询

    /// 查询 `playbackMs` 时刻应显示的内容（纯查询，不接触播放器）。
    ///
    /// 规则：
    /// - 每组在 `[本组开始, 下一组开始)` 生效（左闭右开）；
    /// - 首组之前无当前行（返回 `.noCurrentLine`）；
    /// - 定时空白组是清屏边界：命中返回 `.cleared`，区间仍被消耗；
    /// - 最后一组延续到 `durationMs` 边界（左闭右开：恰好等于 durationMs 视为已结束）；
    ///   `durationMs == nil` 时最后一组无限延续，不虚构结束时间；
    /// - `playbackMs` 为 nil 或负数一律 `.noCurrentLine`，不猜测。
    ///
    /// - Parameters:
    ///   - playbackMs: 播放器报告的权威位置（整数毫秒）；未知为 nil。
    ///   - durationMs: 播放器报告的曲目时长（整数毫秒）；未知为 nil。
    @discardableResult
    public func query(playbackMs: Int64?, durationMs: Int64?) -> LyricsTimelineQueryResult {
        guard let playbackMs, playbackMs >= 0, let groupIndex = groupIndex(atOrBefore: playbackMs) else {
            return .noCurrentLine
        }
        if isPastKnownEnd(groupIndex: groupIndex, playbackMs: playbackMs, durationMs: durationMs) {
            return .noCurrentLine
        }
        let group = groups[groupIndex]
        if group.isClear {
            return .cleared(boundary: LyricsTimelineClearBoundary(
                startMs: group.startMs,
                lineIds: group.lines.map(\.id)
            ))
        }
        return .current(lines: group.lines)
    }

    /// 当前是否位于有明确下一句的前奏/空白段。连续空白组共用稳定区间，
    /// 未知或负位置、曲末、无后续歌词的尾奏均返回 nil。
    public func waitingInterval(playbackMs: Int64?, durationMs: Int64?) -> LyricsWaitingInterval? {
        guard let playbackMs, playbackMs >= 0 else { return nil }
        if let durationMs, playbackMs >= durationMs { return nil }
        var low = 0
        var high = waitingIntervals.count
        while low < high {
            let mid = low + (high - low) / 2
            if waitingIntervals[mid].startMs <= playbackMs {
                low = mid + 1
            } else {
                high = mid
            }
        }
        guard low > 0 else { return nil }
        let interval = waitingIntervals[low - 1]
        guard playbackMs < interval.endMs else { return nil }
        // 下一句恰好在曲末或曲末之后也无法实际进入，不展示虚假的开唱等待。
        if let durationMs, interval.endMs >= durationMs { return nil }
        return interval
    }

    /// 点击歌词行 → 应请求的播放位置 = 该行 effectiveStartMs；
    /// 返回前按 `[0, durationMs]`（duration 已知时）裁剪，负值裁到 0。
    /// 纯查询函数：只计算目标位置，调用方再交给播放器 seek。
    /// 未知 id 或未打轴行返回 nil。
    public func seekPositionMs(forLineId id: UUID, durationMs: Int64?) -> Int64? {
        guard let effective = effectiveStartById[id] else { return nil }
        let nonNegative = max(effective, 0)
        guard let durationMs else { return nonNegative }
        return min(nonNegative, durationMs)
    }

    // MARK: - 私有实现

    /// 二分查找：最右一个 `startMs <= playbackMs` 的组；首组之前返回 nil。
    private func groupIndex(atOrBefore playbackMs: Int64) -> Int? {
        var low = 0
        var high = groups.count - 1
        var found: Int?
        while low <= high {
            let mid = low + (high - low) / 2
            if groups[mid].startMs <= playbackMs {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// 末组边界：duration 已知且 playbackMs 已到达/越过结束时，歌曲已结束。
    /// 非末组区间连续（`< 下一组开始`），不受该规则影响；数据矛盾（时长早于末组起点）
    /// 时同样返回已结束，不虚构行。
    private func isPastKnownEnd(groupIndex: Int, playbackMs: Int64, durationMs: Int64?) -> Bool {
        guard groupIndex == groups.count - 1, let durationMs else { return false }
        return playbackMs >= durationMs
    }

    /// 按有效起点分组：key 唯一，组间排序确定；组内保持文档来源顺序（稳定）。
    private static func buildGroups(entries: [TimedEntry], sourceOffsetMs: Int64, userDelayMs: Int64) -> [Group] {
        var buckets: [Int64: [LyricsTimelineLine]] = [:]
        buckets.reserveCapacity(entries.count)
        for entry in entries {
            let effective = effectiveStartMs(
                lineStartMs: entry.rawStartMs,
                sourceOffsetMs: sourceOffsetMs,
                userDelayMs: userDelayMs
            )
            buckets[effective, default: []].append(
                LyricsTimelineLine(id: entry.id, text: entry.text, effectiveStartMs: effective)
            )
        }
        let sortedStarts = buckets.keys.sorted()
        return sortedStarts.map { start in
            let lines = buckets[start] ?? []
            return Group(startMs: start, isClear: lines.allSatisfy(\.isBlank), lines: lines)
        }
    }

    /// 建索引时一次合并空白段，播放采样只需二分查找，不反复扫描歌词。
    private static func buildWaitingIntervals(groups: [Group]) -> [LyricsWaitingInterval] {
        var result: [LyricsWaitingInterval] = []
        var hasVisibleGroup = false
        var clearStartMs: Int64?
        var anchorLineId: UUID?
        for group in groups {
            if group.isClear {
                if clearStartMs == nil {
                    clearStartMs = group.startMs
                    anchorLineId = group.lines.first?.id
                }
                continue
            }
            // 第一可见组之前统一从播放起点等待；其他组必须有明确的空白边界。
            let startMs = hasVisibleGroup ? clearStartMs : 0
            if let startMs, max(0, startMs) < group.startMs,
               let nextLine = group.lines.first(where: { !$0.isBlank }) {
                result.append(LyricsWaitingInterval(
                    startMs: max(0, startMs), endMs: group.startMs,
                    nextLineId: nextLine.id, anchorLineId: anchorLineId
                ))
            }
            hasVisibleGroup = true
            clearStartMs = nil
            anchorLineId = nil
        }
        return result
    }
}
