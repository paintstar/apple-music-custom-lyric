import Foundation

// 备份 JSON 的结构化预检：白名单键、大小/条数/深度限制。
// 在解码到模型之前完成，保证：
// 1) 未知键产出 warning（不静默丢弃）；
// 2) 深度异常/超大数组/错误容器类型在触碰模型层之前被拒绝；
// 3) 遍历对深度有硬上限，恶意嵌套不会导致递归失控。

enum WalkLevel {
    case root
    case document
    case line
    /// translations 对象：键是语言代码（开放集合），值是 translation 对象。
    case translations
    case translation
    case binding
    case track
    case settings

    var knownKeys: Set<String> {
        switch self {
        case .root:
            return ["schemaVersion", "exportedAt", "documents", "bindings", "settings"]
        case .document:
            return [
                "schemaVersion", "id", "revision", "sourceLanguage", "sourceFormat",
                "sourceOffsetMs", "originalText", "originalFilename", "metadata",
                "lines", "createdAt", "updatedAt"
            ]
        case .line:
            return ["id", "startMs", "text", "translations"]
        case .translations:
            // 语言代码是开放集合，任何键都合法。
            return []
        case .translation:
            return ["text", "source", "needsReview"]
        case .binding:
            return [
                "trackKey", "track", "persistentId", "lyricDocumentId", "userDelayMs",
                "titleHint", "artistHint", "durationHintMs", "updatedAt"
            ]
        case .track:
            return ["storefront", "catalogSongId"]
        case .settings:
            // 设置键是开放集合，白名单在解析层过滤；此处无固定已知键。
            return []
        }
    }
}

enum BackupWalk {

    /// 遍历已解析的 JSON 对象图：收集未知键 warning、执行深度/条数限制、
    /// 检查容器形状。数值语义（小数毫秒、重复行 id 等）交由
    /// LyricSchemaValidator 复用检查。返回收集到的 warning。
    static func walkRoot(
        _ root: [String: Any],
        limits: BackupLimits
    ) throws -> [BackupWarning] {
        let walker = Walker(limits: limits)
        try walker.walkObject(root, path: "root", level: .root, depth: 1)
        return walker.warnings
    }

    /// 有状态的遍历器：limits 与 warnings 作为实例状态，
    /// 遍历方法只携带位置参数。
    private final class Walker {
        let limits: BackupLimits
        var warnings: [BackupWarning] = []

        init(limits: BackupLimits) {
            self.limits = limits
        }

        func walkObject(
            _ object: [String: Any],
            path: String,
            level: WalkLevel,
            depth: Int
        ) throws {
            guard depth <= limits.maxDepth else {
                throw BackupRejection.tooDeep(path: path, depth: depth, limit: limits.maxDepth)
            }
            switch level {
            case .settings:
                try walkSettings(object, path: path)
                return
            case .translations:
                try walkTranslationsMap(object, path: path, depth: depth)
                return
            default:
                break
            }
            for key in object.keys.sorted() {
                guard let child = object[key] else { continue }
                let childPath = "\(path).\(key)"
                guard level.knownKeys.contains(key) else {
                    warnings.append(.unknownKey(path: path, key: key))
                    try walkUnknownValue(child, path: childPath, depth: depth + 1)
                    continue
                }
                try walkKnownKey(key: key, value: child, path: childPath, level: level, depth: depth)
            }
        }

        /// translations 对象：键 = BCP-47 语言代码（开放集合），值 = translation。
        private func walkTranslationsMap(
            _ object: [String: Any],
            path: String,
            depth: Int
        ) throws {
            for key in object.keys.sorted() {
                guard let child = object[key] else { continue }
                guard let dict = child as? [String: Any] else {
                    throw BackupRejection.wrongType(path: "\(path).\(key)", expected: "translation 对象")
                }
                try walkObject(dict, path: "\(path).\(key)", level: .translation, depth: depth + 1)
            }
        }

        /// 按层分发已知键的类型检查。
        private func walkKnownKey(
            key: String,
            value: Any,
            path: String,
            level: WalkLevel,
            depth: Int
        ) throws {
            switch level {
            case .root:
                try walkRootKey(key: key, value: value, path: path, depth: depth)
            case .document:
                try walkDocumentKey(key: key, value: value, path: path, depth: depth)
            case .line:
                try walkLineKey(key: key, value: value, path: path, depth: depth)
            case .translation:
                try walkTranslationKey(key: key, value: value, path: path)
            case .binding:
                try walkBindingKey(key: key, value: value, path: path, depth: depth)
            case .track:
                try requireString(value, path: path, expected: "字符串")
            case .translations, .settings:
                break // 已提前处理
            }
        }

        private func walkRootKey(key: String, value: Any, path: String, depth: Int) throws {
            switch key {
            case "schemaVersion":
                let version = try requireInt(value, path: path, expected: "整数")
                // v2 起同时接受 v1（目录身份备份）与当前版本；更新版本拒绝。
                guard (BackupFile.oldestSupportedSchemaVersion...BackupFile.currentSchemaVersion)
                    .contains(version) else {
                    throw BackupRejection.unsupportedSchemaVersion(found: version)
                }
            case "exportedAt":
                try requireString(value, path: path, expected: "ISO8601 字符串")
            case "documents":
                try walkArray(
                    value, path: path, elementLevel: .document,
                    depth: depth, limit: limits.maxDocuments
                )
            case "bindings":
                try walkArray(
                    value, path: path, elementLevel: .binding,
                    depth: depth, limit: limits.maxBindings
                )
            case "settings":
                guard let dict = value as? [String: Any] else {
                    throw BackupRejection.wrongType(path: path, expected: "对象")
                }
                try walkObject(dict, path: path, level: .settings, depth: depth + 1)
            default:
                break // knownKeys 已过滤
            }
        }

        private func walkDocumentKey(key: String, value: Any, path: String, depth: Int) throws {
            switch key {
            case "schemaVersion", "revision", "sourceOffsetMs":
                _ = try requireInt(value, path: path, expected: "整数")
            case "id":
                try requireUUID(value, path: path)
            case "sourceFormat", "createdAt", "updatedAt":
                try requireString(value, path: path, expected: "字符串")
            case "sourceLanguage", "originalText", "originalFilename":
                try requireStringOrNil(value, path: path, expected: "字符串或 null")
            case "metadata":
                try walkUnknownValue(value, path: path, depth: depth + 1)
            case "lines":
                // 单文档行数受总行数上限约束；与 maxBytes 一起约束总量。
                try walkArray(
                    value, path: path, elementLevel: .line,
                    depth: depth, limit: limits.maxTotalLines
                )
            default:
                break
            }
        }

        private func walkLineKey(key: String, value: Any, path: String, depth: Int) throws {
            switch key {
            case "id":
                try requireUUID(value, path: path)
            case "text":
                try requireString(value, path: path, expected: "字符串")
            case "startMs":
                // 数值语义（小数/越界/非有限）由 LyricSchemaValidator 检查。
                try requireNumberOrNil(value, path: path, expected: "整数毫秒或 null")
            case "translations":
                guard let dict = value as? [String: Any] else {
                    throw BackupRejection.wrongType(path: path, expected: "对象")
                }
                try walkObject(dict, path: path, level: .translations, depth: depth + 1)
            default:
                break
            }
        }

        private func walkTranslationKey(key: String, value: Any, path: String) throws {
            switch key {
            case "text", "source":
                try requireString(value, path: path, expected: "字符串")
            case "needsReview":
                guard value is Bool else {
                    throw BackupRejection.wrongType(path: path, expected: "布尔")
                }
            default:
                break
            }
        }

        private func walkBindingKey(key: String, value: Any, path: String, depth: Int) throws {
            switch key {
            case "trackKey":
                try requireString(value, path: path, expected: "字符串")
            case "lyricDocumentId":
                try requireUUID(value, path: path)
            case "updatedAt":
                try requireString(value, path: path, expected: "字符串")
            case "userDelayMs", "durationHintMs":
                try requireIntOrNil(value, path: path, expected: "整数或 null")
            case "titleHint", "artistHint", "persistentId":
                try requireStringOrNil(value, path: path, expected: "字符串或 null")
            case "track":
                guard let dict = value as? [String: Any] else {
                    throw BackupRejection.wrongType(path: path, expected: "对象")
                }
                try walkObject(dict, path: path, level: .track, depth: depth + 1)
            default:
                break
            }
        }

        /// settings：任意键、值必须是字符串；条数受限；白名单过滤在解析层做。
        private func walkSettings(_ object: [String: Any], path: String) throws {
            guard object.count <= limits.maxSettingsEntries else {
                throw BackupRejection.tooManySettings(
                    count: object.count, limit: limits.maxSettingsEntries
                )
            }
            for key in object.keys.sorted() {
                guard object[key] is String else {
                    throw BackupRejection.settingsValueNotString(key: key)
                }
            }
        }

        /// 已知数组键：条数限制 + 逐元素按层遍历。
        private func walkArray(
            _ value: Any,
            path: String,
            elementLevel: WalkLevel,
            depth: Int,
            limit: Int
        ) throws {
            guard let array = value as? [Any] else {
                throw BackupRejection.wrongType(path: path, expected: "数组")
            }
            guard array.count <= limit else {
                throw BackupRejection.oversizedArray(path: path, count: array.count, limit: limit)
            }
            for (index, element) in array.enumerated() {
                guard let dict = element as? [String: Any] else {
                    throw BackupRejection.wrongType(path: "\(path)[\(index)]", expected: "对象")
                }
                try walkObject(dict, path: "\(path)[\(index)]", level: elementLevel, depth: depth + 1)
            }
        }

        /// 未知键的值：只做深度与数组条数兜底，不检查键白名单。
        private func walkUnknownValue(_ value: Any, path: String, depth: Int) throws {
            guard depth <= limits.maxDepth else {
                throw BackupRejection.tooDeep(path: path, depth: depth, limit: limits.maxDepth)
            }
            if let dict = value as? [String: Any] {
                for key in dict.keys.sorted() {
                    guard let child = dict[key] else { continue }
                    try walkUnknownValue(child, path: "\(path).\(key)", depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                guard array.count <= limits.maxUnknownArrayLength else {
                    throw BackupRejection.oversizedArray(
                        path: path, count: array.count, limit: limits.maxUnknownArrayLength
                    )
                }
                for (index, element) in array.enumerated() {
                    try walkUnknownValue(element, path: "\(path)[\(index)]", depth: depth + 1)
                }
            }
        }

        // MARK: - 标量类型检查

        private func requireInt(_ value: Any, path: String, expected: String) throws -> Int {
            guard let number = value as? NSNumber, !isBoolean(number), let int = exactInt(number) else {
                throw BackupRejection.wrongType(path: path, expected: expected)
            }
            return int
        }

        private func requireIntOrNil(_ value: Any, path: String, expected: String) throws {
            if value is NSNull { return }
            _ = try requireInt(value, path: path, expected: expected)
        }

        private func requireNumberOrNil(_ value: Any, path: String, expected: String) throws {
            if value is NSNull { return }
            guard let number = value as? NSNumber, !isBoolean(number) else {
                throw BackupRejection.wrongType(path: path, expected: expected)
            }
        }

        private func requireString(_ value: Any, path: String, expected: String) throws {
            guard value is String else {
                throw BackupRejection.wrongType(path: path, expected: expected)
            }
        }

        private func requireStringOrNil(_ value: Any, path: String, expected: String) throws {
            if value is NSNull { return }
            try requireString(value, path: path, expected: expected)
        }

        private func requireUUID(_ value: Any, path: String) throws {
            guard let text = value as? String, UUID(uuidString: text) != nil else {
                throw BackupRejection.invalidUUID(
                    path: path, value: (value as? String) ?? String(describing: value)
                )
            }
        }

        private func isBoolean(_ number: NSNumber) -> Bool {
            String(cString: number.objCType) == "c"
        }

        private func exactInt(_ number: NSNumber) -> Int? {
            switch String(cString: number.objCType) {
            case "c", "i", "s", "l", "q":
                return number.intValue
            case "f", "d":
                return Int(exactly: number.doubleValue)
            default:
                return nil
            }
        }
    }
}
