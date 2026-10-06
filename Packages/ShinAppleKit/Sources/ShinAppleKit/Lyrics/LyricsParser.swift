import Foundation

// domain/lyrics：歌词导入流水线。
// 字节 → 编码校验 → 格式识别 → 逐行解析+诊断 → 归一化 → LyricDocument。
// 纯 Swift、无副作用：不访问网络、不依赖任何 SDK / UI / 数据库。
//
// offset 语义是本项目约定，不是 LRC 统一标准：
// 解析出的 offset 原样存入 document.sourceOffsetMs（正值 = 原文件歌词提前），
// 绝不把它加到任何 line.startMs 上；换算只在查询/跳转/导出边界进行。
// 多个 offset 的文档化规则：最后一个有效值生效，被覆盖值产出 warning。
public enum LyricsParser {

    /// 解析字节数据并返回文档与诊断。
    /// - Throws: `LyricParseError`（超限/空输入/无法解码时，不产出半成品文档）。
    public static func parse(
        _ data: Data,
        filename: String? = nil,
        options: LyricParseOptions = LyricParseOptions()
    ) throws -> LyricParseResult {
        guard data.count <= options.maxBytes else {
            throw LyricParseError.inputTooLarge(limitBytes: options.maxBytes, actualBytes: data.count)
        }
        let bytes = [UInt8](data)
        let text = try LyricInputDecoding.decode(bytes)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LyricParseError.emptyInput
        }
        let rawLines = LyricInputDecoding.splitLines(text)
        guard rawLines.count <= options.maxLines else {
            throw LyricParseError.tooManyLines(limit: options.maxLines, actual: rawLines.count)
        }

        var context = ParseContext()
        let format = detectFormat(in: rawLines)
        if format == .lrc {
            for (index, rawLine) in rawLines.enumerated() {
                parseLRCLine(rawLine, lineNumber: index + 1, context: &context)
            }
        } else {
            // 纯文本：所有行 startMs = nil；去掉首尾空白行，保留内部空行作段落分隔。
            for lineText in normalizePlainText(rawLines) {
                context.appendLine(LyricLine(startMs: nil, text: lineText))
            }
        }

        let document = LyricDocument(
            sourceFormat: format,
            sourceOffsetMs: context.offsetMs ?? 0,
            originalText: text,
            originalFilename: filename,
            metadata: context.metadata,
            lines: normalize(context.entries)
        )
        return LyricParseResult(document: document, diagnostics: context.diagnostics)
    }

    // MARK: - 解析上下文

    /// 单行收集结果（order 为收集顺序，供稳定排序使用）。
    private struct LineEntry {
        var order: Int
        var line: LyricLine
    }

    private struct TimedEntry {
        var startMs: Int64
        var order: Int
        var line: LyricLine
    }

    private struct LineScanState {
        var times: [Int64] = []
        var hasError = false
    }

    private struct ParseContext {
        var entries: [LineEntry] = []
        var diagnostics: [LyricDiagnostic] = []
        var metadata: [String: [String]] = [:]
        var offsetMs: Int64?
        var lastOffsetLine: Int?
        var maxTimedSoFar: Int64?

        mutating func appendLine(_ line: LyricLine) {
            entries.append(LineEntry(order: entries.count, line: line))
        }

        mutating func addDiagnostic(
            _ severity: LyricDiagnostic.Severity,
            _ code: LyricDiagnostic.Code,
            _ message: String,
            position: DiagnosticPosition
        ) {
            diagnostics.append(
                LyricDiagnostic(severity: severity, code: code, message: message, position: position)
            )
        }
    }

    // MARK: - 归一化

    /// 稳定排序：同 startMs 保持原输入顺序；未打轴行不参与时间轴，排在末尾
    /// 且保持输入顺序（可保存为 startMs = nil）。
    private static func normalize(_ entries: [LineEntry]) -> [LyricLine] {
        var timed: [TimedEntry] = []
        var untimed: [LyricLine] = []
        for entry in entries {
            if let ms = entry.line.startMs {
                timed.append(TimedEntry(startMs: ms, order: entry.order, line: entry.line))
            } else {
                untimed.append(entry.line)
            }
        }
        timed.sort { ($0.startMs, $0.order) < ($1.startMs, $1.order) }
        return timed.map(\.line) + untimed
    }

    // MARK: - LRC 行解析

    private enum TagOutcome {
        case consumed
        case plainText
    }

    /// 解析单行 LRC：行首可出现任意个标签，其后剩余文本为歌词内容。
    /// - 同一行多个时间戳：每个时间点产出独立 LyricLine 实例（各自独立 UUID）。
    /// - 带时间戳但文本为空：保留为清屏/间奏边界，不删除。
    /// - 任一标签出错：整行不产出实例（诊断已定位），绝不按 0ms 继续。
    /// - 未打轴空白行视为格式噪音丢弃（已文档化）；非空未打轴文本保留。
    private static func parseLRCLine(_ line: String, lineNumber: Int, context: inout ParseContext) {
        let chars = Array(line)
        let position = DiagnosticPosition(
            line: lineNumber,
            column: nil,
            snippet: String(line.prefix(DiagnosticPosition.snippetLimit))
        )
        var state = LineScanState()
        var pos = 0

        scanTags: while pos < chars.count {
            while pos < chars.count, LRCTagScanner.isInlineSpace(chars[pos]) {
                pos += 1
            }
            guard pos < chars.count, chars[pos] == "[" else { break }
            guard let close = chars[pos...].firstIndex(of: "]") else { break }
            let inner = String(chars[(pos + 1)..<close])
            let tagPosition = position.with(column: pos + 1)
            switch consumeTag(inner, position: tagPosition, state: &state, context: &context) {
            case .consumed:
                pos = close + 1
            case .plainText:
                // 不是可识别标签（如纯文本分段标记 [Chorus]）：整行按普通文本处理。
                break scanTags
            }
        }

        let text = String(chars[pos...]).trimmed()
        guard !state.hasError else { return }
        if !state.times.isEmpty {
            for ms in state.times {
                context.appendLine(LyricLine(startMs: ms, text: text))
            }
        } else if !text.isEmpty {
            context.appendLine(LyricLine(startMs: nil, text: text))
        }
    }

    /// 处理行首的下一个标签；返回 .plainText 表示该括号不是标签，整行按正文处理。
    private static func consumeTag(
        _ inner: String,
        position: DiagnosticPosition,
        state: inout LineScanState,
        context: inout ParseContext
    ) -> TagOutcome {
        switch LRCTagScanner.classifyBracket(inner) {
        case .empty:
            context.addDiagnostic(.warning, .emptyTagIgnored, "忽略空标签「[]」。", position: position)
        case .timestamp(let timestamp):
            applyTimestamp(timestamp, position: position, state: &state, context: &context)
        case .malformedTimestamp:
            state.hasError = true
            context.addDiagnostic(
                .error, .timestampFormatInvalid,
                "无法解析的时间戳「[\(inner.trimmed())]」，拒绝按 0 毫秒继续。",
                position: position
            )
        case .metadata(let key, let value):
            applyMetadata(key: key, value: value, position: position, context: &context)
        case .literal:
            return .plainText
        }
        return .consumed
    }

    private static func applyTimestamp(
        _ timestamp: LRCTimestamp,
        position: DiagnosticPosition,
        state: inout LineScanState,
        context: inout ParseContext
    ) {
        switch LRCTagScanner.timestampValue(timestamp) {
        case .failure(let failure):
            state.hasError = true
            let code: LyricDiagnostic.Code
            let message: String
            switch failure {
            case .secondsOutOfRange(let seconds):
                code = .secondsOutOfRange
                message = "时间戳秒数 \(seconds) 超出 0..<60，拒绝按 0 毫秒继续。"
            case .overflow:
                code = .timestampOutOfRange
                message = "时间戳数值超出可表示范围。"
            }
            context.addDiagnostic(.error, code, message, position: position)
        case .success(let value):
            if value.fractionTruncated {
                context.addDiagnostic(
                    .warning, .fractionDigitsTruncated,
                    "小数秒超过 3 位，已按毫秒精度截断。",
                    position: position
                )
            }
            if let maxSeen = context.maxTimedSoFar, value.ms < maxSeen {
                context.addDiagnostic(
                    .warning, .outOfOrderTimestamps,
                    "时间戳乱序（早于此前最大时间），已按时间稳定排序，不丢行。",
                    position: position
                )
            }
            context.maxTimedSoFar = max(context.maxTimedSoFar ?? value.ms, value.ms)
            state.times.append(value.ms)
        }
    }

    private static func applyMetadata(
        key: String,
        value: String,
        position: DiagnosticPosition,
        context: inout ParseContext
    ) {
        guard !key.isEmpty else { return }
        if key.lowercased() == "offset" {
            if let parsed = LRCTagScanner.parseOffsetMs(value) {
                if context.offsetMs != nil {
                    context.addDiagnostic(
                        .warning, .offsetSuperseded,
                        "发现重复 offset 标签：按本项目规则采用最后一个有效值（覆盖第 \(context.lastOffsetLine ?? position.line ?? 0) 行的值）。",
                        position: position
                    )
                }
                context.offsetMs = parsed
                context.lastOffsetLine = position.line
            } else {
                context.addDiagnostic(
                    .warning, .offsetInvalid,
                    "offset 值「\(value)」不是整数毫秒，已忽略。",
                    position: position
                )
            }
            return
        }
        // 未知元信息键原样保留；同键多值按出现顺序累积。
        context.metadata[key, default: []].append(value)
    }

    // MARK: - 格式识别与纯文本

    /// 格式识别（启发式）：任一行首出现时间戳或键值元信息标签即视为 LRC，
    /// 否则视为纯文本。纯文本同样走完整流水线，仅 sourceFormat 不同。
    private static func detectFormat(in lines: [String]) -> LyricSourceFormat {
        for line in lines {
            let trimmedLine = line.drop { LRCTagScanner.isInlineSpace($0) }
            guard trimmedLine.first == "[" else { continue }
            let content = String(trimmedLine)
            guard let close = content.firstIndex(of: "]"), close > content.startIndex else { continue }
            let inner = String(content[content.index(after: content.startIndex)..<close])
            switch LRCTagScanner.classifyBracket(inner) {
            case .timestamp, .malformedTimestamp, .metadata:
                return .lrc
            case .empty, .literal:
                continue
            }
        }
        return .text
    }

    /// 纯文本归一化：去除首尾空白行，保留内部空行（作为段落分隔，均未打轴）。
    private static func normalizePlainText(_ rawLines: [String]) -> [String] {
        let trimmedLines = rawLines.map { $0.trimmed() }
        var start = 0
        var end = trimmedLines.count
        while start < end, trimmedLines[start].isEmpty {
            start += 1
        }
        while end > start, trimmedLines[end - 1].isEmpty {
            end -= 1
        }
        return Array(trimmedLines[start..<end])
    }
}
