import Foundation
import ShinAIProvider
import ShinAppleKit

/// 模拟模式下的本地示例生成器：绝不发送任何真实网络请求，不读取钥匙串。
final class MockPreviewAIStudyClient: AIStudyProviding, Sendable {
    func testConnection(
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: "mock-study", replyPreview: "连接正常")
    }

    func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIWordExplanation {
        AIWordExplanation(surface: word, lemma: word, contextualMeaning: "模拟语境释义", generalMeaning: "模拟通用释义")
    }

    func explainLine(
        _ lineText: String,
        context: AILineContext,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AILineExplanation {
        AILineExplanation(grammarSummary: "模拟句法要点")
    }

    func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIPronunciationLineItem] {
        try await Task.sleep(for: .milliseconds(120))
        return lines.map { line in
            AIPronunciationLineItem(
                lineId: line.id,
                pronunciation: "[模拟\(style.displayName)] \(line.text)"
            )
        }
    }

    func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AITranslationLineItem] {
        try await Task.sleep(for: .milliseconds(120))
        return lines.map { line in
            AITranslationLineItem(
                lineId: line.id,
                translation: "[模拟译文] \(line.text)"
            )
        }
    }

    func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIKeyStudyPoint] {
        []
    }
}
