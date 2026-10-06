import Foundation
import ShinAppleKit

// ShinAppleData 的类型化错误。
// 说明：契约 `LyricsRepositoryError`（ShinAppleKit）只有两个不带详细载荷的 case；
// 存储层需要更细的类型（stored/submitted revision、受影响绑定数、备份拒绝原因等），
// 因此本包统一抛出 ShinAppleDataError，并提供到契约错误的映射
// （`contractError`）。需要契约方跟进的点：给 LyricsRepositoryError
// 增加详细载荷或补充"输入非法"类 case。

/// 存储层错误。所有公开 API 抛出的错误都是本类型。
public enum ShinAppleDataError: Error, Equatable, Sendable {
    /// revision 乐观并发冲突：storedRevision 是库中当前版本，
    /// submittedRevision 是提交方带来的版本。绝不静默覆盖。
    case revisionConflict(documentId: UUID, storedRevision: Int, submittedRevision: Int)
    /// 仓库不可用（打开失败、I/O 失败、数据库损坏、只读等）。
    case storageUnavailable(String)
    /// 文档未通过 schema v1 校验（保存/导入的防御性校验）。
    case invalidDocument([LyricSchemaIssue])
    /// revision 非法（< 1）。
    case invalidRevision(documentId: UUID, revision: Int)
    /// 绑定数据非法（trackKey 与 track 身份不一致、指向别的文档等）。
    case invalidBinding(String)
    /// 设置键非法（如空字符串）。
    case invalidSettingKey(String)
    /// 目标文档不存在。
    case documentNotFound(UUID)
    /// 文档仍被绑定引用，拒绝删除（deletingAffectedBindings = false 时）。
    case documentInUse(documentId: UUID, affectedBindingCount: Int)
    /// 备份被拒绝（导入流水线各阶段的类型化拒绝原因）。
    case invalidBackup(BackupRejection)

    /// 映射到 ShinAppleKit 的契约错误；输入类错误没有契约对应物，返回 nil。
    public var contractError: LyricsRepositoryError? {
        switch self {
        case let .revisionConflict(documentId, _, _):
            return .revisionConflict(documentId: documentId)
        case let .storageUnavailable(message):
            return .storageUnavailable(message)
        default:
            return nil
        }
    }

    /// storageUnavailable 中携带的数据文件路径（打开/迁移失败时
    /// 错误消息内嵌数据库路径，供 UI 展示「数据在哪里、先备份什么」的指引；
    /// 运行期写入失败等其他 storageUnavailable 不保证含路径，返回 nil）。
    ///
    /// 路径提取依赖 `GRDBLyricsStore` 的两类结构化消息前缀（见其
    /// `openFailureMessage` / `migrationFailureMessage`），两处必须同步修改。
    public var dataFilePath: String? {
        guard case let .storageUnavailable(message) = self else { return nil }
        for prefix in Self.pathMessagePrefixes {
            guard message.hasPrefix(prefix) else { continue }
            let remainder = message.dropFirst(prefix.count)
            guard let end = remainder.firstIndex(of: "：") else { continue }
            let candidate = String(remainder[..<end])
            return candidate.isEmpty ? nil : candidate
        }
        return nil
    }

    /// 结构化消息前缀：前缀之后、下一个「：」之前是数据库路径。
    static let pathMessagePrefixes = [
        "无法打开数据库 ",
        "数据库迁移失败（原库保留在上一版本）："
    ]
}

/// 仅测试使用的注入点：在事务内部模拟某一步写入失败，验证整体回滚。
/// 抛出的是 storageUnavailable，与真实写失败在同一错误路径上。
enum SaveFailurePoint: Sendable {
    case afterDocumentWrite
    case afterBindingWrite
}
