import Foundation
import ShinAppleKit
import ShinAppleData

// MARK: - 歌词编辑会话的公开数据模型

/// 编辑器快照：一次编辑操作后 UI 需要的全部状态。
/// 行数组按文档顺序排列；译文与 needsReview 挂在 LyricLine 上随 id 走。
public struct LyricsEditingSnapshot: Equatable, Sendable {
    /// 正在编辑的文档 id（打开后不变）。
    public let documentId: UUID
    /// 基线 revision：打开时（或上次成功保存后）的库内版本。
    /// 本次提交将写入 baseRevision + 1。
    public let baseRevision: Int
    public let lines: [LyricLine]
    public let canUndo: Bool
    public let canRedo: Bool
    /// 工作副本与基线不一致（存在未保存修改）。
    public let hasUnsavedChanges: Bool

    /// 提交时将写入的 revision（基线 + 1；store 的乐观并发要求）。
    public var pendingRevision: Int { baseRevision + 1 }
}

/// 行移动方向（编辑器列表内）。
public enum LyricsEditingMoveDirection: Sendable {
    /// 向列表上方（更早显示顺序）移动。
    case up
    /// 向列表下方移动。
    case down
}

/// 歌词编辑会话的类型化错误。所有失败都可判别、可定位，
/// 不静默修改数据；草稿在任何错误后都保持可用。
public enum LyricsEditingError: Error, Equatable, Sendable {
    /// 没有打开的编辑会话。
    case noOpenEditor
    /// 已有打开的编辑会话（先关闭后才能再开）。
    case editorAlreadyOpen
    /// 目标文档不存在（可能已被删除）。
    case documentNotFound(UUID)
    /// 找不到指定行（行操作一律按稳定 id 定位，绝不用数组下标）。
    case lineNotFound(lineId: UUID)
    /// 时间输入非法；lineId 用于把错误定位到对应行内联显示。
    case invalidTimeInput(lineId: UUID, rawInput: String, reason: LyricTimeInputParser.Failure)
    /// 行数达到上限（与导入解析的产品限制一致：10,000 行）。
    case lineLimitReached(limit: Int)
    /// revision 乐观并发冲突：库中已有更新的版本（如另一窗口已保存）。
    /// 草稿保留，绝不静默覆盖。
    case revisionConflict(documentId: UUID, storedRevision: Int, submittedRevision: Int)
    /// 存储不可用（I/O 失败等）。
    case storageUnavailable(String)
    /// 存储层拒绝的其他类型化原因。
    case storeRejection(String)

    /// 行数上限：与解析器 10,000 行产品限制一致。
    public static let lineLimit = 10_000

    /// 面向用户的中文说明。
    public var message: String {
        switch self {
        case .noOpenEditor:
            return "当前没有打开的歌词编辑会话。"
        case .editorAlreadyOpen:
            return "已有打开的歌词编辑会话，请先关闭后再打开新的编辑。"
        case .documentNotFound(let id):
            return "目标歌词文档不存在（可能已被删除）：\(id.uuidString)"
        case .lineNotFound(let lineId):
            return "找不到目标歌词行：\(lineId.uuidString)"
        case .invalidTimeInput(_, let rawInput, let reason):
            return "时间「\(rawInput)」无法识别：\(Self.failureDescription(reason))"
        case .lineLimitReached(let limit):
            return "歌词行数已达上限（\(limit) 行），无法继续新增。"
        case .revisionConflict(let documentId, let stored, let submitted):
            return "歌词已被其他窗口保存（库中 revision \(stored)，本编辑器提交 \(submitted)）：\(documentId.uuidString)。你的修改仍保留，可选择重新载入或稍后重试。"
        case .storageUnavailable(let detail):
            return "本地歌词库不可用：\(detail)"
        case .storeRejection(let detail):
            return "保存被拒绝：\(detail)"
        }
    }

    private static func failureDescription(_ reason: LyricTimeInputParser.Failure) -> String {
        switch reason {
        case .malformed:
            return "写法不符合支持的格式（[mm:ss.fff]、秒或毫秒）"
        case .secondsOutOfRange(let seconds):
            return "秒数 \(seconds) 超出 0–59"
        case .negativeNotAllowed:
            return "时间不能为负"
        case .fractionalMilliseconds:
            return "毫秒不能带小数"
        case .outOfRange:
            return "数值超出可表示范围"
        }
    }

    /// 把存储层错误映射为本层类型化错误（内部使用，测试可直接断言）。
    static func mapStoreError(_ error: Error) -> LyricsEditingError {
        switch error {
        case let mapped as LyricsEditingError:
            return mapped
        case let dataError as ShinAppleDataError:
            return mapDataError(dataError)
        default:
            return .storeRejection(String(describing: type(of: error)))
        }
    }

    private static func mapDataError(_ dataError: ShinAppleDataError) -> LyricsEditingError {
        switch dataError {
        case let .revisionConflict(documentId, stored, submitted):
            return .revisionConflict(
                documentId: documentId, storedRevision: stored, submittedRevision: submitted
            )
        case let .storageUnavailable(detail):
            return .storageUnavailable(detail)
        case let .invalidDocument(issues):
            return .storeRejection("歌词数据未通过完整性校验（\(issues.count) 处）")
        case let .invalidBinding(detail):
            return .storeRejection("歌曲关联数据非法：\(detail)")
        case let .invalidRevision(documentId, revision):
            return .storeRejection("文档 \(documentId.uuidString) 的 revision 非法：\(revision)")
        case let .documentNotFound(id):
            return .documentNotFound(id)
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
