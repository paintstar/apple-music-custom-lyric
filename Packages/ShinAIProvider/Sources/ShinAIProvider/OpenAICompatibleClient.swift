import Foundation
import ShinAppleKit

/// OpenAI 兼容 `/chat/completions` HTTP 客户端。
/// 本文件是 `ShinAIProvider` 内唯一允许持有或调用 `URLSession` 的位置，
/// 默认构造 ephemeral 会话，并在测试时注入经 `URLProtocol` 拦截的会话。
public final class OpenAICompatibleClient: AIStudyProviding, Sendable {
    /// 默认单次请求超时（秒）：适配思考模型（如 `deepseek-reasoner`）与较长歌词批次。
    public static let defaultRequestTimeoutSeconds: TimeInterval = 120
    /// 默认资源总超时（秒）：允许慢响应模型完整返回结果。
    public static let defaultResourceTimeoutSeconds: TimeInterval = 300

    private let session: URLSession
    private let credentialStore: (any AICredentialStoring)?
    private let clock = ContinuousClock()

    public init(
        session: URLSession = OpenAICompatibleClient.makeDefaultSession(),
        credentialStore: (any AICredentialStoring)? = nil
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    /// 默认会话禁用 Cookie；测试可通过 `protocolClasses` 注入本地拦截器。
    public static func makeDefaultSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaultRequestTimeoutSeconds
        config.timeoutIntervalForResource = defaultResourceTimeoutSeconds
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        return URLSession(configuration: config)
    }

    // MARK: - AIStudyProviding

    public func testConnection(
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        let startedAt = clock.now
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: AIPromptBuilder.testConnectionMessages(),
                useJSONResponseFormat: false,
                maxTokens: 32
            )
        )
        let latencyMs = Self.milliseconds(from: clock.now - startedAt)
        return AIConnectionTestResult(
            latencyMs: latencyMs,
            model: completion.model ?? configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            replyPreview: String(completion.content.prefix(120))
        )
    }

    public func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIWordExplanation {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWord.isEmpty else {
            throw AIProviderError.invalidConfiguration("查询词语不能为空。")
        }
        let messages = AIPromptBuilder.explainWordMessages(
            word: cleanWord,
            lineText: lineText,
            sourceLanguage: sourceLanguage,
            targetLanguage: configuration.preferredTargetLanguage
        )
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: messages,
                useJSONResponseFormat: true,
                maxTokens: nil
            )
        )
        let explanation: AIWordExplanation = try OpenAICompatibleCodec.decodeStructuredContent(from: completion.content)
        guard !explanation.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !explanation.contextualMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !explanation.generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AIProviderError.emptyResult("词义解析结果缺少核心释义字段。")
        }
        return explanation
    }

    public func explainLine(
        _ lineText: String,
        context: AILineContext,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AILineExplanation {
        let cleanLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLine.isEmpty else {
            throw AIProviderError.invalidConfiguration("待解析歌词行不能为空。")
        }
        let messages = AIPromptBuilder.explainLineMessages(
            lineText: cleanLine,
            previousLine: context.previousLine,
            nextLine: context.nextLine,
            sourceLanguage: context.sourceLanguage,
            targetLanguage: configuration.preferredTargetLanguage
        )
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: messages,
                useJSONResponseFormat: true,
                maxTokens: nil
            )
        )
        let explanation: AILineExplanation = try OpenAICompatibleCodec.decodeStructuredContent(from: completion.content)
        guard !explanation.grammarSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyResult("句法解析结果缺少总结内容。")
        }
        return explanation
    }

    public func followUpLine(
        _ request: AILineFollowUpRequest,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> String {
        guard let cleanLine = OpenAICompatibleCodec.trimmedNilIfEmpty(request.lineText),
              let cleanQuestion = OpenAICompatibleCodec.trimmedNilIfEmpty(request.question) else {
            throw AIProviderError.invalidConfiguration("歌词行和追问不能为空。")
        }
        let cleanedRequest = AILineFollowUpRequest(
            lineText: cleanLine, context: request.context, analysis: request.analysis,
            history: request.history, question: cleanQuestion
        )
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: AIPromptBuilder.followUpLineMessages(
                    cleanedRequest,
                    targetLanguage: configuration.preferredTargetLanguage
                ),
                useJSONResponseFormat: false,
                maxTokens: nil
            )
        )
        guard let answer = OpenAICompatibleCodec.trimmedNilIfEmpty(completion.content) else {
            throw AIProviderError.emptyResult("整句追问缺少回答。")
        }
        return answer
    }

    public func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIPronunciationLineItem] {
        let nonEmptyLines = try Self.validatedNonEmptyLines(from: lines, emptyMessage: "没有可注音的非空歌词行。")
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: AIPromptBuilder.pronunciationMessages(
                    lines: nonEmptyLines,
                    style: style,
                    sourceLanguage: sourceLanguage
                ),
                useJSONResponseFormat: true,
                maxTokens: nil
            )
        )
        let rawItems: [AIPronunciationLineItem] = try OpenAICompatibleCodec.decodeItemsArray(from: completion.content)
        return try Self.filterLineItems(
            rawItems.map { ($0.lineId, $0.pronunciation) },
            validIDs: Set(nonEmptyLines.map(\.id)),
            emptyError: "未能匹配到有效的逐行注音结果。"
        ) { lineID, text in
            AIPronunciationLineItem(lineId: lineID, pronunciation: text)
        }
    }

    public func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AITranslationLineItem] {
        let nonEmptyLines = try Self.validatedNonEmptyLines(from: lines, emptyMessage: "没有可翻译的非空歌词行。")
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: AIPromptBuilder.translationMessages(
                    lines: nonEmptyLines,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: configuration.preferredTargetLanguage
                ),
                useJSONResponseFormat: true,
                maxTokens: nil
            )
        )
        let rawItems: [AITranslationLineItem] = try OpenAICompatibleCodec.decodeItemsArray(from: completion.content)
        return try Self.filterLineItems(
            rawItems.map { ($0.lineId, $0.translation) },
            validIDs: Set(nonEmptyLines.map(\.id)),
            emptyError: "未能匹配到有效的逐行译文结果。"
        ) { lineID, text in
            AITranslationLineItem(lineId: lineID, translation: text)
        }
    }

    public func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIKeyStudyPoint] {
        let nonEmptyLines = try Self.validatedNonEmptyLines(from: lines, emptyMessage: "没有可提取学习点的非空歌词行。")
        let validIDs = Set(nonEmptyLines.map(\.id))
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: AIPromptBuilder.keyStudyPointsMessages(
                    lines: nonEmptyLines,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: configuration.preferredTargetLanguage
                ),
                useJSONResponseFormat: true,
                maxTokens: nil
            )
        )
        let rawItems: [AIKeyStudyPointPayload] = try OpenAICompatibleCodec.decodeItemsArray(from: completion.content)
        let points: [AIKeyStudyPoint] = rawItems.compactMap { item in
            let surface = item.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let lemma = item.lemma.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextual = item.contextualMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
            let general = item.generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !surface.isEmpty, !contextual.isEmpty, !general.isEmpty else { return nil }
            let resolvedLineID = item.lineId.flatMap { validIDs.contains($0) ? $0 : nil }
            return AIKeyStudyPoint(
                id: item.id ?? UUID(),
                lineId: resolvedLineID,
                surface: surface,
                lemma: lemma.isEmpty ? surface : lemma,
                reading: OpenAICompatibleCodec.trimmedNilIfEmpty(item.reading),
                partOfSpeech: OpenAICompatibleCodec.trimmedNilIfEmpty(item.partOfSpeech),
                contextualMeaning: contextual,
                generalMeaning: general
            )
        }
        guard !points.isEmpty else {
            throw AIProviderError.emptyResult("未能从歌词中提取到有效学习点。")
        }
        return points
    }

    // MARK: - 网络请求调度

    private func requestCompletion(_ options: ChatRequestOptions) async throws -> AICompletionContent {
        guard session.configuration.identifier == nil else {
            throw AIProviderError.invalidConfiguration("AI 服务不支持自动跟随重定向的后台网络会话。")
        }
        let baseURL = try options.configuration.validatedBaseURL()
        let endpointURL = AIEndpointURL.chatCompletions(from: baseURL)
        let model = options.configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIProviderError.invalidConfiguration("请先填写模型名称。")
        }
        let resolvedKey = try resolveAPIKey(explicitKey: options.apiKey, preset: options.configuration.preset)
        let requestSpec = ResolvedChatRequest(
            endpointURL: endpointURL,
            model: model,
            apiKey: resolvedKey,
            messages: options.messages,
            useJSONResponseFormat: options.useJSONResponseFormat,
            maxTokens: options.maxTokens
        )

        do {
            return try await sendChatRequest(requestSpec)
        } catch let error as AIProviderError {
            // 部分 OpenAI 兼容服务端或代理不支持 response_format 字段，遇 400 明确提示时回退一次纯提示词 JSON 模式。
            if options.useJSONResponseFormat, case let .httpError(statusCode, detail) = error,
               statusCode == 400,
               let detail,
               detail.localizedCaseInsensitiveContains("response_format") {
                var fallbackSpec = requestSpec
                fallbackSpec.useJSONResponseFormat = false
                return try await sendChatRequest(fallbackSpec)
            }
            throw error
        }
    }

    private func sendChatRequest(_ spec: ResolvedChatRequest) async throws -> AICompletionContent {
        let payload = AIChatCompletionsRequestBody(
            model: spec.model,
            messages: spec.messages,
            temperature: 0.2,
            maxTokens: spec.maxTokens,
            responseFormat: spec.useJSONResponseFormat ? AIResponseFormat(type: "json_object") : nil
        )
        var request = URLRequest(url: spec.endpointURL)
        request.httpShouldHandleCookies = false
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = spec.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SameOriginRedirectDelegate())
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if (error as? URLError)?.code == .timedOut {
                throw AIProviderError.networkError(
                    "请求超时（AI 响应耗时较长，可重试或改用响应更快的非思考模型如 deepseek-chat）。"
                )
            }
            throw AIProviderError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse("非 HTTP 响应。")
        }
        guard http.statusCode == 200 else {
            throw AIProviderError.httpError(
                statusCode: http.statusCode,
                message: OpenAICompatibleCodec.extractErrorMessage(from: data)
            )
        }
        return try OpenAICompatibleCodec.extractCompletionContent(from: data)
    }

    private func resolveAPIKey(explicitKey: String?, preset: AIProviderPreset) throws -> String? {
        if let explicitKey {
            let trimmed = explicitKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let credentialStore, let stored = try credentialStore.apiKey(for: preset) {
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if preset.requiresAPIKey {
            throw AIProviderError.missingAPIKey(preset: preset)
        }
        return nil
    }
}

public extension OpenAICompatibleClient {
    func suggestLyricsSearchQueries(
        title: String,
        artist: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AISearchQuerySuggestion] {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw AIProviderError.invalidConfiguration("搜索歌名不能为空。")
        }
        let cleanArtist = OpenAICompatibleCodec.trimmedNilIfEmpty(artist)
        let completion = try await requestCompletion(
            ChatRequestOptions(
                configuration: configuration,
                apiKey: apiKey,
                messages: AIPromptBuilder.searchQuerySuggestionMessages(
                    title: cleanTitle,
                    artist: cleanArtist
                ),
                useJSONResponseFormat: true,
                maxTokens: 512
            )
        )
        let rawItems: [AISearchQuerySuggestion] = try OpenAICompatibleCodec.decodeItemsArray(
            from: completion.content
        )
        let suggestions = Self.sanitizeSearchQuerySuggestions(rawItems)
        guard !suggestions.isEmpty else {
            throw AIProviderError.emptyResult("未能推测出可用的搜索关键词。")
        }
        return suggestions
    }
}

private extension OpenAICompatibleClient {
    struct ChatRequestOptions {
        let configuration: AIConfiguration
        let apiKey: String?
        let messages: [AIChatMessage]
        let useJSONResponseFormat: Bool
        let maxTokens: Int?
    }

    struct ResolvedChatRequest {
        let endpointURL: URL
        let model: String
        let apiKey: String?
        let messages: [AIChatMessage]
        var useJSONResponseFormat: Bool
        let maxTokens: Int?
    }

    static func validatedNonEmptyLines(from lines: [LyricLine], emptyMessage: String) throws -> [LyricLine] {
        let filtered = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty else {
            throw AIProviderError.invalidConfiguration(emptyMessage)
        }
        return filtered
    }

    static func filterLineItems<Output>(
        _ pairs: [(UUID, String)],
        validIDs: Set<UUID>,
        emptyError: String,
        makeOutput: (UUID, String) -> Output
    ) throws -> [Output] {
        var seenIDs = Set<UUID>()
        var results: [Output] = []
        for (id, rawText) in pairs {
            let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validIDs.contains(id), !cleanText.isEmpty, seenIDs.insert(id).inserted else {
                continue
            }
            results.append(makeOutput(id, cleanText))
        }
        guard !results.isEmpty else {
            throw AIProviderError.emptyResult(emptyError)
        }
        return results
    }

    static func sanitizeSearchQuerySuggestions(
        _ rawItems: [AISearchQuerySuggestion]
    ) -> [AISearchQuerySuggestion] {
        var seenKeys = Set<String>()
        var results: [AISearchQuerySuggestion] = []
        for item in rawItems {
            guard let cleanTitle = OpenAICompatibleCodec.trimmedNilIfEmpty(item.title) else {
                continue
            }
            let cleanArtist = OpenAICompatibleCodec.trimmedNilIfEmpty(item.artist)
            let cleanReason = OpenAICompatibleCodec.trimmedNilIfEmpty(item.reason)
            let dedupKey = "\(cleanTitle.lowercased())\u{0}\(cleanArtist?.lowercased() ?? "")"
            guard seenKeys.insert(dedupKey).inserted else { continue }
            results.append(
                AISearchQuerySuggestion(
                    title: cleanTitle,
                    artist: cleanArtist,
                    reason: cleanReason
                )
            )
            if results.count == 4 { break }
        }
        return results
    }

    static func milliseconds(from duration: Duration) -> Int {
        let components = duration.components
        let fromSeconds = Int(components.seconds) * 1_000
        let fromAttoseconds = Int(components.attoseconds / 1_000_000_000_000_000)
        return max(0, fromSeconds + fromAttoseconds)
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard AIEndpointURL.isSameOrigin(from: task.originalRequest?.url, to: request.url) else { return nil }
        var redirectedRequest = request
        redirectedRequest.httpShouldHandleCookies = false
        return redirectedRequest
    }
}
