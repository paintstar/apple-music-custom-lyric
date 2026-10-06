import Foundation

// domain/lyrics：LRC 标签分类与时间戳/offset 换算。
// 供 LyricsParser 使用；模块内部实现，不属于公开契约。
//
// 十进制小数秒按十进制换算（.5=500ms、.05=50ms、.005=5ms），
// 全程整数运算，禁用 Double 乘法与 Date 解析，避免浮点误差。

/// 一个 LRC 时间戳的数字部分（已通过形状校验）。
struct LRCTimestamp: Equatable {
    var minuteDigits: String
    var secondDigits: String
    var fractionDigits: String?
}

/// 方括号内容的分类结果。
enum BracketContent: Equatable {
    case timestamp(LRCTimestamp)
    case malformedTimestamp
    case metadata(key: String, value: String)
    case empty
    case literal
}

/// 时间戳换算失败原因。
enum TimestampFailure: Error {
    case secondsOutOfRange(Int64)
    case overflow
}

/// 时间戳换算结果。
struct TimestampValue {
    var ms: Int64
    var fractionTruncated: Bool
}

/// 标签扫描与换算工具。
enum LRCTagScanner {

    /// 分类方括号内容。识别规则（启发式，已文档化）：
    /// - `数字:数字(.数字)?` → 时间戳；形状不符 → malformedTimestamp（报错）。
    /// - `键:值`（键非纯数字）→ 元信息；offset 由调用方单独处理。
    /// - 空内容 → empty；其余（如 [Chorus]）→ literal（按正文文本保留）。
    static func classifyBracket(_ raw: String) -> BracketContent {
        let inner = raw.trimmed()
        if inner.isEmpty { return .empty }
        guard let colon = inner.firstIndex(of: ":") else { return .literal }
        let key = String(inner[..<colon]).trimmed()
        let value = String(inner[inner.index(after: colon)...]).trimmed()
        if isDigits(key) {
            return timestampContent(key: key, value: value)
        }
        if key.isEmpty { return .literal }
        return .metadata(key: key, value: value)
    }

    /// `数字:数字(.数字)?` 形状校验；不符 → malformedTimestamp。
    private static func timestampContent(key: String, value: String) -> BracketContent {
        let (secondPart, fractionPart) = splitFraction(value)
        let secondValid = !secondPart.isEmpty && isDigits(secondPart)
        var fractionValid = true
        if let fraction = fractionPart {
            fractionValid = !fraction.isEmpty && isDigits(fraction)
        }
        if secondValid, fractionValid {
            return .timestamp(
                LRCTimestamp(minuteDigits: key, secondDigits: secondPart, fractionDigits: fractionPart)
            )
        }
        return .malformedTimestamp
    }

    private static func splitFraction(_ value: String) -> (String, String?) {
        guard let dot = value.firstIndex(of: ".") else { return (value, nil) }
        let fraction = String(value[value.index(after: dot)...])
        return (String(value[..<dot]), fraction)
    }

    /// 时间戳 → 毫秒。分钟可超 59；秒必须在 0..<60；小数超 3 位截断并标记。
    static func timestampValue(_ timestamp: LRCTimestamp) -> Result<TimestampValue, TimestampFailure> {
        guard let minutes = digitsToInt64(timestamp.minuteDigits),
              let seconds = digitsToInt64(timestamp.secondDigits) else {
            return .failure(.overflow)
        }
        guard seconds < 60 else { return .failure(.secondsOutOfRange(seconds)) }
        let fraction = fractionMilliseconds(timestamp.fractionDigits)
        guard let minutesMs = checkedMultiply(minutes, 60_000),
              let secondsMs = checkedMultiply(seconds, 1_000),
              let withSeconds = checkedAdd(minutesMs, secondsMs),
              let total = checkedAdd(withSeconds, fraction.ms) else {
            return .failure(.overflow)
        }
        return .success(TimestampValue(ms: total, fractionTruncated: fraction.truncated))
    }

    /// 十进制小数秒 → 毫秒（.5=500、.05=50、.005=5；超 3 位截断到毫秒精度）。
    private static func fractionMilliseconds(_ digits: String?) -> (ms: Int64, truncated: Bool) {
        guard var fractionDigits = digits else { return (0, false) }
        var truncated = false
        if fractionDigits.count > 3 {
            fractionDigits = String(fractionDigits.prefix(3))
            truncated = true
        }
        var ms = Int64(0)
        var scale = Int64(100)
        for character in fractionDigits {
            if let digit = decimalDigitValue(character) {
                ms += Int64(digit) * scale
                scale /= 10
            }
        }
        return (ms, truncated)
    }

    /// offset 值：可选正负号 + 整数毫秒；非法返回 nil。
    /// 存入 sourceOffsetMs 的符号即「正值 = 原文件歌词提前」（本项目约定，
    /// 不是 LRC 统一标准）；换算只在查询/导出边界进行，不落到 line.startMs。
    static func parseOffsetMs(_ value: String) -> Int64? {
        var rest = Substring(value.trimmed())
        var negative = false
        if let first = rest.first, first == "+" || first == "-" {
            negative = first == "-"
            rest = rest.dropFirst()
        }
        guard let magnitude = digitsToInt64(String(rest)) else { return nil }
        return negative ? -magnitude : magnitude
    }

    static func isInlineSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { decimalDigitValue($0) != nil }
    }

    static func decimalDigitValue(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, (48...57).contains(ascii) else { return nil }
        return Int(ascii - 48)
    }

    /// 十进制数字串 → Int64（只接受 ASCII 数字；空串/非法字符/溢出返回 nil）。
    static func digitsToInt64(_ digits: String) -> Int64? {
        guard !digits.isEmpty else { return nil }
        var value = Int64(0)
        for character in digits {
            guard let digit = decimalDigitValue(character) else { return nil }
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            if multiplyOverflow { return nil }
            let (added, addOverflow) = multiplied.addingReportingOverflow(Int64(digit))
            if addOverflow { return nil }
            value = added
        }
        return value
    }

    static func checkedMultiply(_ a: Int64, _ b: Int64) -> Int64? {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : result
    }

    static func checkedAdd(_ a: Int64, _ b: Int64) -> Int64? {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : result
    }
}

extension String {
    /// 裁剪行首行尾空白（解析器内部工具）。
    func trimmed() -> String {
        trimmingCharacters(in: .whitespaces)
    }
}
