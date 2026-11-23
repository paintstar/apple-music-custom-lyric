import Foundation

// domain/study：歌词词汇与本机词典查询模型。
// 纯 Swift 值类型：不依赖 SwiftUI / 播放 SDK / 网络 / 数据库。

// 领域词表需保留 mastery/mastered（表示语言学习「掌握程度」），仅对该词根做局部规则豁免。
// swiftlint:disable inclusive_language
/// 生词掌握程度。
public enum VocabularyMastery: String, Codable, CaseIterable, Equatable, Sendable {
    /// 初学中。
    case learning
    /// 复习巩固中。
    case reviewing
    /// 已掌握。
    case mastered

    /// 面向界面展示的中文名称。
    public var displayName: String {
        switch self {
        case .learning: return "学习中"
        case .reviewing: return "复习中"
        case .mastered: return "已掌握"
        }
    }
}
// swiftlint:enable inclusive_language

/// 生词例句及可选译文。
public struct VocabularyExample: Codable, Equatable, Sendable {
    public var text: String
    public var translation: String?

    public init(text: String, translation: String? = nil) {
        self.text = text
        self.translation = translation
    }
}

/// 生词本词条，跨歌曲聚合同一词元（lemma）的学习记录。
public struct VocabularyEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 首次或代表性表层词形。
    public var surface: String
    /// 规范词元（原型）。
    public var lemma: String
    /// 读音标注（如假名、音标或罗马音）。
    public var reading: String?
    /// 语言代码（BCP-47，如 "ja"、"en"），未知为 nil。
    public var language: String?
    /// 词性描述，未知为 nil。
    public var partOfSpeech: String?
    /// 通用释义。
    public var generalMeaning: String
    public var examples: [VocabularyExample]
    public var userNote: String?
    // swiftlint:disable:next inclusive_language
    public var mastery: VocabularyMastery
    /// ISO8601 创建与更新时间戳。
    public var createdAt: String
    public var updatedAt: String

    // swiftlint:disable inclusive_language
    public init(
        id: UUID = UUID(),
        surface: String,
        lemma: String? = nil,
        reading: String? = nil,
        language: String? = nil,
        partOfSpeech: String? = nil,
        generalMeaning: String = "",
        examples: [VocabularyExample] = [],
        userNote: String? = nil,
        mastery: VocabularyMastery = .learning,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
    // swiftlint:enable inclusive_language
        self.id = id
        self.surface = surface
        self.lemma = lemma ?? surface
        self.reading = reading
        self.language = language
        self.partOfSpeech = partOfSpeech
        self.generalMeaning = generalMeaning
        self.examples = examples
        self.userNote = userNote
        self.mastery = mastery
        let created = createdAt ?? LyricTimestamp.now()
        self.createdAt = created
        self.updatedAt = updatedAt ?? created
    }
}

/// 生词在具体歌词行中的一次出现位置与语境快照。
public struct VocabularyOccurrence: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 所属 `VocabularyEntry.id`。
    public var entryId: UUID
    public var lyricDocumentId: UUID?
    public var lineId: UUID?
    /// 词形在原文行内的 UTF-16 起始偏移与长度（与 Cocoa/NSString 选区一致）。
    public var utf16Location: Int
    public var utf16Length: Int
    /// 该行中的实际表层词形。
    public var surfaceInLine: String
    /// 该语境下的特定释义。
    public var contextualMeaning: String
    /// 原文行与译文快照，避免歌词微调或删除后丢失历史语境。
    public var lineTextSnapshot: String
    public var lineTranslationSnapshot: String?
    public var startMsSnapshot: Int64?
    /// 关联曲目提示字段（仅供回顾展示，不作为强标识）。
    public var trackKeyHint: String?
    public var trackTitleHint: String?
    public var artistHint: String?
    /// ISO8601 创建时间戳。
    public var createdAt: String

    public init(
        id: UUID = UUID(),
        entryId: UUID,
        lyricDocumentId: UUID? = nil,
        lineId: UUID? = nil,
        utf16Location: Int = 0,
        utf16Length: Int = 0,
        surfaceInLine: String,
        contextualMeaning: String = "",
        lineTextSnapshot: String,
        lineTranslationSnapshot: String? = nil,
        startMsSnapshot: Int64? = nil,
        trackKeyHint: String? = nil,
        trackTitleHint: String? = nil,
        artistHint: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.entryId = entryId
        self.lyricDocumentId = lyricDocumentId
        self.lineId = lineId
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.surfaceInLine = surfaceInLine
        self.contextualMeaning = contextualMeaning
        self.lineTextSnapshot = lineTextSnapshot
        self.lineTranslationSnapshot = lineTranslationSnapshot
        self.startMsSnapshot = startMsSnapshot
        self.trackKeyHint = trackKeyHint
        self.trackTitleHint = trackTitleHint
        self.artistHint = artistHint
        self.createdAt = createdAt ?? LyricTimestamp.now()
    }
}

/// 本机离线词典与语言分析的查询结果。
public struct LocalDictionaryLookupResult: Equatable, Sendable {
    public var query: String
    public var lemma: String?
    public var partOfSpeech: String?
    public var detectedLanguage: String?
    public var systemDefinition: String?
    public var reading: String?

    public init(
        query: String,
        lemma: String? = nil,
        partOfSpeech: String? = nil,
        detectedLanguage: String? = nil,
        systemDefinition: String? = nil,
        reading: String? = nil
    ) {
        self.query = query
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.detectedLanguage = detectedLanguage
        self.systemDefinition = systemDefinition
        self.reading = reading
    }
}
