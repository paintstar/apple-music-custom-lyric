import Foundation

// 双语 LRC 合成。纯文本处理：把网易云分开返回的
// 原文 LRC 与翻译 LRC 合并成「同时间戳原文/译文相邻」的成对 LRC 文本，
// 供既有导入管线的 pairedTimestamps 双语模式识别。
//
// 设计约束：
// - 只做文本搬运与配对，不解析项目文档、不落库、不改时间戳数值；
// - 时间戳按毫秒归一为配对键（`[01:23.45]` 与 `[01:23.450]` 视为同一行）；
// - 原文行保留原样输出（含元信息行 [ti:]/[ar:]/[offset:] 等，解析器自会处理）；
// - 每个时间戳最多配一条译文（多译文取第一条）；无译文的原文行单行输出；
// - 译文有而原文没有的时间戳：丢弃（翻译没有宿主行，不凭空造原文）。

/// 双语 LRC 合成器。纯函数。
public enum BilingualLRCSynthesizer {

    /// 合并原文与翻译 LRC 文本。
    /// - Parameters:
    ///   - originalLRC: 原文 LRC 文本（网易云 `lrc.lyric`）。
    ///   - translatedLRC: 翻译 LRC 文本；nil 时原样返回原文文本。
    /// - Returns: 合成后的文本。无时间戳行（纯文本歌词）不参与配对，按原文原样输出。
    public static func synthesize(originalLRC: String, translatedLRC: String?) -> String {
        guard let translatedLRC,
              !translatedLRC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return originalLRC }

        let translationsByMs = parseTimestampedLines(translatedLRC)
        guard !translationsByMs.isEmpty else { return originalLRC }

        var output: [String] = []
        for line in originalLRC.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            output.append(text)
            // 仅当该行是「单时间戳 + 有正文」的原文行才尝试配对；
            // 元信息行（[ti:]…）、无正文行（[01:23.45]）不配。
            guard let entry = parseSingleTimestampLine(text), !entry.body.isEmpty else { continue }
            if let translation = translationsByMs[entry.startMs] {
                output.append("[\(formatTimestamp(entry.startMs))]\(translation)")
            }
        }
        return output.joined(separator: "\n")
    }

    // MARK: - LRC 行解析（仅本层使用的最小子集；权威解析在 ShinAppleKit）

    struct TimestampedLine {
        let startMs: Int64
        let body: String
    }

    /// 解析一行 `[mm:ss.xx(+/-.x)]body`；非单时间戳格式返回 nil。
    /// 只识别分:秒形式（网易云输出格式），不处理多小时等扩展格式。
    static func parseSingleTimestampLine(_ line: String) -> TimestampedLine? {
        guard line.hasPrefix("[") else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let inner = String(line[line.index(after: line.startIndex)..<close])
        guard let ms = timestampToMilliseconds(inner) else { return nil }
        let body = String(line[line.index(after: close)...])
        return TimestampedLine(startMs: ms, body: body)
    }

    /// `mm:ss(.xx…)` → 毫秒。接受 1–2 位分、1+ 位秒、可选小数。
    static func timestampToMilliseconds(_ value: String) -> Int64? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int64(parts[0]),
              minutes >= 0, minutes < 600
        else { return nil }
        let secondPieces = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard let seconds = Int64(secondPieces[0]), seconds >= 0, seconds < 60
        else { return nil }
        var milliseconds: Int64 = 0
        if secondPieces.count == 2 {
            let fraction = String(secondPieces[1])
            guard !fraction.isEmpty, fraction.count <= 3,
                  fraction.allSatisfy(\.isNumber),
                  let fractionValue = Int64(fraction)
            else { return nil }
            milliseconds = fractionValue * Self.fractionScale(fraction.count)
        } else if secondPieces.count > 2 {
            return nil
        }
        return minutes * 60_000 + seconds * 1_000 + milliseconds
    }

    /// 小数位数对应的毫秒倍率（"5"→500，"45"→450，"456"→456）。
    private static func fractionScale(_ digitCount: Int) -> Int64 {
        switch digitCount {
        case 1: return 100
        case 2: return 10
        default: return 1
        }
    }

    /// 翻译文本按时间戳建索引；同时间戳多译文取第一条。
    /// 跳过无正文行与不可解析行（不猜）。
    static func parseTimestampedLines(_ lrcText: String) -> [Int64: String] {
        var result: [Int64: String] = [:]
        for line in lrcText.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = parseSingleTimestampLine(String(line)),
                  !entry.body.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            if result[entry.startMs] == nil {
                result[entry.startMs] = entry.body
            }
        }
        return result
    }

    /// 毫秒 → 标准 `[mm:ss.xxx]` 文本（输出统一三位小数，配对键一致即可）。
    static func formatTimestamp(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        let seconds = (ms % 60_000) / 1_000
        let milliseconds = ms % 1_000
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }
}
