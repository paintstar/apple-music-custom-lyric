import Foundation
import ShinAppleKit

// 备份导入流水线（解析阶段，绝不写库）：
// 字节 → 严格 UTF-8 → 大小限制 → JSON 解析 → 白名单/限制/深度预检 →
// 文件版本检查 → 复用 LyricSchemaValidator 数值校验 → 严格解码 →
// 语义校验（时间戳/UUID/trackKey/重复 id/悬空绑定）→ BackupParseResult。
// 之后才允许：纯函数冲突预览 → 用户确认 → 单事务提交。

public enum BackupParser {

    /// 解析备份字节。抛出 ShinAppleDataError.invalidBackup（带类型化拒绝原因）。
    public static func parse(
        _ data: Data,
        configuration: BackupConfiguration
    ) throws -> BackupParseResult {
        let limits = configuration.limits
        guard data.count <= limits.maxBytes else {
            throw rejection(.tooLarge(bytes: data.count, limit: limits.maxBytes))
        }

        var warnings: [BackupWarning] = []
        let utf8Data = try strictUTF8(data, warnings: &warnings)

        let root = try parseJSONRoot(utf8Data)

        // 预检抛出的 BackupRejection 统一包装为 ShinAppleDataError。
        let walkWarnings: [BackupWarning]
        do {
            walkWarnings = try BackupWalk.walkRoot(root, limits: limits)
        } catch let rejection as BackupRejection {
            throw ShinAppleDataError.invalidBackup(rejection)
        }
        warnings.append(contentsOf: walkWarnings)

        try rejectSchemaIssues(inRawDocuments: root)

        let file = try decodeFile(utf8Data)
        try validateSemantics(file)
        appendSettingWarnings(into: &warnings, file: file, configuration: configuration)
        let allowed = allowlistedFile(file, configuration: configuration)
        return BackupParseResult(file: allowed, warnings: warnings)
    }

    // MARK: - 阶段

    private static func parseJSONRoot(_ data: Data) throws -> [String: Any] {
        let raw: Any
        do {
            // 默认选项拒绝顶层非对象/数组片段。
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw rejection(.invalidJSON(error.localizedDescription))
        }
        guard let root = raw as? [String: Any] else {
            throw rejection(.unexpectedRoot("顶层必须是 JSON 对象"))
        }
        return root
    }

    /// 严格 UTF-8：拒绝非法字节序列与 UTF-16/32 BOM；UTF-8 BOM 剥离并提示。
    private static func strictUTF8(
        _ data: Data,
        warnings: inout [BackupWarning]
    ) throws -> Data {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            warnings.append(.utf8BomStripped)
            return data.dropFirst(3)
        }
        let utf16LE = bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE
        let utf16BE = bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF
        let utf32LE = bytes.count >= 4 && bytes[0] == 0xFF && bytes[1] == 0xFE
            && bytes[2] == 0x00 && bytes[3] == 0x00
        if utf16LE || utf16BE || utf32LE {
            throw rejection(.notUTF8(reason: "检测到 UTF-16/32 BOM；备份必须是 UTF-8"))
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw rejection(.notUTF8(reason: "字节序列不是合法 UTF-8"))
        }
        return data
    }

    /// 每个文档复用 LyricSchemaValidator 的 JSON 层校验
    /// （schemaVersion、重复 line.id、小数毫秒、非有限/越界时间）。
    private static func rejectSchemaIssues(inRawDocuments root: [String: Any]) throws {
        let rawDocuments = (root["documents"] as? [[String: Any]]) ?? []
        var issues: [LyricSchemaIssue] = []
        for docObject in rawDocuments {
            issues.append(contentsOf: LyricSchemaValidator.issues(inJSONObject: docObject))
        }
        if !issues.isEmpty {
            throw rejection(.schemaIssues(issues))
        }
    }

    private static func decodeFile(_ data: Data) throws -> BackupFile {
        do {
            return try JSONDecoder().decode(BackupFile.self, from: data)
        } catch let error as DecodingError {
            throw rejection(decodingRejection(error))
        }
    }

    /// 解码后的语义校验（模型层；UUID 由解码器与预检保证）。
    private static func validateSemantics(_ file: BackupFile) throws {
        try requireTimestamp(file.exportedAt, path: "root.exportedAt")
        try validateDocuments(file.documents)
        try validateBindings(file.bindings, documentIds: Set(file.documents.map { $0.id }))
    }

    private static func validateDocuments(_ documents: [LyricDocument]) throws {
        var seenIds = Set<UUID>()
        for (index, document) in documents.enumerated() {
            let path = "root.documents[\(index)]"
            guard document.revision >= 1 else {
                throw rejection(.invalidRevision(path: "\(path).revision", revision: document.revision))
            }
            try requireTimestamp(document.createdAt, path: "\(path).createdAt")
            try requireTimestamp(document.updatedAt, path: "\(path).updatedAt")
            guard !seenIds.contains(document.id) else {
                throw rejection(.duplicateDocumentId(document.id))
            }
            seenIds.insert(document.id)
            // 模型层再跑一次完整 schema 校验（防御手工构造的 ParseResult）。
            let issues = LyricSchemaValidator.issues(in: document)
            if !issues.isEmpty {
                throw rejection(.schemaIssues(issues))
            }
        }
    }

    private static func validateBindings(
        _ bindings: [BackupBinding],
        documentIds: Set<UUID>
    ) throws {
        var seenTrackKeys = Set<String>()
        for (index, binding) in bindings.enumerated() {
            let path = "root.bindings[\(index)]"
            try requireTimestamp(binding.updatedAt, path: "\(path).updatedAt")
            let expectedKey = try expectedTrackKey(for: binding, path: path)
            guard binding.trackKey == expectedKey else {
                throw rejection(.trackKeyMismatch(
                    path: "\(path).trackKey",
                    declared: binding.trackKey,
                    expected: expectedKey
                ))
            }
            guard !seenTrackKeys.contains(binding.trackKey) else {
                throw rejection(.duplicateTrackKey(binding.trackKey))
            }
            seenTrackKeys.insert(binding.trackKey)
            guard documentIds.contains(binding.lyricDocumentId) else {
                throw rejection(.danglingBinding(documentId: binding.lyricDocumentId))
            }
        }
    }

    /// 绑定身份校验（v2 语义）：
    /// - persistentId 与 track 恰有一个（都有或都没有均拒绝）；
    /// - persistentId 必须通过十六进制白名单；
    /// - 由身份推导的 trackKey 必须与声明值一致（防篡改）。
    private static func expectedTrackKey(
        for binding: BackupBinding,
        path: String
    ) throws -> String {
        switch (binding.track, binding.persistentId) {
        case (let track?, let persistentId?):
            throw rejection(.wrongType(
                path: "\(path).persistentId",
                expected: "目录身份与 persistentId 不可同时存在（track=\(track.storefront)/\(track.catalogSongId)）"
            ))
        case (nil, nil):
            throw rejection(.missingField(path: "\(path).track 或 \(path).persistentId"))
        case (let track?, nil):
            guard !track.storefront.isEmpty, !track.catalogSongId.isEmpty else {
                throw rejection(.wrongType(path: "\(path).track", expected: "非空目录身份"))
            }
            return SongBinding.trackKey(for: track.catalogIdentity)
        case (nil, let persistentId?):
            guard SongBinding.isValidPersistentID(persistentId) else {
                throw rejection(.wrongType(
                    path: "\(path).persistentId",
                    expected: "1–64 位十六进制字符串"
                ))
            }
            return SongBinding.trackKey(persistentID: persistentId)
        }
    }

    /// 白名单外的设置键：从可导入内容中剔除，并产出 warning（不静默丢弃）。
    private static func appendSettingWarnings(
        into warnings: inout [BackupWarning],
        file: BackupFile,
        configuration: BackupConfiguration
    ) {
        for key in file.settings.keys.sorted() where !configuration.settingAllowlist.contains(key) {
            warnings.append(.settingNotInAllowlist(key: key))
        }
    }

    private static func allowlistedFile(
        _ file: BackupFile,
        configuration: BackupConfiguration
    ) -> BackupFile {
        let allowed = file.settings.filter { configuration.settingAllowlist.contains($0.key) }
        return BackupFile(
            exportedAt: file.exportedAt,
            documents: file.documents,
            bindings: file.bindings,
            settings: allowed
        )
    }

    // MARK: - 工具

    private static func requireTimestamp(_ value: String, path: String) throws {
        guard LyricTimestamp.date(from: value) != nil else {
            throw rejection(.invalidTimestamp(path: path, value: value))
        }
    }

    private static func rejection(_ reason: BackupRejection) -> ShinAppleDataError {
        .invalidBackup(reason)
    }

    /// DecodingError → 带路径的类型化拒绝。
    private static func decodingRejection(_ error: DecodingError) -> BackupRejection {
        switch error {
        case let .keyNotFound(_, context):
            return .missingField(path: path(context.codingPath))
        case let .typeMismatch(_, context):
            return .wrongType(path: path(context.codingPath), expected: "与白名单声明类型一致")
        case let .valueNotFound(_, context):
            return .wrongType(path: path(context.codingPath), expected: "非 null 值")
        case let .dataCorrupted(context):
            return .invalidJSON("\(context.debugDescription)（路径：\(path(context.codingPath))）")
        @unknown default:
            return .invalidJSON(error.localizedDescription)
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "root" }
        return "root." + codingPath.map { $0.stringValue }.joined(separator: ".")
    }
}
