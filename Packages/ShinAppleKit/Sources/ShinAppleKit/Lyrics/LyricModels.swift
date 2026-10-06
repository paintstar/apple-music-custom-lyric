import Foundation

// domain/lyrics：歌词数据模型定稿。
// 纯 Swift 值类型：不依赖 SwiftUI / 播放 SDK / 网络 / 数据库。
// 内部时间统一整数毫秒；未知值用 nil，绝不冒充 0。

/// 歌词来源格式。
public enum LyricSourceFormat: String, Codable, Equatable, Sendable {
    /// 标准 LRC（元信息 + 时间戳）。
    case lrc
    /// 纯文本（无时间戳），所有行 startMs = nil。
    case text
    /// 本项目 JSON 完整备份，导入前须进行 schema 校验。
    case nativeJSON = "native-json"
}

/// 一句译文。绑定到 LyricLine 的稳定 id，而不是数组下标。
public struct Translation: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case manual
        case imported
    }

    public var text: String
    public var source: Source
    /// 原文修改后，对应译文应被标为待复核。
    public var needsReview: Bool

    public init(text: String, source: Source = .manual, needsReview: Bool = false) {
        self.text = text
        self.source = source
        self.needsReview = needsReview
    }
}

/// 一行歌词。id 为稳定 UUID（同文本多时间戳展开时每个实例各有独立 id）；
/// 时间统一整数毫秒；未打轴文本为 nil，可静态显示，不参与动态高亮。
public struct LyricLine: Codable, Equatable, Sendable {
    public var id: UUID
    /// 整数毫秒；nil 表示未打轴。注意：文件 offset 不在此换算。
    public var startMs: Int64?
    public var text: String
    /// key 为 BCP-47 语言代码（如 "zh-Hans"）；空对象表示无翻译。
    /// 重复时间戳的多行不推断「第一行原文、第二行译文」，翻译只经明确绑定。
    public var translations: [String: Translation]

    public init(
        id: UUID = UUID(),
        startMs: Int64?,
        text: String,
        translations: [String: Translation] = [:]
    ) {
        self.id = id
        self.startMs = startMs
        self.text = text
        self.translations = translations
    }
}

/// 歌词文档。保存有 revision；文档与绑定必须原子写入。
public struct LyricDocument: Codable, Equatable, Sendable {
    /// schemaVersion 用于未来迁移；v1 恒为 1。未知版本在导入时拒绝。
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    /// 每次显式保存递增。
    public var revision: Int
    /// 原文语言（BCP-47），未知为 nil。
    public var sourceLanguage: String?
    public var sourceFormat: LyricSourceFormat
    /// LRC 文件 offset（整数毫秒）。
    ///
    /// - 本项目约定：正值 = 原文件歌词提前。换算公式
    ///   `effectiveStartMs = line.startMs - sourceOffsetMs + binding.userDelayMs`
    ///   只在查询/跳转/导出边界使用；导入时绝不把该值加进任何 line.startMs。
    /// - 这是本项目约定，不是所有 LRC 软件的统一行为；来源表现相反时
    ///   由用户在预览中纠正，保存后不偷偷翻转。
    public var sourceOffsetMs: Int64
    /// 原始输入仅保留本地用于追溯；编辑后的权威是 lines，
    /// 导出与播放一律使用 lines，不得用 originalText 复原旧歌词。
    public var originalText: String?
    public var originalFilename: String?
    /// 元信息（ar/ti/al/by 等及未知键）；键保留原样，同键多值按出现顺序累积。
    /// offset 是特殊标签，存入 sourceOffsetMs，不重复进入本字典。
    public var metadata: [String: [String]]
    public var lines: [LyricLine]
    /// ISO8601 字符串；是文档时间戳，不是播放时间。
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        sourceLanguage: String? = nil,
        sourceFormat: LyricSourceFormat = .lrc,
        sourceOffsetMs: Int64 = 0,
        originalText: String? = nil,
        originalFilename: String? = nil,
        metadata: [String: [String]] = [:],
        lines: [LyricLine] = [],
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.revision = revision
        self.sourceLanguage = sourceLanguage
        self.sourceFormat = sourceFormat
        self.sourceOffsetMs = sourceOffsetMs
        self.originalText = originalText
        self.originalFilename = originalFilename
        self.metadata = metadata
        self.lines = lines
        let created = createdAt ?? LyricTimestamp.now()
        self.createdAt = created
        self.updatedAt = updatedAt ?? created
    }
}

/// 曲目身份（v2，带来源命名空间）。强标识必须标注来源与作用域；
/// 不把本地 ID 当官方目录 ID。
public enum TrackIdentity: Equatable, Sendable {
    /// v1 历史：Apple Music 目录歌曲（storefront + catalogSongId）。
    /// v2 只读兼容保留，不再产生新绑定。
    case catalog(CatalogIdentity)
    /// v2：Music 脚本 persistent ID（作用域：本机音乐库；跨机器/重建库需重新确认）。
    case scriptPersistentID(String)
}

/// 歌曲与歌词文档的绑定。userDelayMs > 0 表示歌词延后显示（本项目 UI 约定）。
public struct SongBinding: Equatable, Sendable {
    /// v1 目录命名空间前缀：`apple-music:catalog:`。
    public static let catalogTrackKeyPrefix = "apple-music:catalog:"
    /// v2 脚本身份命名空间前缀：`music-script:persistent:`。
    public static let scriptTrackKeyPrefix = "music-script:persistent:"

    /// 稳定曲目键（命名空间化）：
    /// v1 `apple-music:catalog:<storefront>:<catalogSongId>`；
    /// v2 `music-script:persistent:<persistentID>`。
    /// 这是本项目的命名空间格式，不是 Apple 指定的 ID 格式。
    public var trackKey: String
    /// v1 目录身份（历史绑定兼容保留；v2 脚本绑定为 nil）。
    public var track: CatalogIdentity?
    /// v2 Music 脚本 persistent ID（目录绑定为 nil）；与 `track` 恰有一个非 nil。
    public var persistentID: String?
    public var lyricDocumentId: UUID
    /// 正数让歌词更晚出现；与文件 offset（sourceOffsetMs）分开保存。
    public var userDelayMs: Int64
    public var titleHint: String?
    public var artistHint: String?
    /// 用户确认关联时的曲目时长提示（整数毫秒），未知为 nil。
    public var durationHintMs: Int64?
    public var updatedAt: String

    /// v1 目录绑定构造（历史兼容；v2 新绑定请用 `init(persistentID:...)`）。
    public init(
        track: CatalogIdentity,
        lyricDocumentId: UUID,
        userDelayMs: Int64 = 0,
        titleHint: String? = nil,
        artistHint: String? = nil,
        durationHintMs: Int64? = nil,
        updatedAt: String? = nil
    ) {
        self.trackKey = Self.trackKey(for: track)
        self.track = track
        self.persistentID = nil
        self.lyricDocumentId = lyricDocumentId
        self.userDelayMs = userDelayMs
        self.titleHint = titleHint
        self.artistHint = artistHint
        self.durationHintMs = durationHintMs
        self.updatedAt = updatedAt ?? LyricTimestamp.now()
    }

    /// v2 脚本绑定构造：persistent ID 带来源命名空间。
    public init(
        persistentID: String,
        lyricDocumentId: UUID,
        userDelayMs: Int64 = 0,
        titleHint: String? = nil,
        artistHint: String? = nil,
        durationHintMs: Int64? = nil,
        updatedAt: String? = nil
    ) {
        precondition(
            !persistentID.isEmpty,
            "SongBinding(persistentID:) 不接受空 persistentID（未知身份用 nil 表达，不冒充有效键）"
        )
        self.trackKey = Self.trackKey(persistentID: persistentID)
        self.track = nil
        self.persistentID = persistentID
        self.lyricDocumentId = lyricDocumentId
        self.userDelayMs = userDelayMs
        self.titleHint = titleHint
        self.artistHint = artistHint
        self.durationHintMs = durationHintMs
        self.updatedAt = updatedAt ?? LyricTimestamp.now()
    }

    /// 按项目命名空间构造 v1 目录曲目键；不使用歌名等模糊信息。
    public static func trackKey(for track: CatalogIdentity) -> String {
        "\(catalogTrackKeyPrefix)\(track.storefront):\(track.catalogSongId)"
    }

    /// 按项目命名空间构造 v2 脚本曲目键。
    public static func trackKey(persistentID: String) -> String {
        "\(scriptTrackKeyPrefix)\(persistentID)"
    }

    /// 解析命名空间化曲目键为曲目身份；无法识别的键返回 nil（调用方拒绝，不猜测）。
    public static func trackIdentity(fromTrackKey key: String) -> TrackIdentity? {
        if key.hasPrefix(scriptTrackKeyPrefix) {
            let persistentID = String(key.dropFirst(scriptTrackKeyPrefix.count))
            guard Self.isValidPersistentID(persistentID) else { return nil }
            return .scriptPersistentID(persistentID)
        }
        guard key.hasPrefix(catalogTrackKeyPrefix) else { return nil }
        let remainder = key.dropFirst(catalogTrackKeyPrefix.count)
        let parts = remainder.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let track = CatalogIdentity(storefront: String(parts[0]), catalogSongId: String(parts[1]))
        // 推导值与原键一致才接受（防构造出与声明不符的身份）。
        guard trackKey(for: track) == key else { return nil }
        return .catalog(track)
    }

    /// 脚本 persistent ID 白名单：1–64 位十六进制字符（Music 词典注明
    /// "hexadecimal string"）。长度上限是项目输入限制，用于防止脚本注入。
    public static func isValidPersistentID(_ value: String) -> Bool {
        (1...64).contains(value.count)
            && value.allSatisfy { $0.isHexDigit }
    }
}

/// ISO8601 文档时间戳工具。每次调用独立 formatter，避免共享可变状态。
public enum LyricTimestamp {
    /// 当前时刻的 ISO8601 字符串。
    public static func now() -> String {
        string(from: Date())
    }

    /// Date → ISO8601 字符串（UTC，如 "2026-01-02T03:04:05Z"）。
    public static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// ISO8601 字符串 → Date；格式非法返回 nil。
    public static func date(from iso8601: String) -> Date? {
        ISO8601DateFormatter().date(from: iso8601)
    }
}
