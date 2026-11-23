import Foundation

// 备份 JSON 结构化预检（v3 学习注记与生词本扩展）。
// 从 BackupWalk.swift 拆出，保持类型与文件长度在 SwiftLint 限制内。

extension WalkLevel {
    var isStudyLevel: Bool {
        switch self {
        case .pronunciation, .studyNote, .studyAnnotationSource,
             .vocabularyEntry, .vocabularyExample, .vocabularyOccurrence:
            return true
        default:
            return false
        }
    }

    var studyKnownKeys: Set<String> {
        switch self {
        case .pronunciation:
            return ["style", "text", "source", "needsReview"]
        case .studyNote:
            return ["grammarSummary", "singingTips", "culturalNote", "source", "needsReview", "updatedAt"]
        case .studyAnnotationSource:
            return ["kind", "model"]
        case .vocabularyEntry:
            return [
                "id", "surface", "lemma", "reading", "language", "partOfSpeech",
                "generalMeaning", "examples", "userNote", "mastery", "createdAt", "updatedAt"
            ]
        case .vocabularyExample:
            return ["text", "translation"]
        case .vocabularyOccurrence:
            return [
                "id", "entryId", "lyricDocumentId", "lineId", "utf16Location", "utf16Length",
                "surfaceInLine", "contextualMeaning", "lineTextSnapshot", "lineTranslationSnapshot",
                "startMsSnapshot", "trackKeyHint", "trackTitleHint", "artistHint", "createdAt"
            ]
        default:
            return []
        }
    }
}

extension BackupWalk.Walker {

    func walkStudyKnownKey(
        key: String,
        value: Any,
        path: String,
        level: WalkLevel,
        depth: Int
    ) throws {
        switch level {
        case .pronunciation:
            try walkPronunciationKey(key: key, value: value, path: path, depth: depth)
        case .studyNote:
            try walkStudyNoteKey(key: key, value: value, path: path, depth: depth)
        case .studyAnnotationSource:
            try walkStudyAnnotationSourceKey(key: key, value: value, path: path)
        case .vocabularyEntry:
            try walkVocabularyEntryKey(key: key, value: value, path: path, depth: depth)
        case .vocabularyExample:
            try walkVocabularyExampleKey(key: key, value: value, path: path)
        case .vocabularyOccurrence:
            try walkVocabularyOccurrenceKey(key: key, value: value, path: path)
        default:
            break
        }
    }

    private func walkPronunciationKey(key: String, value: Any, path: String, depth: Int) throws {
        switch key {
        case "style", "text":
            try requireString(value, path: path, expected: "字符串")
        case "needsReview":
            try requireBool(value, path: path)
        case "source":
            guard let dict = value as? [String: Any] else {
                throw BackupRejection.wrongType(path: path, expected: "对象")
            }
            try walkObject(dict, path: path, level: .studyAnnotationSource, depth: depth + 1)
        default:
            break
        }
    }

    private func walkStudyNoteKey(key: String, value: Any, path: String, depth: Int) throws {
        switch key {
        case "grammarSummary", "updatedAt":
            try requireString(value, path: path, expected: "字符串")
        case "singingTips", "culturalNote":
            try requireStringOrNil(value, path: path, expected: "字符串或 null")
        case "needsReview":
            try requireBool(value, path: path)
        case "source":
            guard let dict = value as? [String: Any] else {
                throw BackupRejection.wrongType(path: path, expected: "对象")
            }
            try walkObject(dict, path: path, level: .studyAnnotationSource, depth: depth + 1)
        default:
            break
        }
    }

    private func walkStudyAnnotationSourceKey(key: String, value: Any, path: String) throws {
        switch key {
        case "kind":
            try requireString(value, path: path, expected: "字符串")
        case "model":
            try requireStringOrNil(value, path: path, expected: "字符串或 null")
        default:
            break
        }
    }

    private func walkVocabularyEntryKey(key: String, value: Any, path: String, depth: Int) throws {
        switch key {
        case "id":
            try requireUUID(value, path: path)
        case "surface", "lemma", "generalMeaning", "mastery", "createdAt", "updatedAt":
            try requireString(value, path: path, expected: "字符串")
        case "reading", "language", "partOfSpeech", "userNote":
            try requireStringOrNil(value, path: path, expected: "字符串或 null")
        case "examples":
            try walkArray(
                value, path: path, elementLevel: .vocabularyExample,
                depth: depth, limit: limits.maxUnknownArrayLength
            )
        default:
            break
        }
    }

    private func walkVocabularyExampleKey(key: String, value: Any, path: String) throws {
        switch key {
        case "text":
            try requireString(value, path: path, expected: "字符串")
        case "translation":
            try requireStringOrNil(value, path: path, expected: "字符串或 null")
        default:
            break
        }
    }

    private func walkVocabularyOccurrenceKey(key: String, value: Any, path: String) throws {
        switch key {
        case "id", "entryId":
            try requireUUID(value, path: path)
        case "lyricDocumentId", "lineId":
            try requireUUIDOrNil(value, path: path)
        case "utf16Location", "utf16Length":
            _ = try requireInt(value, path: path, expected: "整数")
        case "startMsSnapshot":
            try requireIntOrNil(value, path: path, expected: "整数或 null")
        case "surfaceInLine", "contextualMeaning", "lineTextSnapshot", "createdAt":
            try requireString(value, path: path, expected: "字符串")
        case "lineTranslationSnapshot", "trackKeyHint", "trackTitleHint", "artistHint":
            try requireStringOrNil(value, path: path, expected: "字符串或 null")
        default:
            break
        }
    }

    private func requireUUIDOrNil(_ value: Any, path: String) throws {
        if value is NSNull { return }
        try requireUUID(value, path: path)
    }

    private func requireBool(_ value: Any, path: String) throws {
        guard value is Bool else {
            throw BackupRejection.wrongType(path: path, expected: "布尔")
        }
    }
}
