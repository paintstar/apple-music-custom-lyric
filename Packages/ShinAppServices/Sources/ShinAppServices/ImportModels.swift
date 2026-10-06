import Foundation
import ShinAppleKit
import ShinAppleData

// 导入会话的公开数据模型。
// 预览模型只携带展示所需信息，不把内部可变状态暴露给 UI；
// 所有时间均为整数毫秒，未知值为 nil。

/// 导入会话目标：打开会话时固定的歌曲身份与提示信息。
/// 目标在会话打开时明确选定，
/// 不跟随当前播放曲目静默变化；导入过程中切歌不会绑定错歌。
/// v2：身份以命名空间化 trackKey 表达
/// （`music-script:persistent:<id>`；旧 `apple-music:catalog:` 仅供历史
/// 数据兼容，不再产生新绑定）。
public struct ImportSessionTarget: Equatable, Sendable {
    /// 命名空间化曲目键。
    public let trackKey: String
    public let titleHint: String?
    public let artistHint: String?
    /// 用户确认关联时的曲目时长提示（整数毫秒），未知为 nil。
    public let durationHintMs: Int64?

    /// v1 兼容构造：目录歌曲身份（历史路径；新代码请用 `init(trackKey:...)`）。
    public init(
        track: CatalogIdentity,
        titleHint: String? = nil,
        artistHint: String? = nil,
        durationHintMs: Int64? = nil
    ) {
        self.init(
            trackKey: SongBinding.trackKey(for: track),
            titleHint: titleHint,
            artistHint: artistHint,
            durationHintMs: durationHintMs
        )
    }

    public init(
        trackKey: String,
        titleHint: String? = nil,
        artistHint: String? = nil,
        durationHintMs: Int64? = nil
    ) {
        self.trackKey = trackKey
        self.titleHint = titleHint
        self.artistHint = artistHint
        self.durationHintMs = durationHintMs
    }
}

/// 双语导入的预览信息：策略层映射结果的展示投影。
/// 只携带展示所需数据，不携带可变文档；未启用（mode == .off）时预览中为 nil。
public struct BilingualPreviewInfo: Equatable, Sendable {
    public let mode: BilingualMode
    /// N 行原文（应用策略后的文档行数）。
    public let originalLineCount: Int
    /// M 行配到译文。
    public let translatedLineCount: Int
    /// K 条双语映射警告（只有警告、不阻止导入）。
    public let warnings: [BilingualWarning]
    /// 配对对照区数据（按结果文档行序；UI 取前若干行展示）。
    public let pairRows: [BilingualPairRow]
}

/// 导入预览：解析成功后、用户确认前的全部展示信息。
public struct ImportPreview: Equatable, Sendable {
    /// 预览对应的文档 id（确认提交时保存的就是该文档）。
    public let documentId: UUID
    public let filename: String?
    public let sourceFormat: LyricSourceFormat
    /// 解析诊断（error = 不可保存；warning = 可保存但需提示）。
    public let diagnostics: [LyricDiagnostic]
    public let totalLineCount: Int
    public let timedLineCount: Int
    public let untimedLineCount: Int
    /// 识别到的元信息（ar/ti/al/by 及未知键，键保留原样）。
    public let metadata: [String: [String]]
    /// LRC offset 标签的原样保存值；绝不在导入时烘焙进行时间。
    public let sourceOffsetMs: Int64
    /// 是否存在可成对的同时间戳行组（仅 LRC；决定「成对」选项是否可选）。
    public let pairedTimestampsAvailable: Bool
    /// 双语映射结果；未启用（.off）时为 nil。
    public let bilingual: BilingualPreviewInfo?

    /// 诊断中存在 error 时不可确认保存。
    public var isImportable: Bool {
        diagnostics.allSatisfy { $0.severity != .error }
    }

    /// 元信息取首值的便捷读取（UI 展示用）。
    public func firstMetadataValue(for key: String) -> String? {
        metadata[key]?.first
    }

    /// 项目 offset 约定说明（导入预览页固定展示）。
    public static let sourceOffsetNote =
        "sourceOffsetMs 是本项目约定：正值表示原文件歌词提前，"
            + "显示时间 = 行时间 − sourceOffsetMs + 用户延迟。"
            + "它不会改写行内时间戳，也不是所有 LRC 软件的统一行为。"
}

/// 目标歌曲当前已有的绑定信息（确认卡的「将被替换」数据源）。
public struct ExistingBindingInfo: Equatable, Sendable {
    public let binding: SongBinding
    /// 绑定指向的现有文档；异常情况下可能为 nil。
    public let document: LyricDocument?
    /// 现有文档还被哪些其他曲目共享（重导入替换后它们不受影响）。
    public let otherBindings: [SongBinding]
}

/// 确认导入的结果。
public struct ImportConfirmation: Equatable, Sendable {
    public let document: LyricDocument
    public let binding: SongBinding
    /// 被替换的旧绑定（nil = 全新关联，此前无绑定）。
    public let replacedBinding: SongBinding?
    /// 替换后失去最后一个绑定的旧文档；保留在库中，不会被自动删除。
    public let documentsLosingLastBinding: [LyricDocument]
}

/// 导入工作流的类型化错误。解析/校验类错误发生后会话保持打开，
/// 用户可以直接重新选择文件重试。
public enum ImportWorkflowError: Error, Equatable, Sendable {
    /// 已有打开的会话（先 cancel 或 confirm 后才能开新会话）。
    case sessionAlreadyOpen
    /// 没有打开的会话。
    case noOpenSession
    /// 会话已完成（confirm 成功后本会话结束；重新导入请开新会话）。
    case sessionCompleted
    /// 二次确认：上一次 confirm 已成功提交，拒绝重复提交。
    case alreadyConfirmed
    /// 解析失败（超限/空文件/无法解码）；会话保持打开可重选文件。
    case parseFailure(LyricParseError)
    /// 文档未通过 schema v1 校验；会话保持打开可重选文件。
    case schemaRejected([LyricSchemaIssue])
    /// 尚未成功导入任何文件就请求确认。
    case nothingIngested
    /// 预览诊断含 error，不可确认保存。
    case previewHasErrors
    /// 保存时检测到 revision 乐观并发冲突（库中版本已更新）。
    case revisionConflict(documentId: UUID, storedRevision: Int, submittedRevision: Int)
    /// 存储不可用（打开/迁移/I/O 失败等）。
    case storageUnavailable(String)
    /// 存储层拒绝的其他类型化原因（绑定非法、revision 非法等）。
    case storeRejection(String)

    /// 面向用户的中文说明。
    public var message: String {
        switch self {
        case .sessionAlreadyOpen:
            return "已有进行中的导入会话，请先取消或完成后再开始新的导入。"
        case .noOpenSession:
            return "当前没有进行中的导入会话。"
        case .sessionCompleted:
            return "本次导入已完成。如需重新导入，请重新开始一次导入。"
        case .alreadyConfirmed:
            return "这份歌词已经保存过，不会重复提交。"
        case .parseFailure(let error):
            return error.message
        case .schemaRejected(let issues):
            return "文件内容未通过数据校验（共 \(issues.count) 处），已拒绝导入。"
        case .nothingIngested:
            return "还没有成功读取任何歌词文件。"
        case .previewHasErrors:
            return "文件存在无法保存的错误，请根据诊断修正后重新选择文件。"
        case .revisionConflict(let documentId, let stored, let submitted):
            return "文档已被其他窗口修改（库中 revision \(stored)，提交 \(submitted)）：\(documentId.uuidString)"
        case .storageUnavailable(let detail):
            return "本地歌词库不可用：\(detail)"
        case .storeRejection(let detail):
            return "保存被拒绝：\(detail)"
        }
    }

    /// 把存储层错误映射为本层类型化错误（内部使用，测试可直接断言）。
    static func mapStoreError(_ error: Error) -> ImportWorkflowError {
        switch error {
        case let mapped as ImportWorkflowError:
            return mapped
        case let dataError as ShinAppleDataError:
            return mapDataError(dataError)
        default:
            return .storeRejection(String(describing: type(of: error)))
        }
    }

    private static func mapDataError(_ dataError: ShinAppleDataError) -> ImportWorkflowError {
        switch dataError {
        case let .revisionConflict(documentId, stored, submitted):
            return .revisionConflict(
                documentId: documentId, storedRevision: stored, submittedRevision: submitted
            )
        case let .storageUnavailable(detail):
            return .storageUnavailable(detail)
        case let .invalidDocument(issues):
            return .schemaRejected(issues)
        case let .invalidBinding(detail):
            return .storeRejection(detail)
        case let .invalidRevision(documentId, revision):
            return .storeRejection("文档 \(documentId.uuidString) 的 revision 非法：\(revision)")
        case let .documentNotFound(id):
            return .storeRejection("目标文档不存在：\(id.uuidString)")
        case let .documentInUse(documentId, count):
            return .storeRejection("文档 \(documentId.uuidString) 仍被 \(count) 个绑定引用")
        case let .invalidBackup(rejection):
            // 保留备份 parse 的类型化拒绝原因（中文），不丢细节。
            return .storeRejection(
                "备份文件未通过校验：\(ShinDataFaultPresentation.backupRejectionReason(rejection))"
            )
        case let .invalidSettingKey(detail):
            return .storeRejection("设置项非法：\(detail)")
        }
    }
}
