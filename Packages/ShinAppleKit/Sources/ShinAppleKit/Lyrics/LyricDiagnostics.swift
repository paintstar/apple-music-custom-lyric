// domain/lyrics：解析诊断、解析错误与解析选项/结果。
// 诊断分两级：error = 不可保存（必须修正输入后重试）；
// warning = 可保存，但需要向用户提示。

/// 诊断定位：1 起始行号/列号与原文片段。
public struct DiagnosticPosition: Equatable, Sendable {
    /// 原文片段截断上限（字符数）。
    public static let snippetLimit = 120

    /// 输入中的 1 起始行号；整文件级诊断可为 nil。
    public var line: Int?
    /// 1 起始列号（按字符计）；未知为 nil。
    public var column: Int?
    /// 原文片段（截断到 snippetLimit），便于用户定位。
    public var snippet: String?

    public init(line: Int?, column: Int? = nil, snippet: String? = nil) {
        self.line = line
        self.column = column
        self.snippet = snippet
    }

    /// 同一行的指定列位置（保留行号与片段）。
    func with(column newColumn: Int?) -> DiagnosticPosition {
        DiagnosticPosition(line: line, column: newColumn, snippet: snippet)
    }
}

/// 一条解析诊断，带位置与原文片段。
public struct LyricDiagnostic: Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable {
        /// 不可保存：文档结构或时间轴存在确定错误。
        case error
        /// 可保存：存在需要提示的归一化决策。
        case warning
    }

    public enum Code: String, Equatable, Sendable {
        /// 时间戳形状非法（如 [00:ab]）；绝不按 0ms 继续。
        case timestampFormatInvalid
        /// 秒不在 0..<60（如 [00:99.00]）。
        case secondsOutOfRange
        /// 时间戳数值超出可表示范围。
        case timestampOutOfRange
        /// 空标签 [] 被忽略。
        case emptyTagIgnored
        /// 小数秒超过 3 位，已按毫秒精度截断（如 .1234 → 123ms）。
        case fractionDigitsTruncated
        /// 乱序时间戳：已按时间稳定排序（同时间戳保持输入顺序），不丢行。
        case outOfOrderTimestamps
        /// 重复 offset 标签：本项目规则为最后一个有效值生效。
        case offsetSuperseded
        /// offset 值非法（非整数毫秒），已忽略。
        case offsetInvalid
    }

    public var severity: Severity
    public var code: Code
    /// 面向用户的中文说明。
    public var message: String
    /// 输入中的 1 起始行号；整文件级诊断可为 nil。
    public var line: Int?
    /// 1 起始列号（按字符计）；未知为 nil。
    public var column: Int?
    /// 原文片段（截断到 DiagnosticPosition.snippetLimit），便于用户定位。
    public var snippet: String?

    init(
        severity: Severity,
        code: Code,
        message: String,
        position: DiagnosticPosition
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.line = position.line
        self.column = position.column
        self.snippet = position.snippet
    }
}

/// 解析流水线的可恢复错误：类型化、可定位；用户可据此换编码或修正后重试。
/// 抛出这些错误时不会产出任何半成品文档。
public enum LyricParseError: Error, Equatable, Sendable {
    /// 字节数超过上限。
    case inputTooLarge(limitBytes: Int, actualBytes: Int)
    /// 输入行数超过上限。
    case tooManyLines(limit: Int, actual: Int)
    /// 空文件或全空白：无可导入内容。
    case emptyInput
    /// 字节流不是合法 UTF-8，byteOffset 为首个非法序列的字节位置。
    case undecodableUTF8(byteOffset: Int)
    /// 字节流不是合法 UTF-16（含未配对代理项/奇数字节），byteOffset 为出错字节位置。
    case undecodableUTF16(byteOffset: Int)

    /// 面向用户的中文说明。
    public var message: String {
        switch self {
        case .inputTooLarge(let limit, let actual):
            return "文件大小 \(actual) 字节超过上限 \(limit) 字节。"
        case .tooManyLines(let limit, let actual):
            return "文件行数 \(actual) 超过上限 \(limit) 行。"
        case .emptyInput:
            return "文件为空或全是空白，没有可导入的内容。"
        case .undecodableUTF8(let offset):
            return "字节流不是合法 UTF-8（字节位置 \(offset)）。请转换编码后重试；不会静默替换乱码。"
        case .undecodableUTF16(let offset):
            return "字节流不是合法 UTF-16（字节位置 \(offset)）。请转换编码后重试；不会静默替换乱码。"
        }
    }
}

/// 解析限制（可配置的产品限制，默认 2 MiB / 10,000 行）。
public struct LyricParseOptions: Equatable, Sendable {
    /// 输入字节上限。
    public var maxBytes: Int
    /// 输入行数上限。
    public var maxLines: Int

    public init(maxBytes: Int = 2 * 1024 * 1024, maxLines: Int = 10_000) {
        self.maxBytes = maxBytes
        self.maxLines = maxLines
    }
}

/// 解析结果：统一文档 + 诊断（不返回 DOM）。
/// 诊断含 error 时文档仅供预览，调用方必须拒绝保存（isImportable == false）。
public struct LyricParseResult: Equatable, Sendable {
    public var document: LyricDocument
    public var diagnostics: [LyricDiagnostic]

    /// 诊断中存在 error（不可保存）。
    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    /// 是否可进入保存流程：无 error；warning 不阻止保存。
    public var isImportable: Bool {
        !hasErrors
    }

    init(document: LyricDocument, diagnostics: [LyricDiagnostic]) {
        self.document = document
        self.diagnostics = diagnostics
    }
}
