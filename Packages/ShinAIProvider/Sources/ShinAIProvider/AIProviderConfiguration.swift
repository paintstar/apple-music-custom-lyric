import Foundation
import ShinAppleKit

/// AI 学习服务预设。除自定义外均内置公开标准端点与推荐模型标识。
public enum AIProviderPreset: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case deepSeek
    case openAI
    case siliconFlow
    case openRouter
    case ollamaLocal
    case custom

    public var id: String { rawValue }

    /// 面向设置界面展示的中文名称。
    public var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .openAI: return "OpenAI"
        case .siliconFlow: return "硅基流动"
        case .openRouter: return "OpenRouter"
        case .ollamaLocal: return "本地 Ollama"
        case .custom: return "自定义"
        }
    }

    /// 预设默认 OpenAI 兼容 Base URL。
    public var defaultBaseURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .siliconFlow: return "https://api.siliconflow.cn/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollamaLocal: return "http://127.0.0.1:11434/v1"
        case .custom: return ""
        }
    }

    /// 预设默认模型名称。
    public var defaultModel: String {
        switch self {
        case .deepSeek: return "deepseek-chat"
        case .openAI: return "gpt-4o-mini"
        case .siliconFlow: return "Qwen/Qwen2.5-7B-Instruct"
        case .openRouter: return "openai/gpt-4o-mini"
        case .ollamaLocal: return "qwen2.5:7b"
        case .custom: return ""
        }
    }

    /// 是否要求配置非空 API Key；本地 Ollama 默认免密钥。
    public var requiresAPIKey: Bool {
        switch self {
        case .ollamaLocal: return false
        case .deepSeek, .openAI, .siliconFlow, .openRouter, .custom: return true
        }
    }
}

/// AI 学习服务的非敏感配置；绝不含有 API Key。
public struct AIConfiguration: Codable, Equatable, Sendable {
    public var preset: AIProviderPreset
    public var baseURLString: String
    public var modelName: String
    public var preferredTargetLanguage: String
    public var preferredPronunciationStyle: PronunciationStyle

    public init(
        preset: AIProviderPreset = .deepSeek,
        baseURLString: String? = nil,
        modelName: String? = nil,
        preferredTargetLanguage: String = "zh-Hans",
        preferredPronunciationStyle: PronunciationStyle = .romaji
    ) {
        self.preset = preset
        self.baseURLString = baseURLString ?? preset.defaultBaseURL
        self.modelName = modelName ?? preset.defaultModel
        self.preferredTargetLanguage = preferredTargetLanguage
        self.preferredPronunciationStyle = preferredPronunciationStyle
    }

    /// 校验当前配置中的 Base URL 是否满足安全协议约束。
    public func validatedBaseURL() throws -> URL {
        try validatedEndpointURL(baseURLString: baseURLString)
    }
}

/// 从 `UserDefaults` 读写非敏感 `AIConfiguration`。API Key 由 `AICredentialStoring` 单独保管。
public final class AIServiceSettingsStore: @unchecked Sendable {
    public static let defaultStorageKey = "ai.service.configuration"

    private let userDefaults: UserDefaults
    private let storageKey: String

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = AIServiceSettingsStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    /// 读取当前配置；未保存或解码失败时返回默认配置。
    public func load() -> AIConfiguration {
        guard let data = userDefaults.data(forKey: storageKey),
              let configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data)
        else {
            return AIConfiguration()
        }
        return configuration
    }

    /// 保存非敏感配置到 `UserDefaults`。
    public func save(_ configuration: AIConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    /// 清除保存的配置，恢复默认状态。
    public func reset() {
        userDefaults.removeObject(forKey: storageKey)
    }
}

private let loopbackHosts: Set<String> = [
    "localhost",
    "127.0.0.1",
    "::1",
    "0:0:0:0:0:0:0:1"
]

/// 校验 AI 服务端点 URL：仅允许 `https` 协议，或本地回环地址（`localhost` / `127.0.0.1` / `::1`）的 `http` 协议。
public func validatedEndpointURL(baseURLString: String) throws -> URL {
    let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AIProviderError.invalidEndpoint("服务地址不能为空。")
    }
    guard let components = URLComponents(string: trimmed),
          let url = components.url,
          let scheme = components.scheme?.lowercased(),
          !scheme.isEmpty,
          let rawHost = components.host,
          !rawHost.isEmpty
    else {
        throw AIProviderError.invalidEndpoint("无法解析为有效 URL：\(trimmed)")
    }
    if components.user != nil || components.password != nil {
        throw AIProviderError.invalidEndpoint("服务地址不得内嵌用户名或密码，请使用系统钥匙串保存密钥。")
    }

    let normalizedHost = rawHost
        .lowercased()
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

    switch scheme {
    case "https":
        return url
    case "http":
        guard loopbackHosts.contains(normalizedHost) else {
            throw AIProviderError.invalidEndpoint("非本地地址仅允许使用 HTTPS 协议：\(trimmed)")
        }
        return url
    default:
        throw AIProviderError.invalidEndpoint("不支持的协议「\(scheme)」，仅允许 HTTPS 或本地回环 HTTP。")
    }
}
