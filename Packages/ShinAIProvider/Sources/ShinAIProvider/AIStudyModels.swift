import Foundation
import ShinAppleKit

/// AI 词汇释义结果（语境释义 + 通用释义 + 例句）。
public struct AIWordExplanation: Codable, Equatable, Sendable {
    public var surface: String
    public var lemma: String
    public var reading: String
    public var partOfSpeech: String
    public var contextualMeaning: String
    public var generalMeaning: String
    public var examples: [VocabularyExample]

    public init(
        surface: String,
        lemma: String,
        reading: String = "",
        partOfSpeech: String = "",
        contextualMeaning: String,
        generalMeaning: String,
        examples: [VocabularyExample] = []
    ) {
        self.surface = surface
        self.lemma = lemma
        self.reading = reading
        self.partOfSpeech = partOfSpeech
        self.contextualMeaning = contextualMeaning
        self.generalMeaning = generalMeaning
        self.examples = examples
    }

    private enum CodingKeys: String, CodingKey {
        case surface
        case lemma
        case reading
        case partOfSpeech
        case contextualMeaning
        case generalMeaning
        case examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.surface = try container.decode(String.self, forKey: .surface)
        self.lemma = try container.decode(String.self, forKey: .lemma)
        self.reading = try container.decodeIfPresent(String.self, forKey: .reading) ?? ""
        self.partOfSpeech = try container.decodeIfPresent(String.self, forKey: .partOfSpeech) ?? ""
        self.contextualMeaning = try container.decode(String.self, forKey: .contextualMeaning)
        self.generalMeaning = try container.decode(String.self, forKey: .generalMeaning)
        self.examples = try container.decodeIfPresent([VocabularyExample].self, forKey: .examples) ?? []
    }
}

/// AI 单行歌词句法与背景解析结果。
public struct AILineExplanation: Codable, Equatable, Sendable {
    public var grammarSummary: String
    public var keyExpressions: [String]
    public var singingTips: String?
    public var culturalNote: String?

    public init(
        grammarSummary: String,
        keyExpressions: [String] = [],
        singingTips: String? = nil,
        culturalNote: String? = nil
    ) {
        self.grammarSummary = grammarSummary
        self.keyExpressions = keyExpressions
        self.singingTips = singingTips
        self.culturalNote = culturalNote
    }

    private enum CodingKeys: String, CodingKey {
        case grammarSummary
        case keyExpressions
        case singingTips
        case culturalNote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.grammarSummary = try container.decode(String.self, forKey: .grammarSummary)
        self.keyExpressions = try container.decodeIfPresent([String].self, forKey: .keyExpressions) ?? []
        self.singingTips = try container.decodeIfPresent(String.self, forKey: .singingTips)
        self.culturalNote = try container.decodeIfPresent(String.self, forKey: .culturalNote)
    }
}

/// 批量注音的单行结果，按 `LyricLine.id` 对齐。
public struct AIPronunciationLineItem: Codable, Equatable, Sendable {
    public var lineId: UUID
    public var pronunciation: String

    public init(lineId: UUID, pronunciation: String) {
        self.lineId = lineId
        self.pronunciation = pronunciation
    }
}

/// 批量翻译的单行结果，按 `LyricLine.id` 对齐。
public struct AITranslationLineItem: Codable, Equatable, Sendable {
    public var lineId: UUID
    public var translation: String

    public init(lineId: UUID, translation: String) {
        self.lineId = lineId
        self.translation = translation
    }
}

/// AI 提取的整首关键学习点 / 推荐生词。
public struct AIKeyStudyPoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var lineId: UUID?
    public var surface: String
    public var lemma: String
    public var reading: String?
    public var partOfSpeech: String?
    public var contextualMeaning: String
    public var generalMeaning: String

    public init(
        id: UUID = UUID(),
        lineId: UUID? = nil,
        surface: String,
        lemma: String,
        reading: String? = nil,
        partOfSpeech: String? = nil,
        contextualMeaning: String,
        generalMeaning: String
    ) {
        self.id = id
        self.lineId = lineId
        self.surface = surface
        self.lemma = lemma
        self.reading = reading
        self.partOfSpeech = partOfSpeech
        self.contextualMeaning = contextualMeaning
        self.generalMeaning = generalMeaning
    }
}

/// 设置页「测试连接」的返回摘要。
public struct AIConnectionTestResult: Codable, Equatable, Sendable {
    public var latencyMs: Int
    public var model: String
    public var replyPreview: String

    public init(latencyMs: Int, model: String, replyPreview: String) {
        self.latencyMs = latencyMs
        self.model = model
        self.replyPreview = replyPreview
    }
}

/// AI 推测的歌词搜索原曲名候选条目。
public struct AISearchQuerySuggestion: Codable, Equatable, Sendable, Identifiable {
    public var title: String
    public var artist: String?
    public var reason: String?

    public var id: String { "\(title)|\(artist ?? "")" }

    public init(
        title: String,
        artist: String? = nil,
        reason: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.reason = reason
    }
}

/// AI 学习服务调用或配置错误，提供面向界面展示的清晰中文说明。
public enum AIProviderError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey(preset: AIProviderPreset)
    case invalidEndpoint(String)
    case invalidConfiguration(String)
    case httpError(statusCode: Int, message: String?)
    case networkError(String)
    case invalidResponse(String)
    case emptyResult(String)
    case keychainError(status: Int32)

    public var errorDescription: String? { userMessage }

    public var userMessage: String {
        switch self {
        case .missingAPIKey(let preset):
            return "尚未配置「\(preset.displayName)」的 API Key，请先在设置中保存密钥。"
        case .invalidEndpoint(let detail):
            return "AI 服务地址无效：\(detail)"
        case .invalidConfiguration(let detail):
            return "AI 服务配置无效：\(detail)"
        case .httpError(let statusCode, let message):
            let suffix = message.flatMap { trimmed -> String? in
                let clean = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : "（\(clean)）"
            } ?? ""
            switch statusCode {
            case 401:
                return "认证失败（HTTP 401）：API Key 无效或已过期\(suffix)。"
            case 403:
                return "访问被拒绝（HTTP 403）：无权限调用当前模型或接口\(suffix)。"
            case 404:
                return "接口或模型不存在（HTTP 404）：请检查 Base URL 与模型名称\(suffix)。"
            case 429:
                return "请求过于频繁或额度不足（HTTP 429）：请稍后再试\(suffix)。"
            default:
                return "AI 服务返回异常状态（HTTP \(statusCode)）\(suffix)。"
            }
        case .networkError(let detail):
            return "网络连接失败：\(detail)"
        case .invalidResponse(let detail):
            return "AI 响应 JSON 解析失败：\(detail)"
        case .emptyResult(let detail):
            return "AI 返回结果为空：\(detail)"
        case .keychainError(let status):
            return "系统钥匙串读写失败（状态码 \(status)）。"
        }
    }
}

/// 单行歌词上下文，用于辅助句法解析。
public struct AILineContext: Equatable, Sendable {
    public var previousLine: String?
    public var nextLine: String?
    public var sourceLanguage: String?

    public init(
        previousLine: String? = nil,
        nextLine: String? = nil,
        sourceLanguage: String? = nil
    ) {
        self.previousLine = previousLine
        self.nextLine = nextLine
        self.sourceLanguage = sourceLanguage
    }
}

/// AI 歌词学习服务协议，便于服务层与 UI 注入真实客户端或 Mock 实现。
public protocol AIStudyProviding: Sendable {
    func testConnection(
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIConnectionTestResult

    func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIWordExplanation

    func explainLine(
        _ lineText: String,
        context: AILineContext,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AILineExplanation

    func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIPronunciationLineItem]

    func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AITranslationLineItem]

    func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIKeyStudyPoint]

    func suggestLyricsSearchQueries(
        title: String,
        artist: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AISearchQuerySuggestion]
}

public extension AIStudyProviding {
    func testConnection(configuration: AIConfiguration) async throws -> AIConnectionTestResult {
        try await testConnection(configuration: configuration, apiKey: nil)
    }

    func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        configuration: AIConfiguration
    ) async throws -> AIWordExplanation {
        var resolved = configuration
        if let targetLanguage { resolved.preferredTargetLanguage = targetLanguage }
        return try await explainWord(
            word,
            inLine: lineText,
            sourceLanguage: sourceLanguage,
            configuration: resolved,
            apiKey: nil
        )
    }

    func explainLine(
        _ lineText: String,
        previousLine: String? = nil,
        nextLine: String? = nil,
        sourceLanguage: String? = nil,
        configuration: AIConfiguration
    ) async throws -> AILineExplanation {
        try await explainLine(
            lineText,
            context: AILineContext(
                previousLine: previousLine,
                nextLine: nextLine,
                sourceLanguage: sourceLanguage
            ),
            configuration: configuration,
            apiKey: nil
        )
    }

    func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle? = nil,
        sourceLanguage: String? = nil,
        configuration: AIConfiguration
    ) async throws -> [AIPronunciationLineItem] {
        try await generatePronunciations(
            for: lines,
            style: style ?? configuration.preferredPronunciationStyle,
            sourceLanguage: sourceLanguage,
            configuration: configuration,
            apiKey: nil
        )
    }

    func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        configuration: AIConfiguration
    ) async throws -> [AITranslationLineItem] {
        var resolved = configuration
        if let targetLanguage { resolved.preferredTargetLanguage = targetLanguage }
        return try await generateTranslations(
            for: lines,
            sourceLanguage: sourceLanguage,
            configuration: resolved,
            apiKey: nil
        )
    }

    func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        configuration: AIConfiguration
    ) async throws -> [AIKeyStudyPoint] {
        var resolved = configuration
        if let targetLanguage { resolved.preferredTargetLanguage = targetLanguage }
        return try await extractKeyStudyPoints(
            from: lines,
            sourceLanguage: sourceLanguage,
            configuration: resolved,
            apiKey: nil
        )
    }

    func suggestLyricsSearchQueries(
        title: String,
        artist: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AISearchQuerySuggestion] {
        []
    }

    func suggestLyricsSearchQueries(
        title: String,
        artist: String? = nil,
        configuration: AIConfiguration
    ) async throws -> [AISearchQuerySuggestion] {
        try await suggestLyricsSearchQueries(
            title: title,
            artist: artist,
            configuration: configuration,
            apiKey: nil
        )
    }
}
