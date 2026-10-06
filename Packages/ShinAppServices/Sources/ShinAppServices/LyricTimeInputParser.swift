import Foundation

// MARK: - 编辑器时间输入解析

/// 歌词行时间输入的解析与显示工具（纯函数，无副作用）。
///
/// 编辑器时间输入框接受的写法。非法输入一律返回类型化错误，
/// 不静默归零，报错须指出无法解析的具体位置：
///
/// 1. 空白串或仅一对空方括号 `[]` → 未打轴（startMs = nil）。
/// 2. 可选包裹一对 ASCII 方括号：`[01:02.500]` 与 `01:02.500` 等价；
///    只出现单边括号视为非法。
/// 3. 分秒形式 `分:秒(.小数)`：分钟至少 1 位数字、可超过 59（与导入解析一致）；
///    秒必须为数字且 < 60；小数为十进制（`.5` = 500ms），超过 3 位按十进制
///    截断到毫秒（内部单位即毫秒，与导入行为一致）。
/// 4. 纯数字（可含一个小数点）→ 十进制秒：`90` = 90 秒，`12.5` = 12 秒 500ms。
/// 5. 整数毫秒：数字 + 可选空白 + `ms` 或 `毫秒` 后缀；带小数毫秒被拒绝
///    （内部最细单位为毫秒，不存在半毫秒）。
/// 6. 负号一律拒绝（本项目行时间不为负）；其余写法报 malformed。
///
/// 全程整数运算，禁用 Double 乘法与 Date 解析，避免浮点误差。
public enum LyricTimeInputParser {

    /// 解析失败原因（类型化，可定位到行的错误载荷）。
    public enum Failure: Error, Equatable, Sendable {
        /// 无法识别的写法。
        case malformed
        /// 秒 ≥ 60（冒号形式）。
        case secondsOutOfRange(Int64)
        /// 负数不被接受（行时间不为负）。
        case negativeNotAllowed
        /// 毫秒输入带小数（内部最细单位为毫秒）。
        case fractionalMilliseconds
        /// 数值超出可表示范围。
        case outOfRange
    }

    /// 解析时间输入。
    /// - Returns: `.success(nil)` 表示未打轴（输入为空白）；否则为整数毫秒。
    public static func parse(_ rawInput: String) -> Result<Int64?, Failure> {
        var raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .success(nil) }

        // 可选的一对方括号；单边括号非法。
        if raw.hasPrefix("[") || raw.hasSuffix("]") {
            guard raw.hasPrefix("["), raw.hasSuffix("]"), raw.count >= 2 else {
                return .failure(.malformed)
            }
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { return .success(nil) }
        }

        // 符号：负号拒绝；正号允许后剥掉。
        if raw.hasPrefix("-") { return .failure(.negativeNotAllowed) }
        if raw.hasPrefix("+") {
            raw = String(raw.dropFirst()).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { return .failure(.malformed) }
        }

        if raw.contains(":") { return parseColonForm(raw) }
        if raw.hasSuffix("ms") || raw.hasSuffix("毫秒") { return parseMillisecondForm(raw) }
        return parseDecimalSeconds(raw)
    }

    /// `分:秒(.小数)` 形式。只允许一个冒号；分钟可超 59，秒必须 < 60。
    private static func parseColonForm(_ raw: String) -> Result<Int64?, Failure> {
        guard let colon = raw.firstIndex(of: ":") else { return .failure(.malformed) }
        let minutePart = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = String(raw[raw.index(after: colon)...])
        guard !rest.contains(":") else { return .failure(.malformed) }
        guard isDigits(minutePart) else { return .failure(.malformed) }

        let (secondPart, fractionPart) = splitFraction(rest)
        guard isDigits(secondPart), fractionIsValid(fractionPart) else {
            return .failure(.malformed)
        }
        guard let minutes = digitsToInt64(minutePart), let seconds = digitsToInt64(secondPart) else {
            return .failure(.outOfRange)
        }
        guard seconds < 60 else { return .failure(.secondsOutOfRange(seconds)) }
        let fraction = fractionMilliseconds(fractionPart)
        guard let minutesMs = checkedMultiply(minutes, 60_000),
              let secondsMs = checkedMultiply(seconds, 1_000),
              let withSeconds = checkedAdd(minutesMs, secondsMs),
              let total = checkedAdd(withSeconds, fraction) else {
            return .failure(.outOfRange)
        }
        return .success(total)
    }

    /// 整数毫秒形式：`1250ms` / `1250 毫秒`。带小数 → fractionalMilliseconds。
    private static func parseMillisecondForm(_ raw: String) -> Result<Int64?, Failure> {
        let suffixLength = 2 // "ms" 与 "毫秒" 均为 2 个字符
        let digits = String(raw.dropLast(suffixLength)).trimmingCharacters(in: .whitespaces)
        if digits.contains(".") {
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 2, parts.allSatisfy({ isDigits(String($0)) }) {
                return .failure(.fractionalMilliseconds)
            }
            return .failure(.malformed)
        }
        guard isDigits(digits), let value = digitsToInt64(digits) else {
            return .failure(.malformed)
        }
        return .success(value)
    }

    /// 纯数字（可含一个小数点）→ 十进制秒；`.5` 视为 0.5 秒。
    private static func parseDecimalSeconds(_ raw: String) -> Result<Int64?, Failure> {
        guard !raw.contains(":") else { return .failure(.malformed) }
        guard let dot = raw.firstIndex(of: ".") else {
            guard isDigits(raw), let seconds = digitsToInt64(raw),
                  let secondsMs = checkedMultiply(seconds, 1_000) else {
                return isDigits(raw) ? .failure(.outOfRange) : .failure(.malformed)
            }
            return .success(secondsMs)
        }
        let wholePart = String(raw[..<dot])
        let fractionPart = String(raw[raw.index(after: dot)...])
        let wholeIsDigits = wholePart.isEmpty || isDigits(wholePart)
        guard wholeIsDigits, isDigits(fractionPart) else {
            return .failure(.malformed)
        }
        let seconds = wholePart.isEmpty ? Int64(0) : digitsToInt64(wholePart)
        guard let seconds, let secondsMs = checkedMultiply(seconds, 1_000),
              let total = checkedAdd(secondsMs, fractionMilliseconds(fractionPart)) else {
            return .failure(.outOfRange)
        }
        return .success(total)
    }

    /// 毫秒 → 显示文本：`1:02.500`；未打轴（nil）→ 空串（输入框留空）。
    /// 本项目行时间不为负；防御性处理下负值按 0 显示，不产生误导性文本。
    public static func displayString(from ms: Int64?) -> String {
        guard let ms, ms > 0 else { return ms == 0 ? "0:00.000" : "" }
        let totalSeconds = ms / 1_000
        let remainder = ms % 1_000
        return String(format: "%d:%02d.%03d", totalSeconds / 60, totalSeconds % 60, remainder)
    }

    // MARK: - 内部工具（整数运算，与 ShinAppleKit 解析器同规则）

    private static func splitFraction(_ value: String) -> (String, String?) {
        guard let dot = value.firstIndex(of: ".") else { return (value, nil) }
        let fraction = String(value[value.index(after: dot)...])
        return (String(value[..<dot]), fraction)
    }

    private static func fractionIsValid(_ fraction: String?) -> Bool {
        guard let fraction else { return true }
        return isDigits(fraction)
    }

    /// 十进制小数 → 毫秒（`.5` = 500、`.05` = 50、`.005` = 5；超 3 位截断）。
    private static func fractionMilliseconds(_ digits: String?) -> Int64 {
        guard var fraction = digits else { return 0 }
        if fraction.count > 3 {
            fraction = String(fraction.prefix(3))
        }
        var ms = Int64(0)
        var scale = Int64(100)
        for character in fraction {
            if let digit = decimalDigitValue(character) {
                ms += Int64(digit) * scale
            }
            scale /= 10
        }
        return ms
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { decimalDigitValue($0) != nil }
    }

    private static func decimalDigitValue(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, (48...57).contains(ascii) else { return nil }
        return Int(ascii - 48)
    }

    /// 十进制数字串 → Int64（空串/非法字符/溢出返回 nil）。
    private static func digitsToInt64(_ digits: String) -> Int64? {
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

    private static func checkedMultiply(_ a: Int64, _ b: Int64) -> Int64? {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? nil : result
    }

    private static func checkedAdd(_ a: Int64, _ b: Int64) -> Int64? {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : result
    }
}
