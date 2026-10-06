import Foundation

// 纯时间轴查询结果类型（当前行规则）。
// 结果只携带行的稳定 id（UUID），绝不把数组下标当身份。

/// 查询结果中的一行可见歌词。来自命中的时间组，按文档来源顺序排列。
public struct LyricsTimelineLine: Equatable, Sendable {
    /// 对应 LyricLine.id（稳定 UUID）。
    public let id: UUID
    public let text: String
    /// 已按偏移公式换算的有效起点（整数毫秒，可能为负）。
    public let effectiveStartMs: Int64
}

extension LyricsTimelineLine {
    /// 空白文本（空或仅空白字符）视为清屏行。
    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 清屏边界：命中「全部行文本为空白的定时时间组」。
/// 此时没有可见行，但该组仍消耗 `[组开始, 下一组开始)` 区间——
/// 这与「首组之前/未知时间」的无当前行语义不同，调用方可区分处理。
public struct LyricsTimelineClearBoundary: Equatable, Sendable {
    /// 清屏组生效起点（整数毫秒，应用偏移后可能为负）。
    public let startMs: Int64
    /// 构成该清屏边界的空白行稳定 id（通常一行；同时间戳多空行时多行）。
    public let lineIds: [UUID]
}

/// 可确定下一句起点的等待区间。只来自前奏或明确的定时空白，不推测演唱句尾。
/// 起止均为应用来源 offset 和用户延迟后的播放坐标，区间左闭右开。
public struct LyricsWaitingInterval: Equatable, Sendable {
    public let startMs: Int64
    public let endMs: Int64
    /// 下一组中第一条非空歌词的稳定 id。
    public let nextLineId: UUID
    /// 连续空白段首行；没有空白行的前奏使用 nil，由视图在首句前展示等待位。
    public let anchorLineId: UUID?

    public init(startMs: Int64, endMs: Int64, nextLineId: UUID, anchorLineId: UUID?) {
        self.startMs = startMs
        self.endMs = endMs
        self.nextLineId = nextLineId
        self.anchorLineId = anchorLineId
    }
}

/// 时间轴查询结果。三种情形互斥，用于区分「清屏边界」与「无歌词/未知时间」。
public enum LyricsTimelineQueryResult: Equatable, Sendable {
    /// 无当前行：首组之前、文档无可打轴行、playbackMs 为 nil 或负数、
    /// 或 duration 已知且 playbackMs 已到达/越过结束边界。不猜测、不虚构。
    case noCurrentLine
    /// 命中定时空白清屏组：无可见行，但区间被该组消耗（下一组开始前保持清屏）。
    case cleared(boundary: LyricsTimelineClearBoundary)
    /// 命中可见行组：同时间戳多行一起返回，按文档来源顺序。
    case current(lines: [LyricsTimelineLine])
}
