import Foundation
import ShinAppleKit
@testable import ShinLyricsEngine

/// 时间轴测试共享工具。夹具全部为原创虚构文本，不含任何真实歌词。
enum TimelineFixture {
    /// 由 (startMs, text) 元组构建歌词文档；startMs 为 nil 表示未打轴行。
    static func document(
        sourceOffsetMs: Int64 = 0,
        lines: [(startMs: Int64?, text: String)]
    ) -> LyricDocument {
        LyricDocument(
            sourceFormat: .lrc,
            sourceOffsetMs: sourceOffsetMs,
            lines: lines.map { LyricLine(startMs: $0.startMs, text: $0.text) }
        )
    }

    /// 标准三组文档：起点 1,000 / 2,000 / 5,000ms。
    static func threeGroupDocument(sourceOffsetMs: Int64 = 0) -> LyricDocument {
        document(
            sourceOffsetMs: sourceOffsetMs,
            lines: [
                (1_000, "第一句测试文本"),
                (2_000, "第二句测试文本"),
                (5_000, "第三句测试文本")
            ]
        )
    }
}

/// 结果解包辅助：把查询结果转换为可选值，配合 `try #require` 使用。
func currentLines(of result: LyricsTimelineQueryResult) -> [LyricsTimelineLine]? {
    guard case let .current(lines) = result else { return nil }
    return lines
}

func clearedBoundary(of result: LyricsTimelineQueryResult) -> LyricsTimelineClearBoundary? {
    guard case let .cleared(boundary) = result else { return nil }
    return boundary
}
