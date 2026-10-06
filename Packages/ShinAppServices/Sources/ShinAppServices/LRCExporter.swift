import Foundation
import ShinAppleKit
import ShinLyricsEngine

// MARK: - LRC 互操作导出
//
// LRC 只作为互操作格式，不是无损出口（完整无损请使用 JSON 备份）。
// 两条硬规则（均有对应单元测试）：
// - **不写 [offset:] 标签**：各软件对 offset 语义不一，写标签容易被误读；
//   文档 offset 的处理方式只在损失说明中告知用户。
// - **偏移只应用一次**：`.appliedOffset` 模式使用引擎唯一定义点
//   `LyricsTimelineIndex.effectiveStartMs` 单次换算
//   （effective = startMs − sourceOffsetMs + userDelayMs），导出文件内的
//   时间即最终时间，重新导入不会再次应用任何偏移。
//
// 时间格式 `[mm:ss.ff]`（百分之一秒，向下截断）；分钟超 59 时保持实际
// 分钟数（如 61:02.30）。负的有效起点裁剪为 0 并逐行计数报告。

/// LRC 导出模式。
public enum LRCExportMode: Equatable, Sendable {
    /// 原始时间：写 `line.startMs` 原值；不写 [offset:] 标签。
    case originalTimes
    /// 应用当前偏移：按引擎公式单次应用（userDelay 取当前绑定值）。
    case appliedOffset
}

/// LRC 导出结果：文本 + 损失说明列表 + 被裁剪行数。
/// 损失说明永远非空（至少包含固定条目），UI 必须原样可见。
public struct LRCExportResult: Equatable, Sendable {
    /// 导出的 LRC 文本（UTF-8；不含元信息标签）。
    public let text: String
    /// 信息损失/处理方式说明（每条一句话，面向用户展示）。
    public let lossNotes: [String]
    /// `.appliedOffset` 模式下应用偏移后为负、被裁剪为 0 的行数
    /// （`.originalTimes` 恒为 0）。
    public let clampedLineCount: Int
}

/// LRC 导出的纯函数实现（无 I/O、无状态；UI 与服务层共用）。
public enum LRCExporter {

    /// 导出 LRC。
    /// - Parameters:
    ///   - document: 权威歌词文档（导出永远使用 lines，不读取 originalText）。
    ///   - mode: 时间模式（原始时间 / 应用当前偏移）。
    ///   - userDelayMs: `.appliedOffset` 模式使用的用户延迟（正数 = 延后）；
    ///     由调用方按当前绑定解析；`.originalTimes` 模式忽略。
    public static func export(
        document: LyricDocument,
        mode: LRCExportMode,
        userDelayMs: Int64 = 0
    ) -> LRCExportResult {
        var rows: [(timeMs: Int64, text: String)] = []
        rows.reserveCapacity(document.lines.count)
        var clampedCount = 0
        var truncatedCount = 0
        var untimedCount = 0
        var translationCount = 0

        for line in document.lines {
            translationCount += line.translations.count
            guard let start = line.startMs else {
                untimedCount += 1
                continue
            }
            let effective: Int64
            switch mode {
            case .originalTimes:
                effective = start
            case .appliedOffset:
                // 偏移换算唯一定义点（与渲染/点击跳转共用，单次应用不烘焙）。
                effective = LyricsTimelineIndex.effectiveStartMs(
                    lineStartMs: start,
                    sourceOffsetMs: document.sourceOffsetMs,
                    userDelayMs: userDelayMs
                )
            }
            let outputMs = max(effective, 0)
            if effective < 0 {
                clampedCount += 1
            }
            // LRC 百分秒精度低于内部毫秒：非整 10ms 的值被截断，须告知。
            if outputMs % 10 != 0 {
                truncatedCount += 1
            }
            rows.append((outputMs, line.text))
        }

        let text = rows
            .map { "[\(timeTag($0.timeMs))]\($0.text)" }
            .joined(separator: "\n")
        let notes = buildLossNotes(
            document: document,
            mode: mode,
            userDelayMs: userDelayMs,
            summary: LossSummary(
                clampedCount: clampedCount,
                truncatedCount: truncatedCount,
                untimedCount: untimedCount,
                translationCount: translationCount
            )
        )
        return LRCExportResult(
            text: rows.isEmpty ? "" : text + "\n",
            lossNotes: notes,
            clampedLineCount: clampedCount
        )
    }

    /// `[mm:ss.ff]`：百分之一秒、向下截断；分钟保持实际数值（可超 59）。
    static func timeTag(_ ms: Int64) -> String {
        let totalCentis = ms / 10
        let minutes = totalCentis / 6_000
        let seconds = (totalCentis % 6_000) / 100
        let centis = totalCentis % 100
        return String(format: "%02d:%02d.%02d", minutes, seconds, centis)
    }

    // MARK: - 损失说明

    /// 与模式无关的损失统计。
    struct LossSummary: Sendable {
        var clampedCount: Int
        var truncatedCount: Int
        var untimedCount: Int
        var translationCount: Int
    }

    private static func buildLossNotes(
        document: LyricDocument,
        mode: LRCExportMode,
        userDelayMs: Int64,
        summary: LossSummary
    ) -> [String] {
        var notes: [String] = []
        notes.append("LRC 是互操作格式，不是完整备份：行稳定 id 与待复核（needsReview）标记不会写入。")
        notes.append("未写入：文档元信息（ti/ar/al 等全部标签）与完整 JSON 备份才有的关联信息。")
        if summary.translationCount > 0 {
            notes.append("未写入：共 \(summary.translationCount) 句译文（LRC 无译文字段；完整保留请使用 JSON 备份）。")
        }
        if summary.untimedCount > 0 {
            notes.append("未写入：共 \(summary.untimedCount) 行未打轴文本（LRC 时间行必须有时间戳）。")
        }
        switch mode {
        case .originalTimes:
            notes.append(
                "行时间为原始时间；文档 offset（sourceOffsetMs = \(document.sourceOffsetMs) ms）"
                    + "未写入文件，也不写 [offset:] 标签（各软件对 offset 语义不一，避免误读）。"
            )
        case .appliedOffset:
            notes.append(
                "已一次性应用当前显示偏移：行时间 = 原始时间 − 文档 offset"
                    + "（\(document.sourceOffsetMs) ms）+ 用户延迟（\(userDelayMs) ms）；"
                    + "文件不写 [offset:] 标签，重新导入的时间即为本文件时间，不会再次偏移。"
            )
        }
        if summary.clampedCount > 0 {
            notes.append(
                "\(summary.clampedCount) 行应用偏移后时间为负，已裁剪为 0："
                    + "这些行的负时间只保留在应用内文档中。"
            )
        }
        if summary.truncatedCount > 0 {
            notes.append(
                "\(summary.truncatedCount) 行时间的精度高于百分之一秒，已按 LRC 百分秒规则向下截断。"
            )
        }
        return notes
    }
}
