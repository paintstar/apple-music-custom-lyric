import CryptoKit
import Foundation
import ShinAIProvider

public enum AIStudyCacheKey {
    /// 修改生成提示词或缓存结果结构时递增版本。
    private static let promptVersion = "1"

    public static func make(task: String, configuration: AIConfiguration, inputs: [String]) -> String {
        let fields = [
            promptVersion,
            task,
            configuration.preset.rawValue,
            (try? configuration.validatedBaseURL().absoluteString) ?? "",
            configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        ] + inputs
        var hasher = SHA256()
        for field in fields {
            // 长度前缀避免用户输入中出现分隔符时来自不同字段的内容碰撞。
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
