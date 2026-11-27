import Foundation
import ShinAIProvider
import ShinAppleKit

/// 模拟模式下的学习解析客户端：提供虚构的日语/英语词句解析，绝不发送网络请求或读取钥匙串。
final class MockStudyDetailAIClient: AIStudyProviding, Sendable {
    func testConnection(
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: "mock-study", replyPreview: "模拟连接正常")
    }

    func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIWordExplanation {
        try await Task.sleep(for: .milliseconds(120))
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = lineText
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? cleanWord
        if Self.isJapanese(word: cleanWord, line: firstLine, sourceLanguage: sourceLanguage) {
            return AIWordExplanation(
                surface: cleanWord,
                lemma: cleanWord,
                reading: "よみかた（模拟）",
                partOfSpeech: "名词 / 动词（模拟）",
                contextualMeaning: "在「\(firstLine)」中，该词承接前后句意象，强调画面感与情绪流动（模拟解析）。",
                generalMeaning: "表示与「\(cleanWord)」相关的核心动作或事物概念（模拟通用释义）。",
                examples: [
                    VocabularyExample(
                        text: "静かな夜に\(cleanWord)を思い出す。",
                        translation: "在宁静的夜晚回想起这个画面（模拟例句）。"
                    ),
                    VocabularyExample(
                        text: "次のページへ\(cleanWord)のように進む。",
                        translation: "如同歌词所写般迈向下一页（模拟例句）。"
                    )
                ]
            )
        }
        let lower = cleanWord.lowercased()
        return AIWordExplanation(
            surface: cleanWord,
            lemma: lower,
            reading: "/mɒk/",
            partOfSpeech: "动词 / 名词（模拟）",
            contextualMeaning: "In \"\(firstLine)\", \"\(cleanWord)\" carries a figurative lyrical nuance (mock).",
            generalMeaning: "表示「\(cleanWord)」在日常与书面语境下的基础含义（模拟通用释义）。",
            examples: [
                VocabularyExample(
                    text: "We keep \(lower) in mind through every verse.",
                    translation: "我们在每一段旋律中都铭记这份意象（模拟例句）。"
                ),
                VocabularyExample(
                    text: "A quiet melody makes \(lower) easier to recall.",
                    translation: "柔和的旋律让这个词语更容易记住（模拟例句）。"
                )
            ]
        )
    }

    func explainLine(
        _ lineText: String,
        context: AILineContext,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AILineExplanation {
        try await Task.sleep(for: .milliseconds(150))
        let cleanLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isJapanese(word: cleanLine, line: cleanLine, sourceLanguage: context.sourceLanguage) {
            return AILineExplanation(
                grammarSummary: "本句（模拟解析）以核心谓语收束前面的修饰成分，常见于抒情段落的递进表达。",
                keyExpressions: ["助词衔接", "连体修饰结构", "抒情倒装"],
                singingTips: "长元音部分保持气息连贯，句末助词轻收即可（模拟提示）。",
                culturalNote: "日语歌词常借由自然或日常意象映射内心情绪变化（模拟背景）。"
            )
        }
        return AILineExplanation(
            grammarSummary: "本句（模拟解析）采用主谓宾与介词短语并置的抒情句式，重音落在句尾意象词上。",
            keyExpressions: ["介词短语修饰", "意象并列", "节奏重音"],
            singingTips: "辅音结尾与下一个元音之间可自然连读，尾音适度弱化收束（模拟提示）。",
            culturalNote: "英文歌词常以具象景物隐喻时间流逝或心境转折（模拟背景）。"
        )
    }

    func followUpLine(
        _ request: AILineFollowUpRequest,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        if let previous = request.history.last {
            return "承接上一问「\(previous.question)」，可以把它和「\(request.question)」一起放回本句，看修饰成分如何连接核心谓语。"
        }
        return "针对「\(request.question)」，可以先找本句的核心谓语，再结合前后句理解修饰成分的作用。"
    }

    func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIPronunciationLineItem] {
        []
    }

    func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AITranslationLineItem] {
        []
    }

    func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIKeyStudyPoint] {
        []
    }

    private static func isJapanese(word: String, line: String, sourceLanguage: String?) -> Bool {
        if let lang = sourceLanguage?.lowercased(), lang.hasPrefix("ja") {
            return true
        }
        let sample = word + line
        return sample.unicodeScalars.contains { scalar in
            (0x3040...0x309F).contains(scalar.value)
                || (0x30A0...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
