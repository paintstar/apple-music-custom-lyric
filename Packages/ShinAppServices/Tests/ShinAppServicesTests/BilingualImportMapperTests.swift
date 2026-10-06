import Foundation
import Testing
import ShinAppleKit
import ShinAppleData
@testable import ShinAppServices

// 双语 LRC 导入测试：翻译经明确绑定，不按数组位置猜测。
// 全部夹具为原创虚构文本（「测试原文/译文」系列），
// 不复制任何真实歌词。
//
// 本文件：双语导入策略层纯函数（BilingualImportMapper）；
// 会话/预览与重算竞争见 BilingualImportSessionTests.swift。

// MARK: - 夹具（原创虚构；策略层与会话层测试共用）

enum BilingualFixture {

    /// 典型成对 LRC：两组、每组「原文 + 译文」。
    static let pairedLrcText = """
    [00:01.000]测试原文甲
    [00:01.000]测试译文甲
    [00:03.000]测试原文乙
    [00:03.000]测试译文乙
    """

    /// 组内 3 行：1 原文 + 1 译文 + 1 多出行（应得警告，文本保留在警告中）。
    static let tripleLineGroupLrcText = """
    [00:01.000]测试原文甲
    [00:01.000]测试译文甲
    [00:01.000]多出行测试文本
    """

    /// 组内含空行边界（清屏行）：空行跳过配对、原样保留。
    static let emptyLineInGroupLrcText = """
    [00:01.000]测试原文甲
    [00:01.000]
    [00:01.000]测试译文甲
    """

    /// 成对 + 未打轴行：未打轴行不参与成对。
    static let pairedWithUntimedLrcText = """
    [00:01.000]测试原文甲
    [00:01.000]测试译文甲
    未打轴补记测试文本
    """

    /// 无同时间戳组的 LRC（成对模式应给文档级警告、行不变）。
    static let noGroupLrcText = """
    [00:01.000]第一句测试文本
    [00:02.000]第二句测试文本
    """

    /// 四种分隔符各占一行（服务层用例按单分隔符模式处理）。
    static let separatorLinesLrcText = """
    [00:01.000]测试原文甲//测试译文甲
    [00:02.000]测试原文乙/测试译文乙
    [00:03.000]测试原文丙｜测试译文丙
    [00:04.000]测试原文丁|测试译文丁
    """

    /// 译文内再含分隔符：首次出现切分，其余全归译文。
    static let repeatedSeparatorLrcText = "[00:01.000]测试原文甲//译//文\n"

    /// 两侧空白的分隔行（trim 行为）。
    static let paddedSeparatorLrcText = "[00:01.000]  测试原文甲  //  测试译文甲  \n"

    /// 分隔符后无译文。
    static let emptyTranslationLrcText = "[00:01.000]测试原文甲//\n"

    /// 分隔符前无原文。
    static let emptyOriginalLrcText = "[00:01.000]//测试译文甲\n"

    /// 纯文本（逐行分隔符应生效；成对模式应给文档级警告）。
    static let plainText = """
    测试原文甲//测试译文甲
    测试原文乙//测试译文乙
    """

    /// 竞争测试夹具：同一文件在成对模式下译文为「成对译文测试X」，
    /// 在 // 分隔符模式下译文为「分隔译文测试X」——两种结果可区分。
    static let raceLrcText = """
    [00:01.000]测试原文甲//分隔译文测试甲
    [00:01.000]成对译文测试甲
    [00:03.000]测试原文乙//分隔译文测试乙
    [00:03.000]成对译文测试乙
    """

    static func document(_ text: String) -> LyricDocument {
        do {
            return try LyricsParser.parse(Data(text.utf8)).document
        } catch {
            fatalError("双语测试夹具必须可解析：\(error)")
        }
    }

    static func outcome(_ text: String, mode: BilingualMode) -> BilingualMappingOutcome {
        BilingualImportMapper.apply(mode: mode, to: document(text))
    }
}

// MARK: - 策略层纯函数

@Suite("双语导入策略层")
struct BilingualImportMapperTests {

    // MARK: .off 回归

    @Test("off：文档与解析产物完全一致，零警告零译文（现状不变）")
    func offKeepsDocumentUntouched() {
        let document = BilingualFixture.document(BilingualFixture.pairedLrcText)
        let outcome = BilingualImportMapper.apply(mode: .off, to: document)
        #expect(outcome.document == document)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.translatedLineCount == 0)
        #expect(outcome.pairRows.isEmpty)
        for line in outcome.document.lines {
            #expect(line.translations.isEmpty)
        }
    }

    // MARK: 同时间戳成对

    @Test("成对：典型成对——组内首非空行=原文，第二非空行=译文并移出行列表")
    func typicalPairedGroups() {
        let outcome = BilingualFixture.outcome(BilingualFixture.pairedLrcText, mode: .pairedTimestamps)
        #expect(outcome.document.lines.count == 2)
        #expect(outcome.translatedLineCount == 2)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.originalLineCount == 2)
        let first = outcome.document.lines[0]
        #expect(first.text == "测试原文甲")
        #expect(first.startMs == 1_000)
        #expect(first.translations[BilingualImportMapper.translationLanguageKey] == Translation(
            text: "测试译文甲", source: .imported, needsReview: false
        ))
        let second = outcome.document.lines[1]
        #expect(second.text == "测试原文乙")
        #expect(second.translations[BilingualImportMapper.translationLanguageKey]?.text == "测试译文乙")
        #expect(outcome.pairRows == [
            BilingualPairRow(originalText: "测试原文甲", translationText: "测试译文甲"),
            BilingualPairRow(originalText: "测试原文乙", translationText: "测试译文乙")
        ])
    }

    @Test("成对：组内 3 行——1 原文 + 1 译文 + 1 警告，多出行文本保留在警告里")
    func extraLineInGroupBecomesWarning() {
        let outcome = BilingualFixture.outcome(BilingualFixture.tripleLineGroupLrcText, mode: .pairedTimestamps)
        #expect(outcome.document.lines.count == 1)
        #expect(outcome.translatedLineCount == 1)
        #expect(outcome.warnings.count == 1)
        let warning = outcome.warnings[0]
        #expect(warning.message.contains("多出行测试文本"))
        #expect(warning.relatedText == "多出行测试文本")
        #expect(outcome.document.lines[0].text == "测试原文甲")
        #expect(outcome.document.lines[0].translations[BilingualImportMapper.translationLanguageKey]?.text == "测试译文甲")
        #expect(outcome.pairRows[0].warningMessage != nil)
    }

    @Test("成对：组内空行（清屏边界）跳过配对且原样保留")
    func emptyLinesInGroupAreSkipped() {
        let outcome = BilingualFixture.outcome(BilingualFixture.emptyLineInGroupLrcText, mode: .pairedTimestamps)
        #expect(outcome.translatedLineCount == 1)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.document.lines.count == 2)
        #expect(outcome.document.lines[0].text == "测试原文甲")
        #expect(outcome.document.lines[0].translations[BilingualImportMapper.translationLanguageKey]?.text == "测试译文甲")
        #expect(outcome.document.lines[1].text.isEmpty)
        #expect(outcome.document.lines[1].startMs == 1_000)
    }

    @Test("成对：未打轴行不参与配对——原样保留、无译文、无警告")
    func untimedLinesDoNotParticipate() {
        let outcome = BilingualFixture.outcome(BilingualFixture.pairedWithUntimedLrcText, mode: .pairedTimestamps)
        #expect(outcome.translatedLineCount == 1)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.document.lines.count == 2)
        let untimed = outcome.document.lines[1]
        #expect(untimed.startMs == nil)
        #expect(untimed.text == "未打轴补记测试文本")
        #expect(untimed.translations.isEmpty)
        #expect(outcome.pairRows[1].translationText == nil)
        #expect(outcome.pairRows[1].warningMessage == nil)
    }

    @Test("成对：纯文本文档 → 文档级警告、行不变（确定行为，已文档化）")
    func plainTextDocumentGetsDocumentLevelWarning() {
        let document = BilingualFixture.document(BilingualFixture.plainText)
        let outcome = BilingualImportMapper.apply(mode: .pairedTimestamps, to: document)
        #expect(outcome.document.lines == document.lines)
        #expect(outcome.translatedLineCount == 0)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].message.contains("纯文本"))
        #expect(BilingualImportMapper.hasPairableGroups(document) == false)
    }

    @Test("成对：无同时间戳组的 LRC → 文档级警告、行不变")
    func lrcWithoutGroupsGetsDocumentLevelWarning() {
        let document = BilingualFixture.document(BilingualFixture.noGroupLrcText)
        let outcome = BilingualImportMapper.apply(mode: .pairedTimestamps, to: document)
        #expect(outcome.document.lines == document.lines)
        #expect(outcome.translatedLineCount == 0)
        #expect(outcome.warnings.count == 1)
        #expect(outcome.warnings[0].message.contains("同时间戳"))
    }

    // MARK: 同行分隔符

    /// 单分隔符用例（结构体避免大元组；每个用例用独立单行文档）。
    private struct SeparatorCase {
        let text: String
        let separator: InlineSeparator
        let original: String
        let translation: String
    }

    @Test("分隔符：四种分隔符各一例（//、/、｜、|）")
    func allFourSeparators() {
        // 每个分隔符用独立单行文档：同一文档混用多种分隔符时，
        // 「首次出现」规则会让更短的分隔符也命中（如 / 命中 // 的第一个斜杠），
        // 那是指定行为的正确结果，不适合作为本用例的对照。
        let cases: [SeparatorCase] = [
            SeparatorCase(
                text: "[00:01.000]测试原文甲//测试译文甲\n", separator: .doubleSlash,
                original: "测试原文甲", translation: "测试译文甲"
            ),
            SeparatorCase(
                text: "[00:02.000]测试原文乙/测试译文乙\n", separator: .singleSlash,
                original: "测试原文乙", translation: "测试译文乙"
            ),
            SeparatorCase(
                text: "[00:03.000]测试原文丙｜测试译文丙\n", separator: .fullWidthPipe,
                original: "测试原文丙", translation: "测试译文丙"
            ),
            SeparatorCase(
                text: "[00:04.000]测试原文丁|测试译文丁\n", separator: .pipe,
                original: "测试原文丁", translation: "测试译文丁"
            )
        ]
        for item in cases {
            let outcome = BilingualFixture.outcome(item.text, mode: .inlineSeparator(item.separator))
            #expect(outcome.document.lines.count == 1)
            #expect(outcome.translatedLineCount == 1, "分隔符 \(item.separator.rawValue)")
            #expect(outcome.warnings.isEmpty, "分隔符 \(item.separator.rawValue)")
            let translated = outcome.document.lines[0]
            #expect(translated.text == item.original, "分隔符 \(item.separator.rawValue)")
            #expect(
                translated.translations[BilingualImportMapper.translationLanguageKey]?.text == item.translation,
                "分隔符 \(item.separator.rawValue)"
            )
        }
    }

    @Test("分隔符：按首次出现切分，译文内再含分隔符全部归译文")
    func firstOccurrenceSplitRestGoesToTranslation() {
        let outcome = BilingualFixture.outcome(
            BilingualFixture.repeatedSeparatorLrcText, mode: .inlineSeparator(.doubleSlash)
        )
        #expect(outcome.translatedLineCount == 1)
        #expect(outcome.warnings.isEmpty)
        let line = outcome.document.lines[0]
        #expect(line.text == "测试原文甲")
        #expect(line.translations[BilingualImportMapper.translationLanguageKey]?.text == "译//文")
    }

    @Test("分隔符：两侧 trim")
    func bothSidesAreTrimmed() {
        let outcome = BilingualFixture.outcome(
            BilingualFixture.paddedSeparatorLrcText, mode: .inlineSeparator(.doubleSlash)
        )
        #expect(outcome.translatedLineCount == 1)
        #expect(outcome.document.lines[0].text == "测试原文甲")
        #expect(outcome.document.lines[0].translations[BilingualImportMapper.translationLanguageKey]?.text == "测试译文甲")
    }

    @Test("分隔符：译文为空 → 警告 + 仅保留原文")
    func emptyTranslationWarnsAndKeepsOriginal() {
        let outcome = BilingualFixture.outcome(
            BilingualFixture.emptyTranslationLrcText, mode: .inlineSeparator(.doubleSlash)
        )
        #expect(outcome.translatedLineCount == 0)
        #expect(outcome.warnings.count == 1)
        let line = outcome.document.lines[0]
        #expect(line.text == "测试原文甲")
        #expect(line.translations.isEmpty)
        #expect(outcome.pairRows[0].warningMessage != nil)
    }

    @Test("分隔符：原文为空 → 警告 + 整行原样保留（不猜测内容归属）")
    func emptyOriginalWarnsAndKeepsLine() {
        let document = BilingualFixture.document(BilingualFixture.emptyOriginalLrcText)
        let outcome = BilingualImportMapper.apply(mode: .inlineSeparator(.doubleSlash), to: document)
        #expect(outcome.translatedLineCount == 0)
        #expect(outcome.warnings.count == 1)
        // 整行原样保留：同一行实例（id 不变）、文本不变、无译文。
        #expect(outcome.document.lines.count == 1)
        #expect(outcome.document.lines[0].id == document.lines[0].id)
        #expect(outcome.document.lines[0].text == "//测试译文甲")
        #expect(outcome.document.lines[0].translations.isEmpty)
        #expect(outcome.pairRows[0].warningMessage != nil)
    }

    @Test("分隔符：纯文本文档逐行生效")
    func plainTextLinesAreProcessedLineByLine() {
        let outcome = BilingualFixture.outcome(BilingualFixture.plainText, mode: .inlineSeparator(.doubleSlash))
        #expect(outcome.document.lines.count == 2)
        #expect(outcome.translatedLineCount == 2)
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.document.lines[0].translations[BilingualImportMapper.translationLanguageKey]?.text == "测试译文甲")
        #expect(outcome.document.lines[1].translations[BilingualImportMapper.translationLanguageKey]?.text == "测试译文乙")
    }

    // MARK: 成对可用性

    @Test("hasPairableGroups：仅 LRC 且存在 ≥2 非空行的同时间戳组时可用")
    func pairableGroupDetection() {
        #expect(BilingualImportMapper.hasPairableGroups(
            BilingualFixture.document(BilingualFixture.pairedLrcText)
        ))
        #expect(!BilingualImportMapper.hasPairableGroups(
            BilingualFixture.document(BilingualFixture.plainText)
        ))
        #expect(!BilingualImportMapper.hasPairableGroups(
            BilingualFixture.document(BilingualFixture.noGroupLrcText)
        ))
    }

    // MARK: 幂等

    @Test("映射幂等：同一输入重复应用结果相同（策略永远基于原始解析产物）")
    func mappingIsDeterministic() {
        let document = BilingualFixture.document(BilingualFixture.raceLrcText)
        let first = BilingualImportMapper.apply(mode: .pairedTimestamps, to: document)
        let second = BilingualImportMapper.apply(mode: .pairedTimestamps, to: document)
        #expect(first == second)
    }
}
