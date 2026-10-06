import Foundation
import ShinAppleKit

// 完整备份的数据结构与导入/导出配置。
// 备份文件是权威无损出口：含原文（originalText）/译文/时间/offset/
// 绑定（含 userDelayMs 与提示字段）/revision/schemaVersion/白名单设置。
// 结构上不存在 token、密钥、Apple 用户身份、音频等字段。

/// 备份文件顶层模型（BackupFile JSON，schemaVersion 独立于文档 schema）。
/// v2：绑定支持 `music-script:persistent:` 身份
/// （`track` 可缺省、新增 `persistentId`）；导入端同时接受 v1。
public struct BackupFile: Codable, Equatable, Sendable {
    /// 备份格式版本；未来版本由导入端拒绝（原库不动）。
    public static let currentSchemaVersion = 2
    /// 可导入的最旧版本（v1：全目录身份绑定）。
    public static let oldestSupportedSchemaVersion = 1

    public var schemaVersion: Int
    /// ISO8601 UTC 字符串。
    public var exportedAt: String
    public var documents: [LyricDocument]
    public var bindings: [BackupBinding]
    /// 仅白名单键（BackupConfiguration.settingAllowlist）。
    public var settings: [String: String]

    init(
        schemaVersion: Int = BackupFile.currentSchemaVersion,
        exportedAt: String,
        documents: [LyricDocument],
        bindings: [BackupBinding],
        settings: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.documents = documents
        self.bindings = bindings
        self.settings = settings
    }
}

/// 备份中的目录歌曲身份（CatalogIdentity 的 Codable 镜像）。
public struct BackupCatalogIdentity: Codable, Equatable, Sendable {
    public var storefront: String
    public var catalogSongId: String

    public init(storefront: String, catalogSongId: String) {
        self.storefront = storefront
        self.catalogSongId = catalogSongId
    }

    init(track: CatalogIdentity) {
        self.storefront = track.storefront
        self.catalogSongId = track.catalogSongId
    }

    var catalogIdentity: CatalogIdentity {
        CatalogIdentity(storefront: storefront, catalogSongId: catalogSongId)
    }
}

/// 备份中的绑定（SongBinding 的 Codable 镜像）。
/// v2：`track`（目录身份）可缺省，新增 `persistentId`；两者恰有一个非空。
/// v1 备份文件全部带 `track`，解码后照常还原。
public struct BackupBinding: Codable, Equatable, Sendable {
    public var trackKey: String
    /// v1 目录身份（v2 脚本绑定为 nil；旧版本应用无法解码缺 track 的文件）。
    public var track: BackupCatalogIdentity?
    /// v2 Music 脚本 persistent ID（目录绑定为 nil）。
    public var persistentId: String?
    public var lyricDocumentId: UUID
    public var userDelayMs: Int64
    public var titleHint: String?
    public var artistHint: String?
    public var durationHintMs: Int64?
    public var updatedAt: String

    public init(from binding: SongBinding) {
        self.trackKey = binding.trackKey
        self.track = binding.track.map(BackupCatalogIdentity.init(track:))
        self.persistentId = binding.persistentID
        self.lyricDocumentId = binding.lyricDocumentId
        self.userDelayMs = binding.userDelayMs
        self.titleHint = binding.titleHint
        self.artistHint = binding.artistHint
        self.durationHintMs = binding.durationHintMs
        self.updatedAt = binding.updatedAt
    }

    /// 还原为领域绑定模型（调用方先用 validateIdentity 校验一致性）。
    public var songBinding: SongBinding {
        if let persistentId {
            return SongBinding(
                persistentID: persistentId,
                lyricDocumentId: lyricDocumentId,
                userDelayMs: userDelayMs,
                titleHint: titleHint,
                artistHint: artistHint,
                durationHintMs: durationHintMs,
                updatedAt: updatedAt
            )
        }
        guard let track else {
            // 缺少身份的绑定在 BackupParser.validateBindings 已拒绝；
            // 此处兜底以目录空身份构造会被 store 校验拒绝，不会静默入库。
            return SongBinding(
                track: CatalogIdentity(storefront: "", catalogSongId: ""),
                lyricDocumentId: lyricDocumentId,
                userDelayMs: userDelayMs,
                titleHint: titleHint,
                artistHint: artistHint,
                durationHintMs: durationHintMs,
                updatedAt: updatedAt
            )
        }
        return SongBinding(
            track: track.catalogIdentity,
            lyricDocumentId: lyricDocumentId,
            userDelayMs: userDelayMs,
            titleHint: titleHint,
            artistHint: artistHint,
            durationHintMs: durationHintMs,
            updatedAt: updatedAt
        )
    }
}

/// 导入/导出的可配置限制。默认量级与解析层一致（2 MiB / 10,000 行）。
public struct BackupLimits: Equatable, Sendable {
    public var maxBytes: Int
    public var maxDocuments: Int
    public var maxBindings: Int
    /// 所有文档的行数总和上限。
    public var maxTotalLines: Int
    public var maxSettingsEntries: Int
    /// JSON 嵌套深度上限（含未知键下的内容，防御恶意构造）。
    public var maxDepth: Int
    public var maxUnknownArrayLength: Int

    public static let standard = BackupLimits(
        maxBytes: 2 * 1024 * 1024,
        maxDocuments: 10_000,
        maxBindings: 10_000,
        maxTotalLines: 10_000,
        maxSettingsEntries: 256,
        maxDepth: 32,
        maxUnknownArrayLength: 10_000
    )

    public init(
        maxBytes: Int,
        maxDocuments: Int,
        maxBindings: Int,
        maxTotalLines: Int,
        maxSettingsEntries: Int,
        maxDepth: Int,
        maxUnknownArrayLength: Int
    ) {
        self.maxBytes = maxBytes
        self.maxDocuments = maxDocuments
        self.maxBindings = maxBindings
        self.maxTotalLines = maxTotalLines
        self.maxSettingsEntries = maxSettingsEntries
        self.maxDepth = maxDepth
        self.maxUnknownArrayLength = maxUnknownArrayLength
    }
}

/// 备份配置：限制 + 设置白名单。
/// 白名单默认为空：v1 尚未定义可移植设置；应用加入可移植设置键时，
/// 必须同步扩展白名单并补充往返测试。
public struct BackupConfiguration: Equatable, Sendable {
    public var limits: BackupLimits
    public var settingAllowlist: Set<String>

    public static let standard = BackupConfiguration(
        limits: .standard,
        settingAllowlist: []
    )

    public init(limits: BackupLimits = .standard, settingAllowlist: Set<String> = []) {
        self.limits = limits
        self.settingAllowlist = settingAllowlist
    }
}

/// 解析/导入阶段的非致命提示（不静默丢弃任何东西）。
public enum BackupWarning: Equatable, Sendable {
    /// 未知键：按白名单解码时被忽略，但显式告知调用方。
    case unknownKey(path: String, key: String)
    /// 不在白名单内的设置键：不导入，但显式告知。
    case settingNotInAllowlist(key: String)
    /// 输入带 UTF-8 BOM：已剥离后解析。
    case utf8BomStripped
}

/// 解析成功（尚未提交）的备份：模型 + 提示。冲突预览与提交都以此为准。
/// 使用编译器合成的 memberwise 初始化器（模块内构造）。
public struct BackupParseResult: Equatable, Sendable {
    /// settings 已按白名单过滤，只含可导入键。
    public var file: BackupFile
    public var warnings: [BackupWarning]
}

/// 当前库状态的纯值快照，供纯函数冲突预览使用（UI 也可自行构造/比对）。
/// 使用编译器合成的 memberwise 初始化器。
public struct BackupStoreSnapshot: Equatable, Sendable {
    public var documents: [UUID: LyricDocument]
    /// key 为 trackKey。
    public var bindings: [String: SongBinding]
    public var settings: [String: String]
}

/// 预览：将被替换的文档（现有 → 传入）。
public struct BackupDocumentReplacement: Equatable, Sendable {
    public var existing: LyricDocument
    public var incoming: LyricDocument
}

/// 预览：将被替换的绑定（现有 → 传入）。
public struct BackupBindingReplacement: Equatable, Sendable {
    public var existing: SongBinding
    public var incoming: BackupBinding
}

/// 预览：将被替换的设置（现有 → 传入）。
public struct BackupSettingReplacement: Equatable, Sendable {
    public var existing: String
    public var incoming: String
}

/// 冲突预览（纯函数结果）：确认后提交将新增/替换的内容。
/// 与备份一致且库中已相同的条目是 no-op，不出现。
public struct BackupConflictPreview: Equatable, Sendable {
    public var documentsToAdd: [LyricDocument]
    public var documentReplacements: [BackupDocumentReplacement]
    public var bindingsToAdd: [SongBinding]
    public var bindingReplacements: [BackupBindingReplacement]
    public var settingsToWrite: [String: String]
    public var settingsToReplace: [String: BackupSettingReplacement]

    /// 没有任何写入（备份与库完全一致）。
    public var isEmpty: Bool {
        documentsToAdd.isEmpty
            && documentReplacements.isEmpty
            && bindingsToAdd.isEmpty
            && bindingReplacements.isEmpty
            && settingsToWrite.isEmpty
            && settingsToReplace.isEmpty
    }
}

/// 重新导入同一首歌的冲突预览（确认界面数据源）。
public struct ReimportPreview: Equatable, Sendable {
    public var trackKey: String
    /// 该曲目当前绑定；nil 表示全新关联（无覆盖）。
    public var replacedBinding: SongBinding?
    public var incomingDocumentId: UUID
    /// 替换后不再被任何曲目引用的旧文档（不会被自动删除，仅提示）。
    public var documentsLosingLastBinding: [LyricDocument]
}
