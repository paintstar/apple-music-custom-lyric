import Foundation
import ShinAppleKit
import Testing
@testable import ShinAIProvider

@Suite("AIProviderConfiguration 与内存凭据库")
struct AIProviderConfigurationTests {

    @Test("各服务商预设元数据与密钥需求正确")
    func presetMetadata() {
        #expect(AIProviderPreset.deepSeek.defaultBaseURL == "https://api.deepseek.com/v1")
        #expect(AIProviderPreset.deepSeek.defaultModel == "deepseek-chat")
        #expect(AIProviderPreset.deepSeek.requiresAPIKey)

        #expect(AIProviderPreset.openAI.defaultBaseURL == "https://api.openai.com/v1")
        #expect(AIProviderPreset.openAI.defaultModel == "gpt-4o-mini")
        #expect(AIProviderPreset.openAI.requiresAPIKey)

        #expect(AIProviderPreset.siliconFlow.defaultBaseURL == "https://api.siliconflow.cn/v1")
        #expect(AIProviderPreset.siliconFlow.defaultModel == "Qwen/Qwen2.5-7B-Instruct")
        #expect(AIProviderPreset.siliconFlow.requiresAPIKey)

        #expect(AIProviderPreset.openRouter.defaultBaseURL == "https://openrouter.ai/api/v1")
        #expect(AIProviderPreset.openRouter.defaultModel == "openai/gpt-4o-mini")
        #expect(AIProviderPreset.openRouter.requiresAPIKey)

        #expect(AIProviderPreset.ollamaLocal.defaultBaseURL == "http://127.0.0.1:11434/v1")
        #expect(AIProviderPreset.ollamaLocal.defaultModel == "qwen2.5:7b")
        #expect(!AIProviderPreset.ollamaLocal.requiresAPIKey)

        #expect(AIProviderPreset.custom.defaultBaseURL.isEmpty)
        #expect(AIProviderPreset.custom.defaultModel.isEmpty)
        #expect(AIProviderPreset.custom.requiresAPIKey)
    }

    @Test("端点安全校验放行 HTTPS 与本地回环 HTTP")
    func validEndpointsAccepted() throws {
        let httpsURL = try validatedEndpointURL(baseURLString: "  https://api.deepseek.com/v1  ")
        #expect(httpsURL.absoluteString == "https://api.deepseek.com/v1")

        let localhostURL = try validatedEndpointURL(baseURLString: "http://localhost:11434/v1")
        #expect(localhostURL.host == "localhost")

        let ipv4Loopback = try validatedEndpointURL(baseURLString: "http://127.0.0.1:11434/v1")
        #expect(ipv4Loopback.host == "127.0.0.1")

        let ipv6Loopback = try validatedEndpointURL(baseURLString: "http://[::1]:11434/v1")
        #expect(ipv6Loopback.port == 11434)
    }

    @Test("端点安全校验拦截非 HTTPS 远程地址与非法协议")
    func unsafeEndpointsRejected() {
        let invalidInputs = [
            "",
            "   ",
            "not-a-url",
            "http://api.openai.com/v1",
            "http://192.168.1.10:11434/v1",
            "http://localhost.example.com/v1",
            "ftp://example.com/v1",
            "https://user:pass@example.com/v1"
        ]
        for raw in invalidInputs {
            do {
                _ = try validatedEndpointURL(baseURLString: raw)
                Issue.record("期望拦截非法地址，但通过了：\(raw)")
            } catch let error as AIProviderError {
                guard case .invalidEndpoint = error else {
                    Issue.record("期望 invalidEndpoint，实际抛出：\(error)")
                    return
                }
            } catch {
                Issue.record("期望 AIProviderError，实际抛出：\(error)")
            }
        }
    }

    @Test("AIServiceSettingsStore 在独立 UserDefaults 域往返保存配置")
    func settingsStoreRoundTrip() {
        let suiteName = "com.shinapple.tests.ai-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AIServiceSettingsStore(userDefaults: defaults)
        #expect(store.load() == AIConfiguration())

        let custom = AIConfiguration(
            preset: .openRouter,
            baseURLString: "https://openrouter.ai/api/v1",
            modelName: "openai/gpt-4o-mini",
            preferredTargetLanguage: "zh-Hans",
            preferredPronunciationStyle: .furigana
        )
        store.save(custom)
        #expect(store.load() == custom)

        store.reset()
        #expect(store.load() == AIConfiguration())
    }

    @Test("InMemoryAICredentialStore 支持按预设存取与删除且忽略空字符串")
    func inMemoryCredentialStoreOperations() throws {
        let store = InMemoryAICredentialStore()
        #expect(try store.apiKey(for: .deepSeek) == nil)

        try store.saveAPIKey("test-key", for: .deepSeek)
        #expect(try store.apiKey(for: .deepSeek) == "test-key")
        #expect(try store.apiKey(for: .openAI) == nil)

        try store.saveAPIKey("   ", for: .deepSeek)
        #expect(try store.apiKey(for: .deepSeek) == nil)

        try store.saveAPIKey("other-key", for: .openAI)
        try store.deleteAPIKey(for: .openAI)
        #expect(try store.apiKey(for: .openAI) == nil)
    }
}
