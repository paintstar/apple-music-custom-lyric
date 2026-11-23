import Foundation
import ShinAppleKit
import Testing
@testable import ShinAIProvider

@Suite("OpenAICompatibleClient", .serialized)
struct OpenAICompatibleClientTests {

    private func expectProviderError<T: Sendable>(
        _ expression: () async throws -> T,
        verify: (AIProviderError) -> Void
    ) async {
        do {
            _ = try await expression()
            Issue.record("期望抛出 AIProviderError，但成功返回")
        } catch let error as AIProviderError {
            verify(error)
        } catch {
            Issue.record("期望 AIProviderError，实际抛出：\(error)")
        }
    }

    @Test("连接测试：发送请求头并返回延迟、模型名与回复预览")
    func testConnectionSuccess() async throws {
        var capturedURL: URL?
        var capturedAuth: String?
        MockAIURLProtocol.handler = { request in
            capturedURL = request.url
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": "deepseek-chat",
                "choices": [
                    ["message": ["role": "assistant", "content": "连接正常"]]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, data)
        }

        let config = AIConfiguration(preset: .deepSeek)
        let result = try await MockAIURLProtocol.makeClient().testConnection(
            configuration: config,
            apiKey: "test-key"
        )
        #expect(capturedURL?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(capturedAuth == "Bearer test-key")
        #expect(result.model == "deepseek-chat")
        #expect(result.replyPreview == "连接正常")
        #expect(result.latencyMs >= 0)
    }

    @Test("本地 Ollama 免密钥可直接连接并省略 Authorization 头")
    func ollamaWorksWithoutAPIKey() async throws {
        var capturedAuth: String?
        MockAIURLProtocol.handler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": "qwen2.5:7b",
                "choices": [["message": ["role": "assistant", "content": "OK"]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, data)
        }

        let config = AIConfiguration(preset: .ollamaLocal)
        let result = try await MockAIURLProtocol.makeClient().testConnection(
            configuration: config,
            apiKey: nil
        )
        #expect(capturedAuth == nil)
        #expect(result.replyPreview == "OK")
    }

    @Test("任务1：单词语境解析正常解码 AIWordExplanation")
    func explainWordParsesJSON() async throws {
        let payload = """
        {
          "surface": "紙飛行機",
          "lemma": "紙飛行機",
          "reading": "かみひこうき",
          "partOfSpeech": "名词",
          "contextualMeaning": "象征承载愿望飞向远方的纸飞机",
          "generalMeaning": "用纸折叠而成的玩具飞机",
          "examples": [
            { "text": "窓から紙飛行機を飛ばす。", "translation": "从窗边放飞纸飞机。" }
          ]
        }
        """
        try MockAIURLProtocol.respondChatContent(payload)

        let credStore = InMemoryAICredentialStore(initialKeys: [.openAI: "demo-key"])
        let client = MockAIURLProtocol.makeClient(credentialStore: credStore)
        let explanation = try await client.explainWord(
            "紙飛行機",
            inLine: "青い紙飛行機が飛ぶ",
            sourceLanguage: "ja",
            configuration: AIConfiguration(preset: .openAI, preferredTargetLanguage: "zh-Hans"),
            apiKey: nil
        )
        #expect(explanation.surface == "紙飛行機")
        #expect(explanation.reading == "かみひこうき")
        #expect(explanation.partOfSpeech == "名词")
        #expect(explanation.examples.count == 1)
        #expect(explanation.examples.first?.translation == "从窗边放飞纸飞机。")
    }

    @Test("任务2：单行解析兼容 Markdown ```json 代码块包裹")
    func explainLineParsesMarkdownFencedJSON() async throws {
        let fenced = """
        以下是本句分析：
        ```json
        {
          "grammarSummary": "「が」提示自然主语，「飛ぶ」为动词基本形。",
          "keyExpressions": ["紙飛行機が飛ぶ"],
          "singingTips": "句尾轻收气。",
          "culturalNote": null
        }
        ```
        """
        try MockAIURLProtocol.respondChatContent(fenced)

        let explanation = try await MockAIURLProtocol.makeClient().explainLine(
            "青い紙飛行機が飛ぶ",
            context: AILineContext(previousLine: nil, nextLine: "白い雲の上", sourceLanguage: "ja"),
            configuration: AIConfiguration(preset: .deepSeek, preferredTargetLanguage: "zh-Hans"),
            apiKey: "test-key"
        )
        #expect(explanation.grammarSummary.contains("「が」"))
        #expect(explanation.keyExpressions == ["紙飛行機が飛ぶ"])
        #expect(explanation.singingTips == "句尾轻收气。")
        #expect(explanation.culturalNote == nil)
    }

    @Test("任务3：批量注音按行 UUID 对齐并过滤无效或空白条目")
    func generatePronunciationsAlignsByLineID() async throws {
        let line1 = LyricLine(startMs: 1_000, text: "青い紙飛行機が飛ぶ")
        let line2 = LyricLine(startMs: 4_000, text: "白い雲の上")
        let emptyLine = LyricLine(startMs: 6_000, text: "   ")
        let unknownID = UUID()

        let json = """
        {
          "items": [
            { "lineId": "\(line1.id.uuidString)", "pronunciation": "aoi kamihikouki ga tobu" },
            { "lineId": "\(unknownID.uuidString)", "pronunciation": "should ignore" },
            { "lineId": "\(line2.id.uuidString)", "pronunciation": "shiroi kumo no ue" }
          ]
        }
        """
        try MockAIURLProtocol.respondChatContent(json)

        let items = try await MockAIURLProtocol.makeClient().generatePronunciations(
            for: [line1, line2, emptyLine],
            style: .romaji,
            sourceLanguage: "ja",
            configuration: AIConfiguration(preset: .deepSeek),
            apiKey: "test-key"
        )
        #expect(items == [
            AIPronunciationLineItem(lineId: line1.id, pronunciation: "aoi kamihikouki ga tobu"),
            AIPronunciationLineItem(lineId: line2.id, pronunciation: "shiroi kumo no ue")
        ])
    }

    @Test("任务4：批量翻译按行 UUID 对齐")
    func generateTranslationsAlignsByLineID() async throws {
        let line1 = LyricLine(startMs: 1_000, text: "青い紙飛行機が飛ぶ")
        let line2 = LyricLine(startMs: 4_000, text: "白い雲の上")

        let json = """
        {
          "items": [
            { "lineId": "\(line1.id.uuidString)", "translation": "蓝色纸飞机在飞翔" },
            { "lineId": "\(line2.id.uuidString)", "translation": "在洁白的云朵上方" }
          ]
        }
        """
        try MockAIURLProtocol.respondChatContent(json)

        let items = try await MockAIURLProtocol.makeClient().generateTranslations(
            for: [line1, line2],
            sourceLanguage: "ja",
            configuration: AIConfiguration(preset: .siliconFlow, preferredTargetLanguage: "zh-Hans"),
            apiKey: "test-key"
        )
        #expect(items == [
            AITranslationLineItem(lineId: line1.id, translation: "蓝色纸飞机在飞翔"),
            AITranslationLineItem(lineId: line2.id, translation: "在洁白的云朵上方")
        ])
    }

    @Test("任务5：整首关键学习点提取并映射有效 lineId")
    func extractKeyStudyPointsParsesItems() async throws {
        let line = LyricLine(startMs: 1_000, text: "青い紙飛行機が飛ぶ")
        let json = """
        ```json
        {
          "items": [
            {
              "lineId": "\(line.id.uuidString)",
              "surface": "青い",
              "lemma": "青い",
              "reading": "あおい",
              "partOfSpeech": "形容词",
              "contextualMeaning": "蓝色的、澄澈的",
              "generalMeaning": "蓝色；青涩的"
            }
          ]
        }
        ```
        """
        try MockAIURLProtocol.respondChatContent(json)

        let points = try await MockAIURLProtocol.makeClient().extractKeyStudyPoints(
            from: [line],
            sourceLanguage: "ja",
            configuration: AIConfiguration(preset: .openRouter, preferredTargetLanguage: "zh-Hans"),
            apiKey: "test-key"
        )
        #expect(points.count == 1)
        #expect(points.first?.lineId == line.id)
        #expect(points.first?.surface == "青い")
        #expect(points.first?.reading == "あおい")
    }

    @Test("不支持 response_format 返回 400 时自动回退重试一次")
    func retriesWithoutResponseFormatWhenUnsupported() async throws {
        var attemptCount = 0
        var secondBodyHasResponseFormat = true
        MockAIURLProtocol.handler = { request in
            attemptCount += 1
            let bodyData = MockAIURLProtocol.bodyData(from: request) ?? Data()
            let jsonObj = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            if attemptCount == 1 {
                let err = #"{"error":{"message":"response_format is not supported by this model"}}"#
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data(err.utf8))
            }
            secondBodyHasResponseFormat = jsonObj["response_format"] != nil
            let reply = #"{"grammarSummary":"测试回退成功","keyExpressions":[]}"#
            let envelope: [String: Any] = [
                "model": "custom-model",
                "choices": [["message": ["role": "assistant", "content": reply]]]
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: envelope))
        }

        let explanation = try await MockAIURLProtocol.makeClient().explainLine(
            "Testing fallback line",
            context: AILineContext(sourceLanguage: "en"),
            configuration: AIConfiguration(
                preset: .custom,
                baseURLString: "https://example.com/v1",
                modelName: "custom-model",
                preferredTargetLanguage: "zh-Hans"
            ),
            apiKey: "test-key"
        )
        #expect(attemptCount == 2)
        #expect(!secondBodyHasResponseFormat)
        #expect(explanation.grammarSummary == "测试回退成功")
    }

    @Test("错误处理：缺少密钥与非 HTTPS 远程地址本地拦截")
    func localValidationErrors() async {
        let client = MockAIURLProtocol.makeClient()

        MockAIURLProtocol.reset()
        await expectProviderError {
            try await client.testConnection(configuration: AIConfiguration(preset: .deepSeek), apiKey: nil)
        } verify: { error in
            #expect(error == .missingAPIKey(preset: .deepSeek))
            #expect(error.userMessage.contains("API Key"))
        }

        let insecure = AIConfiguration(
            preset: .custom,
            baseURLString: "http://remote.example.com/v1",
            modelName: "m"
        )
        await expectProviderError {
            try await client.testConnection(configuration: insecure, apiKey: "test-key")
        } verify: { error in
            guard case .invalidEndpoint = error else {
                Issue.record("期望 invalidEndpoint，实际：\(error)")
                return
            }
        }
    }

    @Test("错误处理：HTTP 401、429、非法 JSON 与网络层异常")
    func remoteAndDecodingErrors() async throws {
        let client = MockAIURLProtocol.makeClient()

        MockAIURLProtocol.respondRaw(json: #"{"error":{"message":"invalid auth"}}"#, status: 401)
        await expectProviderError {
            try await client.testConnection(configuration: AIConfiguration(preset: .deepSeek), apiKey: "test-key")
        } verify: { error in
            guard case let .httpError(statusCode, _) = error else {
                Issue.record("期望 httpError，实际：\(error)")
                return
            }
            #expect(statusCode == 401)
            #expect(error.userMessage.contains("401"))
        }

        MockAIURLProtocol.respondRaw(json: #"{"error":{"message":"rate limit"}}"#, status: 429)
        await expectProviderError {
            try await client.testConnection(configuration: AIConfiguration(preset: .openAI), apiKey: "test-key")
        } verify: { error in
            guard case let .httpError(statusCode, _) = error else {
                Issue.record("期望 httpError，实际：\(error)")
                return
            }
            #expect(statusCode == 429)
            #expect(error.userMessage.contains("429"))
        }

        try MockAIURLProtocol.respondChatContent("{not-valid-json")
        await expectProviderError {
            try await client.explainWord(
                "word",
                inLine: "line",
                sourceLanguage: "en",
                configuration: AIConfiguration(preset: .openAI, preferredTargetLanguage: "zh-Hans"),
                apiKey: "test-key"
            )
        } verify: { error in
            guard case .invalidResponse = error else {
                Issue.record("期望 invalidResponse，实际：\(error)")
                return
            }
        }

        MockAIURLProtocol.failNetwork()
        await expectProviderError {
            try await client.testConnection(configuration: AIConfiguration(preset: .deepSeek), apiKey: "test-key")
        } verify: { error in
            guard case .networkError = error else {
                Issue.record("期望 networkError，实际：\(error)")
                return
            }
        }
    }
}

extension OpenAICompatibleClientTests {

    @Test("默认会话超时：单次请求 120 秒、资源总超时 300 秒")
    func defaultSessionTimeouts() {
        let session = OpenAICompatibleClient.makeDefaultSession()
        #expect(OpenAICompatibleClient.defaultRequestTimeoutSeconds == 120)
        #expect(OpenAICompatibleClient.defaultResourceTimeoutSeconds == 300)
        #expect(session.configuration.timeoutIntervalForRequest == 120)
        #expect(session.configuration.timeoutIntervalForResource == 300)
    }

    @Test("错误处理：URLError.cancelled 透传为 CancellationError")
    func urlCancelledMapsToCancellationError() async {
        let client = MockAIURLProtocol.makeClient()
        MockAIURLProtocol.handler = { _ in throw URLError(.cancelled) }

        do {
            _ = try await client.testConnection(configuration: AIConfiguration(preset: .deepSeek), apiKey: "test-key")
            Issue.record("期望抛出 CancellationError，但成功返回")
        } catch is CancellationError {
            // 预期透传 CancellationError，而非包装成 AIProviderError.networkError
        } catch {
            Issue.record("期望 CancellationError，实际抛出：\(error)")
        }
    }

    @Test("错误处理：URLError.timedOut 返回包含超时说明与模型建议的提示")
    func urlTimedOutReturnsActionableHint() async {
        let client = MockAIURLProtocol.makeClient()
        MockAIURLProtocol.handler = { _ in throw URLError(.timedOut) }

        await expectProviderError {
            try await client.testConnection(configuration: AIConfiguration(preset: .deepSeek), apiKey: "test-key")
        } verify: { error in
            guard case let .networkError(detail) = error else {
                Issue.record("期望 networkError，实际：\(error)")
                return
            }
            #expect(detail.contains("请求超时"))
            #expect(detail.contains("重试"))
            #expect(detail.contains("deepseek-chat"))
        }
    }

    @Test("搜词推测：正常解码、清洗空白、按标题与歌手去重并限制最多 4 条")
    func suggestLyricsSearchQueriesSanitizesAndCaps() async throws {
        var capturedMaxTokens: Int?
        var capturedHasJSONFormat = false
        let content = """
        {
          "items": [
            { "title": "  青い紙飛行機  ", "artist": "  Sora Band ", "reason": " 日文原名 " },
            { "title": "   ", "artist": "ignored", "reason": "空标题应过滤" },
            { "title": "青い紙飛行機", "artist": "sora band", "reason": "大小写重复应去重" },
            { "title": "あおい かみひこうき", "artist": "  ", "reason": "   " },
            { "title": "Blue Paper Plane", "artist": null, "reason": "英文标题" },
            { "title": "蓝色纸飞机", "artist": "空乐队", "reason": "常用译名" },
            { "title": "第五条候选", "artist": "空乐队", "reason": "超出上限应截断" }
          ]
        }
        """
        MockAIURLProtocol.handler = { request in
            let bodyData = MockAIURLProtocol.bodyData(from: request) ?? Data()
            let jsonObj = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            capturedMaxTokens = jsonObj["max_tokens"] as? Int
            capturedHasJSONFormat = jsonObj["response_format"] != nil
            let envelope: [String: Any] = [
                "model": "deepseek-chat",
                "choices": [["message": ["role": "assistant", "content": content]]]
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: envelope))
        }

        let provider: any AIStudyProviding = MockAIURLProtocol.makeClient()
        let suggestions = try await provider.suggestLyricsSearchQueries(
            title: "Aoi Kamihikouki",
            artist: "Sora Band",
            configuration: AIConfiguration(preset: .deepSeek),
            apiKey: "test-key"
        )
        #expect(capturedMaxTokens == 512)
        #expect(capturedHasJSONFormat)
        #expect(suggestions == [
            AISearchQuerySuggestion(title: "青い紙飛行機", artist: "Sora Band", reason: "日文原名"),
            AISearchQuerySuggestion(title: "あおい かみひこうき", artist: nil, reason: nil),
            AISearchQuerySuggestion(title: "Blue Paper Plane", artist: nil, reason: "英文标题"),
            AISearchQuerySuggestion(title: "蓝色纸飞机", artist: "空乐队", reason: "常用译名")
        ])
        #expect(suggestions.first?.id == "青い紙飛行機|Sora Band")
        #expect(suggestions[1].id == "あおい かみひこうき|")
    }

    @Test("搜词推测：空标题抛 invalidConfiguration，空列表抛 emptyResult")
    func suggestLyricsSearchQueriesValidationAndEmptyErrors() async throws {
        let client = MockAIURLProtocol.makeClient()
        let config = AIConfiguration(preset: .deepSeek)

        MockAIURLProtocol.reset()
        await expectProviderError {
            try await client.suggestLyricsSearchQueries(title: "  \n ", artist: "Sora", configuration: config, apiKey: "k")
        } verify: { error in
            guard case .invalidConfiguration = error else {
                Issue.record("期望 invalidConfiguration，实际：\(error)")
                return
            }
        }

        try MockAIURLProtocol.respondChatContent(#"{"items":[{"title":"   ","artist":"Sora"}]}"#)
        await expectProviderError {
            try await client.suggestLyricsSearchQueries(title: "Aoi Kamihikouki", artist: nil, configuration: config, apiKey: "k")
        } verify: { error in
            guard case .emptyResult = error else {
                Issue.record("期望 emptyResult，实际：\(error)")
                return
            }
        }
    }
}
