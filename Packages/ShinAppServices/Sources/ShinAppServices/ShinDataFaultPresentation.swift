import Foundation
import ShinAppleData

// MARK: - 存储层失败的统一中文呈现与恢复分类
//
// 「失败时错误消息区分来源」的单一出口：三个应用服务（导入/编辑/歌词库）
// 的 `mapDataError` 共用本表，保证每个 `ShinAppleDataError` case 都有
// 中文说明与建议动作分类（有穷尽性测试保证新增 case 不被遗漏）。
//
// 错误呈现原则：
// - 只描述发生了什么与用户可以做什么，不假装成功、不自动重试；
// - 备份损坏保留 parse 阶段的类型化拒绝原因，不吞细节；
// - 存储不可用保留底层细节（打开/迁移失败时含数据文件路径，
//   见 `ShinAppleDataError.dataFilePath`），供 UI 给出「先备份、
//   不要删除/重建数据文件」的指引。

/// 存储层失败的恢复建议分类（封闭集合；UI 据此提供对应恢复动作）。
public enum LyricsRecoveryHint: Equatable, Sendable {
    /// 用户显式重试同一操作即可（幂等的瞬时失败）。
    case retry
    /// 载入库中最新版本后再继续（revision 冲突：其他窗口已保存更新版本，
    /// 本地草稿保留，绝不静默覆盖）。
    case reloadLatest
    /// 检查磁盘空间与文件权限，并保留数据目录备份（存储不可用/损坏；
    /// 绝不自动删除或重建库文件）。
    case checkStorageAndBackup
    /// 修正输入内容后重试（schema 校验、绑定/设置数据非法等输入类拒绝）。
    case fixInput
    /// 刷新界面状态后重试（目标已不存在，例如文档刚被其他窗口删除）。
    case refreshState
    /// 先处理关联/引用关系再重试（文档仍被绑定引用等）。
    case resolveReferences
    /// 更换或修复备份文件后重试（备份损坏/版本过新；原数据不受影响）。
    case fixBackup
}

/// `ShinAppleDataError` 的中文 message 与恢复分类。
public enum ShinDataFaultPresentation {

    /// 面向用户的中文说明（区分失败来源，可直接展示）。
    public static func message(for error: ShinAppleDataError) -> String {
        switch error {
        case let .revisionConflict(documentId, stored, submitted):
            return "歌词已被其他窗口保存（库中 revision \(stored)，提交 \(submitted)），"
                + "已取消本次保存以避免覆盖：\(documentId.uuidString)。可载入库中最新版本后重做修改。"
        case let .storageUnavailable(detail):
            return "本地歌词库不可用：\(detail)"
        case let .invalidDocument(issues):
            return "歌词数据未通过完整性校验（共 \(issues.count) 处），已拒绝写入，原数据不受影响。"
        case let .invalidRevision(documentId, revision):
            return "歌词版本号非法（\(revision)），已拒绝写入：\(documentId.uuidString)"
        case let .invalidBinding(detail):
            return "歌曲关联数据非法：\(detail)"
        case let .invalidSettingKey(detail):
            return "设置项非法：\(detail)"
        case .documentNotFound(let id):
            return "目标歌词文档不存在（可能已被删除）：\(id.uuidString)"
        case let .documentInUse(documentId, count):
            return "该歌词仍被 \(count) 首歌曲关联，请先处理关联后再删除：\(documentId.uuidString)"
        case let .invalidBackup(rejection):
            return "备份文件未通过校验：\(backupRejectionReason(rejection))；原数据不受影响。"
        }
    }

    /// 建议的恢复动作分类。
    public static func recoveryHint(for error: ShinAppleDataError) -> LyricsRecoveryHint {
        switch error {
        case .revisionConflict:
            return .reloadLatest
        case .storageUnavailable:
            return .checkStorageAndBackup
        case .invalidDocument, .invalidRevision, .invalidBinding, .invalidSettingKey:
            return .fixInput
        case .documentNotFound:
            return .refreshState
        case .documentInUse:
            return .resolveReferences
        case .invalidBackup:
            return .fixBackup
        }
    }

    /// 备份 parse 阶段类型化拒绝原因的中文说明（保留细节，不吞原因）。
    /// 按拒绝类别分三组呈现（格式与体量 / 字段内容 / 身份与语义）。
    public static func backupRejectionReason(_ rejection: BackupRejection) -> String {
        switch rejection {
        case .notUTF8, .tooLarge, .invalidJSON, .unexpectedRoot, .tooDeep, .oversizedArray:
            return formatOrSizeReason(rejection)
        case .settingsValueNotString, .tooManySettings, .missingField, .wrongType,
             .invalidUUID, .invalidTimestamp, .invalidRevision:
            return fieldContentReason(rejection)
        case .unsupportedSchemaVersion, .trackKeyMismatch, .duplicateDocumentId,
             .duplicateTrackKey, .danglingBinding, .schemaIssues:
            return identityOrSemanticReason(rejection)
        }
    }

    /// 格式与体量类拒绝（编码、大小、JSON 结构、嵌套/数组限制）。
    private static func formatOrSizeReason(_ rejection: BackupRejection) -> String {
        switch rejection {
        case let .notUTF8(reason):
            return "文件不是 UTF-8 文本（\(reason)）"
        case let .tooLarge(bytes, limit):
            return "文件过大（\(bytes) 字节，上限 \(limit) 字节）"
        case let .invalidJSON(detail):
            return "不是合法 JSON（\(detail)）"
        case let .unexpectedRoot(detail):
            return "文件顶层结构不是备份对象（\(detail)）"
        case let .tooDeep(path, depth, limit):
            return "嵌套层级超限（\(path)：深度 \(depth)，上限 \(limit)）"
        case let .oversizedArray(path, count, limit):
            return "数组条目超限（\(path)：\(count) 项，上限 \(limit) 项）"
        default:
            preconditionFailure("非格式与体量类拒绝：\(rejection)")
        }
    }

    /// 字段内容类拒绝（设置值、缺失字段、类型、UUID/时间戳/revision 非法）。
    private static func fieldContentReason(_ rejection: BackupRejection) -> String {
        switch rejection {
        case let .settingsValueNotString(key):
            return "设置值必须是文本（键「\(key)」）"
        case let .tooManySettings(count, limit):
            return "设置条目过多（\(count) 项，上限 \(limit) 项）"
        case let .missingField(path):
            return "缺少必需字段（\(path)）"
        case let .wrongType(path, expected):
            return "字段类型不符（\(path)：期望 \(expected)）"
        case let .invalidUUID(path, value):
            return "非法 UUID（\(path)：\(value)）"
        case let .invalidTimestamp(path, value):
            return "非法时间戳（\(path)：\(value)）"
        case let .invalidRevision(path, revision):
            return "非法 revision（\(path)：\(revision)）"
        default:
            preconditionFailure("非字段内容类拒绝：\(rejection)")
        }
    }

    /// 身份与语义类拒绝（版本、trackKey 防篡改、重复 id、悬挂绑定、schema）。
    private static func identityOrSemanticReason(_ rejection: BackupRejection) -> String {
        switch rejection {
        case let .unsupportedSchemaVersion(found):
            return "备份格式版本过新（版本 \(found)），请先升级应用再导入"
        case let .trackKeyMismatch(path, declared, expected):
            return "trackKey 与曲目身份不一致（\(path)：声明 \(declared)，应为 \(expected)）"
        case let .duplicateDocumentId(id):
            return "备份内出现重复文档 id（\(id.uuidString)）"
        case let .duplicateTrackKey(key):
            return "备份内出现重复曲目键（\(key)）"
        case let .danglingBinding(documentId):
            return "绑定指向备份中不存在的文档（\(documentId.uuidString)）"
        case let .schemaIssues(issues):
            return "歌词内容未通过完整性校验（共 \(issues.count) 处）"
        default:
            preconditionFailure("非身份与语义类拒绝：\(rejection)")
        }
    }
}
