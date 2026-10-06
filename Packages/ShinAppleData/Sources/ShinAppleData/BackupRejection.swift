import Foundation
import ShinAppleKit

/// 备份导入的拒绝原因。所有拒绝都发生在任何写入之前；
/// 拒绝时原库一个字节都不会被改动（提交是独立的最后一步）。
public enum BackupRejection: Error, Equatable, Sendable {
    /// 字节不是严格 UTF-8（或 UTF-16/32 BOM）。
    case notUTF8(reason: String)
    /// 字节数超限。
    case tooLarge(bytes: Int, limit: Int)
    /// 不是合法 JSON。
    case invalidJSON(String)
    /// 顶层不是 JSON 对象。
    case unexpectedRoot(String)
    /// 备份格式版本是未来版本：拒绝，原库不变。
    case unsupportedSchemaVersion(found: Int)
    /// 嵌套深度超限（含未知键下的内容）。
    case tooDeep(path: String, depth: Int, limit: Int)
    /// 数组条数超限。
    case oversizedArray(path: String, count: Int, limit: Int)
    /// 设置值不是字符串（settings 表只存文本）。
    case settingsValueNotString(key: String)
    /// 设置条目数超限。
    case tooManySettings(count: Int, limit: Int)
    /// 解码时缺少必需字段。
    case missingField(path: String)
    /// 字段类型与白名单声明不符。
    case wrongType(path: String, expected: String)
    /// UUID 非法。
    case invalidUUID(path: String, value: String)
    /// ISO8601 时间戳非法。
    case invalidTimestamp(path: String, value: String)
    /// revision < 1。
    case invalidRevision(path: String, revision: Int)
    /// trackKey 与 track 字段推导值不一致（防篡改）。
    case trackKeyMismatch(path: String, declared: String, expected: String)
    /// 备份内出现重复文档 id。
    case duplicateDocumentId(UUID)
    /// 备份内出现重复曲目键。
    case duplicateTrackKey(String)
    /// 绑定指向备份中不存在的文档（备份必须自包含）。
    case danglingBinding(documentId: UUID)
    /// 文档未通过 schema v1 校验（复用 LyricSchemaValidator 的结果）。
    case schemaIssues([LyricSchemaIssue])
}
