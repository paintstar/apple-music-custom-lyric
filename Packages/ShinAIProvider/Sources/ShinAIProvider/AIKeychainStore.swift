import Foundation
import os
import Security

/// AI 服务 API Key 存储协议；按预设区分账户，绝不写入本地数据库或导出备份。
public protocol AICredentialStoring: Sendable {
    func apiKey(for preset: AIProviderPreset) throws -> String?
    func saveAPIKey(_ key: String, for preset: AIProviderPreset) throws
    func deleteAPIKey(for preset: AIProviderPreset) throws
}

/// 基于 macOS 系统钥匙串（Security framework）的 API Key 存储。
public final class SystemKeychainCredentialStore: AICredentialStoring, @unchecked Sendable {
    /// 统一钥匙串服务标识常量。
    public static let serviceName = "com.shinapple.ai-credentials"

    private let service: String

    public init(service: String = SystemKeychainCredentialStore.serviceName) {
        self.service = service
    }

    public func apiKey(for preset: AIProviderPreset) throws -> String? {
        var query = baseQuery(for: preset)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AIProviderError.keychainError(status: status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            throw AIProviderError.keychainError(status: errSecDecode)
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func saveAPIKey(_ key: String, for preset: AIProviderPreset) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey(for: preset)
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(for: preset)
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AIProviderError.keychainError(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "ShinApple AI (\(preset.displayName))"
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIProviderError.keychainError(status: addStatus)
        }
    }

    public func deleteAPIKey(for preset: AIProviderPreset) throws {
        let query = baseQuery(for: preset)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProviderError.keychainError(status: status)
        }
    }

    private func baseQuery(for preset: AIProviderPreset) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: preset.rawValue
        ]
    }
}

/// 线程安全的内存凭据存储，供单元测试与 Mock 模式使用，不写入系统钥匙串。
public final class InMemoryAICredentialStore: AICredentialStoring, @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<[AIProviderPreset: String]>

    public init(initialKeys: [AIProviderPreset: String] = [:]) {
        let sanitized = initialKeys.reduce(into: [AIProviderPreset: String]()) { result, pair in
            let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result[pair.key] = trimmed
            }
        }
        self.storage = OSAllocatedUnfairLock(initialState: sanitized)
    }

    public func apiKey(for preset: AIProviderPreset) throws -> String? {
        storage.withLock { $0[preset] }
    }

    public func saveAPIKey(_ key: String, for preset: AIProviderPreset) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        storage.withLock { state in
            if trimmed.isEmpty {
                state.removeValue(forKey: preset)
            } else {
                state[preset] = trimmed
            }
        }
    }

    public func deleteAPIKey(for preset: AIProviderPreset) throws {
        _ = storage.withLock { $0.removeValue(forKey: preset) }
    }
}
