import Foundation
import ShinAppleKit

// 双语导入策略层。纯函数：输入 ShinAppleKit 解析产物文档，
// 输出挂好译文的文档 + 配对统计/警告。不访问网络、存储、UI 与播放状态。
//
// 数据处理边界：
// - 「同时间戳 = 同组、不自动识别译文」是 ShinAppleKit 解析器语义，本层
//   零改动解析器；双语识别只发生在导入策略层。
// - 本函数是纯内存映射，绝不写库；结果必须经预览（用户看到原文→译文对照
//   与统计）并由 confirmImport 显式确认后才随文档落库。
// - 输入永远是「原始解析产物」，映射幂等：重复应用不会在上一轮结果上累积。
// - 译文写入 source = .imported。文档此刻尚未入库，不存在覆盖已保存人工
//   译文的路径；若同一行已有译文（例如未来扩展的会话内编辑），按「本次
//   导入内容替换该文档译文」处理并计入统计。

/// 双语导入模式。
public enum BilingualMode: Equatable, Sendable {
    /// 不识别双语（默认）：文档与解析产物完全一致。
    case off
    /// 同时间戳成对：行组内第一非空行 = 原文，其余非空行中第一行 = 译文。
    /// 仅对 LRC 中「同时间戳行组」生效；纯文本/未打轴行不参与（本项目文档化行为）。
    case pairedTimestamps
    /// 同行分隔符：按分隔符首次出现切分，前段 = 原文，后段 = 译文。逐行生效（含纯文本）。
    case inlineSeparator(InlineSeparator)
}

/// 同行分隔符选项。
public enum InlineSeparator: String, Equatable, Hashable, CaseIterable, Sendable {
    /// 双斜线（默认）。
    case doubleSlash = "//"
    /// 半角斜线。
    case singleSlash = "/"
    /// 全角竖线。
    case fullWidthPipe = "｜"
    /// 半角竖线。
    case pipe = "|"

    /// UI 展示名。
    public var displayName: String {
        switch self {
        case .doubleSlash: return "//（默认）"
        case .singleSlash: return "/"
        case .fullWidthPipe: return "｜（全角）"
        case .pipe: return "|（半角）"
        }
    }
}

/// 一条双语映射警告。双语识别只有警告、不产生 error：
/// 配对失败不阻止导入（用户可改用其他模式或继续单语导入）。
public struct BilingualWarning: Equatable, Sendable {
    /// 面向用户的中文说明；被丢弃/未配对的文本保留在消息里，不静默丢失。
    public let message: String
    /// 相关文本片段（如组内多出的行）；无则为 nil。
    public let relatedText: String?

    public init(message: String, relatedText: String? = nil) {
        self.message = message
        self.relatedText = relatedText
    }
}

/// 配对对照区一行：原文 + 译文（nil = 未配到）+ 行级警告（nil = 无）。
public struct BilingualPairRow: Equatable, Sendable {
    public let originalText: String
    public let translationText: String?
    public let warningMessage: String?

    public init(originalText: String, translationText: String?, warningMessage: String? = nil) {
        self.originalText = originalText
        self.translationText = translationText
        self.warningMessage = warningMessage
    }
}

/// 双语映射结果：应用策略后的文档与统计。
public struct BilingualMappingOutcome: Equatable, Sendable {
    /// 应用策略后的文档（输入为 off 时与解析产物相同）。
    public let document: LyricDocument
    public let mode: BilingualMode
    public let warnings: [BilingualWarning]
    /// 原文行数（结果文档行数，含空行边界与未打轴行）。
    public let originalLineCount: Int
    /// 配到译文的行数。
    public let translatedLineCount: Int
    /// 对照区数据（按结果文档行序）。
    public let pairRows: [BilingualPairRow]
}

public enum BilingualImportMapper {

    /// 导入译文写入的语言键（与播放面板/编辑器使用的 "zh-Hans" 一致）。
    public static let translationLanguageKey = "zh-Hans"

    /// 应用双语策略（纯函数、幂等）。mode = .off 时文档原样返回、无警告。
    public static func apply(
        mode: BilingualMode,
        to document: LyricDocument
    ) -> BilingualMappingOutcome {
        switch mode {
        case .off:
            return BilingualMappingOutcome(
                document: document,
                mode: .off,
                warnings: [],
                originalLineCount: document.lines.count,
                translatedLineCount: 0,
                pairRows: []
            )
        case .pairedTimestamps:
            return applyPairedTimestamps(to: document)
        case .inlineSeparator(let separator):
            return applyInlineSeparator(separator, to: document)
        }
    }

    /// 是否存在可成对行组：LRC 且至少一个同时间戳组含 ≥2 个非空行。
    /// 「成对」选项是否可用以此为准（纯文本或无同时间戳组时置灰）。
    public static func hasPairableGroups(_ document: LyricDocument) -> Bool {
        guard document.sourceFormat == .lrc else { return false }
        return timedRuns(in: document.lines).contains { run in
            run.filter { !$0.text.isEmpty }.count >= 2
        }
    }

    // MARK: - 同时间戳成对

    /// 成对模式规则：
    /// - 对解析产物中同 startMs 的行组（文档已归一：sourceOffsetMs 在文档上、
    ///   组内顺序即原输入顺序；offset 对全文档统一，分组等价于按 effectiveStart）。
    /// - 组内第一非空行 = 原文；其余非空行中第一行 = 译文，移入该行
    ///   translations["zh-Hans"]（不再作为独立歌词行）；更多非空行 = 警告，
    ///   文本保留在警告里，不静默丢弃。
    /// - 空文本行（清屏/间奏边界）跳过配对、原样保留。
    /// - 未打轴行（含纯文本文档）不参与成对：原样保留、无警告。
    /// - 整个文档没有任何配对发生时，给一条文档级警告（纯文本/无组各一文案）。
    private static func applyPairedTimestamps(to document: LyricDocument) -> BilingualMappingOutcome {
        var warnings: [BilingualWarning] = []
        var pairRows: [BilingualPairRow] = []
        var newLines: [LyricLine] = []
        var translatedCount = 0
        var run: [LyricLine] = []

        // 处理一个同时间戳组：返回保留行；译文/警告经 inout 累积。
        func flush() {
            guard !run.isEmpty else { return }
            let nonEmpty = run.filter { !$0.text.isEmpty }
            var keep = run
            if nonEmpty.count >= 2 {
                var original = nonEmpty[0]
                original.translations[translationLanguageKey] = Translation(
                    text: nonEmpty[1].text, source: .imported, needsReview: false
                )
                translatedCount += 1
                var rowWarning: String?
                if nonEmpty.count > 2 {
                    let extras = Array(nonEmpty[2...])
                    let joined = extras.map(\.text).joined(separator: " / ")
                    rowWarning = "同时间戳组多出 \(extras.count) 行未自动配对（内容保留在警告中）"
                    warnings.append(BilingualWarning(
                        message: "\(rowWarning!)：「\(joined)」", relatedText: joined
                    ))
                }
                // 原文行替换为挂好译文的版本；译文行与多余行移出歌词行。
                keep = run.compactMap { line in
                    if line.id == original.id { return original }
                    return nonEmpty.contains { $0.id == line.id } ? nil : line
                }
                pairRows.append(BilingualPairRow(
                    originalText: original.text,
                    translationText: nonEmpty[1].text,
                    warningMessage: rowWarning
                ))
            } else {
                for line in run {
                    pairRows.append(BilingualPairRow(
                        originalText: line.text, translationText: nil, warningMessage: nil
                    ))
                }
            }
            newLines.append(contentsOf: keep)
            run = []
        }

        for line in document.lines {
            guard let start = line.startMs else {
                flush()
                // 未打轴行不参与成对模式（文档化行为）：原样保留。
                newLines.append(line)
                pairRows.append(BilingualPairRow(
                    originalText: line.text, translationText: nil, warningMessage: nil
                ))
                continue
            }
            if let first = run.first?.startMs, first != start {
                flush()
            }
            run.append(line)
        }
        flush()

        if translatedCount == 0 {
            warnings.insert(noPairableGroupWarning(for: document), at: 0)
        }
        return BilingualMappingOutcome(
            document: copy(document, lines: newLines),
            mode: .pairedTimestamps,
            warnings: warnings,
            originalLineCount: newLines.count,
            translatedLineCount: translatedCount,
            pairRows: pairRows
        )
    }

    private static func noPairableGroupWarning(for document: LyricDocument) -> BilingualWarning {
        if document.sourceFormat == .text {
            return BilingualWarning(
                message: "本文档为纯文本（无时间戳），成对模式不适用，未产生任何译文；请改用「同行分隔符」模式。",
                relatedText: nil
            )
        }
        return BilingualWarning(
            message: "本文档没有同时间戳的行组，成对模式未产生任何译文；如为双语 LRC 请检查文件或改用「同行分隔符」模式。",
            relatedText: nil
        )
    }

    // MARK: - 同行分隔符

    /// 分隔符模式规则：逐行（含纯文本行）按分隔符
    /// 「首次出现」切分；前段 = 原文，后段 = 译文（后段再含分隔符全部归译文）；
    /// 两侧 trim。译文为空 → 警告 + 仅保留原文；原文为空 → 警告 + 整行原样保留
    /// （不猜测内容归属）；无分隔符 → 原样保留（单语句子是正常情形，不告警）。
    private static func applyInlineSeparator(
        _ separator: InlineSeparator,
        to document: LyricDocument
    ) -> BilingualMappingOutcome {
        var warnings: [BilingualWarning] = []
        var pairRows: [BilingualPairRow] = []
        var newLines: [LyricLine] = []
        var translatedCount = 0

        for line in document.lines {
            guard let splitRange = line.text.range(of: separator.rawValue) else {
                newLines.append(line)
                pairRows.append(BilingualPairRow(
                    originalText: line.text, translationText: nil, warningMessage: nil
                ))
                continue
            }
            let head = String(line.text[..<splitRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // 后段可再含分隔符：首次出现之后的全部内容都归译文。
            let tail = String(line.text[splitRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if head.isEmpty {
                let message = "分隔符「\(separator.rawValue)」前没有原文，该行未拆分：「\(line.text)」"
                warnings.append(BilingualWarning(message: message, relatedText: line.text))
                newLines.append(line)
                pairRows.append(BilingualPairRow(
                    originalText: line.text, translationText: nil, warningMessage: message
                ))
                continue
            }
            var mapped = line
            mapped.text = head
            if tail.isEmpty {
                let message = "分隔符「\(separator.rawValue)」后没有译文，该行仅保留原文：「\(head)」"
                warnings.append(BilingualWarning(message: message, relatedText: head))
                pairRows.append(BilingualPairRow(
                    originalText: head, translationText: nil, warningMessage: message
                ))
            } else {
                mapped.translations[translationLanguageKey] = Translation(
                    text: tail, source: .imported, needsReview: false
                )
                translatedCount += 1
                pairRows.append(BilingualPairRow(
                    originalText: head, translationText: tail, warningMessage: nil
                ))
            }
            newLines.append(mapped)
        }

        return BilingualMappingOutcome(
            document: copy(document, lines: newLines),
            mode: .inlineSeparator(separator),
            warnings: warnings,
            originalLineCount: newLines.count,
            translatedLineCount: translatedCount,
            pairRows: pairRows
        )
    }

    // MARK: - 行组工具

    /// 按相等 startMs 把打轴行切分为连续组；未打轴行打断分组（不属于任何组）。
    /// 解析产物已归一（打轴行按时间稳定排序、同 startMs 相邻），本函数不排序、
    /// 只分组，保持输入顺序。
    private static func timedRuns(in lines: [LyricLine]) -> [[LyricLine]] {
        var runs: [[LyricLine]] = []
        var current: [LyricLine] = []
        for line in lines {
            guard let start = line.startMs else {
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
                continue
            }
            if let first = current.first?.startMs, first != start {
                runs.append(current)
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    /// 以指定行集合重建文档（其余字段原样保留，含 id/revision/offset/元信息/时间戳）。
    private static func copy(_ document: LyricDocument, lines: [LyricLine]) -> LyricDocument {
        LyricDocument(
            id: document.id,
            revision: document.revision,
            sourceLanguage: document.sourceLanguage,
            sourceFormat: document.sourceFormat,
            sourceOffsetMs: document.sourceOffsetMs,
            originalText: document.originalText,
            originalFilename: document.originalFilename,
            metadata: document.metadata,
            lines: lines,
            createdAt: document.createdAt,
            updatedAt: document.updatedAt
        )
    }
}
