import Foundation
import ShinAppleKit

/// OpenAI Chat Completions 请求与响应 JSON 编解码工具，隔离在客户端之外以便独立复用与保持文件精简。
enum OpenAICompatibleCodec {
    static func trimmedNilIfEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func extractErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(AIErrorEnvelope.self, from: data) {
            if let message = trimmedNilIfEmpty(decoded.error?.message) {
                return String(message.prefix(200))
            }
            if let message = trimmedNilIfEmpty(decoded.message) {
                return String(message.prefix(200))
            }
        }
        if let raw = trimmedNilIfEmpty(String(data: data, encoding: .utf8)) {
            return String(raw.prefix(200))
        }
        return nil
    }

    static func extractCompletionContent(from data: Data) throws -> AICompletionContent {
        let envelope: AIChatCompletionsResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(AIChatCompletionsResponseEnvelope.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse("无法解析 Chat Completions 响应外层结构。")
        }
        guard let firstChoice = envelope.choices.first else {
            throw AIProviderError.emptyResult("响应 choices 列表为空。")
        }
        let text = firstChoice.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIProviderError.emptyResult("模型返回的 message.content 为空。")
        }
        return AICompletionContent(model: trimmedNilIfEmpty(envelope.model), content: text)
    }

    /// 自动剥离 Markdown ```json ... ``` 代码块后再做严格 JSON 解码。
    static func decodeStructuredContent<T: Decodable>(from rawContent: String) throws -> T {
        let data = try jsonPayloadData(from: rawContent)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIProviderError.invalidResponse("模型返回的 JSON 字段不符合预期结构：\(error.localizedDescription)")
        }
    }

    static func decodeItemsArray<Item: Decodable>(from rawContent: String) throws -> [Item] {
        let data = try jsonPayloadData(from: rawContent)
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(AIItemsEnvelope<Item>.self, from: data) {
            return wrapped.items
        }
        if let linesWrapped = try? decoder.decode(AILinesEnvelope<Item>.self, from: data) {
            return linesWrapped.lines
        }
        do {
            return try decoder.decode([Item].self, from: data)
        } catch {
            throw AIProviderError.invalidResponse("模型返回的列表 JSON 不符合预期结构：\(error.localizedDescription)")
        }
    }

    static func extractJSONString(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startFence = trimmed.range(of: "```") else {
            return trimmed
        }
        let afterOpen = trimmed[startFence.upperBound...]
        let bodyStart: Substring.Index
        if let newlineIndex = afterOpen.firstIndex(of: "\n") {
            bodyStart = afterOpen.index(after: newlineIndex)
        } else if afterOpen.lowercased().hasPrefix("json") {
            bodyStart = afterOpen.index(afterOpen.startIndex, offsetBy: 4)
        } else {
            bodyStart = afterOpen.startIndex
        }
        let remaining = afterOpen[bodyStart...]
        guard let endFence = remaining.range(of: "```") else {
            return trimmed
        }
        return String(remaining[..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonPayloadData(from rawContent: String) throws -> Data {
        let jsonString = extractJSONString(from: rawContent)
        guard !jsonString.isEmpty else {
            throw AIProviderError.emptyResult("模型未输出 JSON 内容。")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw AIProviderError.invalidResponse("响应内容不是有效 UTF-8 文本。")
        }
        return data
    }
}

struct AIResponseFormat: Encodable {
    let type: String
}

struct AIChatCompletionsRequestBody: Encodable {
    let model: String
    let messages: [AIChatMessage]
    let temperature: Double
    let maxTokens: Int?
    let responseFormat: AIResponseFormat?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

struct AICompletionContent {
    let model: String?
    let content: String
}

struct AIKeyStudyPointPayload: Decodable {
    let id: UUID?
    let lineId: UUID?
    let surface: String
    let lemma: String
    let reading: String?
    let partOfSpeech: String?
    let contextualMeaning: String
    let generalMeaning: String
}

private struct AIErrorDetail: Decodable {
    let message: String?
}

private struct AIErrorEnvelope: Decodable {
    let error: AIErrorDetail?
    let message: String?
}

private struct AIContentPart: Decodable {
    let text: String?
}

private struct AIChatMessagePayload: Decodable {
    let textContent: String

    private enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .content) {
            self.textContent = text
            return
        }
        if let parts = try? container.decode([AIContentPart].self, forKey: .content) {
            self.textContent = parts.compactMap(\.text).joined()
            return
        }
        if (try? container.decodeNil(forKey: .content)) == true {
            self.textContent = ""
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .content,
            in: container,
            debugDescription: "无法解码 message.content"
        )
    }
}

private struct AIChatChoicePayload: Decodable {
    let message: AIChatMessagePayload
}

private struct AIChatCompletionsResponseEnvelope: Decodable {
    let model: String?
    let choices: [AIChatChoicePayload]
}

private struct AIItemsEnvelope<Item: Decodable>: Decodable {
    let items: [Item]
}

private struct AILinesEnvelope<Item: Decodable>: Decodable {
    let lines: [Item]
}
