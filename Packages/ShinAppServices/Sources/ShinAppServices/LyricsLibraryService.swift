import Foundation
import ShinAppleKit
import ShinAppleData

// MARK: - 本地歌词库管理服务
//
// 面向「本地歌词库」页的读模型与文档级写操作：
// - libraryOverview：文档列表（文件名/标题提示、行数、打轴统计、
//   updatedAt、关联绑定数与曲目提示）；
// - 删除流程：affectedBindings(forDeletionOf:) 先取受影响绑定清单供用户
//   确认；确认后 deleteDocument(id:) 经 store 单事务删除文档及其全部
//   绑定——原子提交，任何路径都不产生悬空引用（外键 restrict + 同事务删除）；
// - reassociate：把某曲目重新关联到另一文档，原关联文档原样保留；
// - 备份包装：exportBackup / parseBackup → backupConflictPreview（确认页
//   数据源透传）→ importBackup（确认后单事务提交）；
// - exportLRC：按文档导出 LRC（两种模式，见 LRCExporter）。
//
// 无状态、线程安全；存储错误统一映射为 LyricsLibraryError。

/// 概览行里的一条绑定摘要（「关联绑定数与曲目提示」数据源）。
public struct LyricsLibraryBindingSummary: Equatable, Sendable {
    public let trackKey: String
    public let titleHint: String?
    public let artistHint: String?
    /// 该曲目当前的播放延迟（整数毫秒；正数 = 延后）。
    public let userDelayMs: Int64

    init(binding: SongBinding) {
        self.trackKey = binding.trackKey
        self.titleHint = binding.titleHint
        self.artistHint = binding.artistHint
        self.userDelayMs = binding.userDelayMs
    }
}

/// 本地歌词库概览行（一个歌词文档一行）。
public struct LyricsLibraryOverviewItem: Equatable, Sendable {
    public let documentId: UUID
    /// 导入时的原始文件名；未知为 nil。
    public let originalFilename: String?
    /// 标题提示：元信息 ti 标签首值；未知为 nil。
    public let titleHint: String?
    public let revision: Int
    /// 文档 offset 原样保存值（整数毫秒；显示时经公式换算，不在行内）。
    public let sourceOffsetMs: Int64
    public let lineCount: Int
    public let timedLineCount: Int
    public let untimedLineCount: Int
    /// ISO8601 文档时间戳。
    public let updatedAt: String
    /// 指向本文档的全部绑定（按 trackKey 排序，输出确定）。
    public let bindings: [LyricsLibraryBindingSummary]

    public var bindingCount: Int { bindings.count }
    /// 关联曲目的标题提示（可能含 nil 项被略去；仅展示用）。
    public var trackHints: [String] { bindings.compactMap(\.titleHint) }
}

/// 歌词库管理的类型化错误。面向用户的中文说明见 `message`。
public enum LyricsLibraryError: Error, Equatable, Sendable {
    /// 目标文档不存在（可能已被删除）。
    case documentNotFound(UUID)
    /// trackKey 与项目命名空间不符（`music-script:persistent:<id>` 或
    /// 旧 `apple-music:catalog:<storefront>:<id>`）。
    case invalidTrackKey(String)
    /// 存储不可用（I/O 失败等）。
    case storageUnavailable(String)
    /// 存储层拒绝的其他类型化原因。
    case storeRejection(String)

    public var message: String {
        switch self {
        case .documentNotFound(let id):
            return "目标歌词文档不存在（可能已被删除）：\(id.uuidString)"
        case .invalidTrackKey(let key):
            return "曲目标识非法（无法解析为已知命名空间的曲目身份）：\(key)"
        case .storageUnavailable(let detail):
            return "本地歌词库不可用：\(detail)"
        case .storeRejection(let detail):
            return "操作被拒绝：\(detail)"
        }
    }

    /// 把存储层错误映射为本层类型化错误（内部使用，测试可直接断言）。
    static func mapStoreError(_ error: Error) -> LyricsLibraryError {
        switch error {
        case let mapped as LyricsLibraryError:
            return mapped
        case let dataError as ShinAppleDataError:
            return mapDataError(dataError)
        default:
            return .storeRejection(String(describing: type(of: error)))
        }
    }

    private static func mapDataError(_ dataError: ShinAppleDataError) -> LyricsLibraryError {
        switch dataError {
        case let .documentNotFound(id):
            return .documentNotFound(id)
        case let .storageUnavailable(detail):
            return .storageUnavailable(detail)
        case let .invalidBinding(detail):
            return .storeRejection("歌曲关联数据非法：\(detail)")
        case let .revisionConflict(documentId, stored, submitted):
            return .storeRejection(
                "文档已被其他窗口修改（库中 revision \(stored)，提交 \(submitted)）：\(documentId.uuidString)"
            )
        case let .documentInUse(documentId, count):
            return .storeRejection("文档 \(documentId.uuidString) 仍被 \(count) 个绑定引用")
        case let .invalidDocument(issues):
            return .storeRejection("歌词数据未通过完整性校验（共 \(issues.count) 处），已拒绝写入。")
        case let .invalidRevision(documentId, revision):
            return .storeRejection("文档 \(documentId.uuidString) 的 revision 非法：\(revision)")
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

/// 本地歌词库管理服务。无状态 struct；全部方法可安全并发调用。
public struct LyricsLibraryService: Sendable {

    // internal：同模块的 +Backup 扩展复用；对外不可见。
    let store: GRDBLyricsStore

    public init(store: GRDBLyricsStore) {
        self.store = store
    }

    // MARK: - 概览

    /// 全部歌词文档的概览行（按 documentId 排序，输出确定）。
    /// v3 起读文档摘要列，不解码每篇文档的全部歌词行（性能补强）。
    public func libraryOverview() async throws -> [LyricsLibraryOverviewItem] {
        do {
            let summaries = try await store.allDocumentSummaries()
            let bindings = try await store.allBindings()
            // 单次扫描分组；文档与绑定都来自同一读序列（store 内两次只读）。
            var byDocument: [UUID: [LyricsLibraryBindingSummary]] = [:]
            for binding in bindings {
                byDocument[binding.lyricDocumentId, default: []].append(
                    LyricsLibraryBindingSummary(binding: binding)
                )
            }
            return summaries.map { summary in
                LyricsLibraryOverviewItem(
                    documentId: summary.id,
                    originalFilename: summary.originalFilename,
                    titleHint: summary.titleHint,
                    revision: summary.revision,
                    sourceOffsetMs: summary.sourceOffsetMs,
                    lineCount: summary.lineCount,
                    timedLineCount: summary.timedLineCount,
                    untimedLineCount: summary.untimedLineCount,
                    updatedAt: summary.updatedAt,
                    bindings: byDocument[summary.id] ?? []
                )
            }
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    // MARK: - 删除（先预览受影响绑定，确认后原子删除）

    /// 删除确认页数据源：指向该文档的全部绑定（复用 store 的
    /// bindings(referencing:)）。文档不存在抛 documentNotFound。
    public func affectedBindings(forDeletionOf documentId: UUID) async throws -> [SongBinding] {
        do {
            guard try await store.document(id: documentId) != nil else {
                throw LyricsLibraryError.documentNotFound(documentId)
            }
            return try await store.bindings(referencing: documentId)
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    /// 确认后执行删除：单事务删除文档及其全部绑定，原子、不留悬空引用。
    /// 返回被一并解除的绑定（展示用；与确认预览之间如有并发写入，
    /// 实际删除以事务内的完整清单为准）。文档不存在抛 documentNotFound。
    @discardableResult
    public func deleteDocument(id documentId: UUID) async throws -> [SongBinding] {
        do {
            let affected = try await store.bindings(referencing: documentId)
            try await store.deleteDocument(id: documentId, deletingAffectedBindings: true)
            return affected
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    // MARK: - 重新关联

    /// 把 `trackKey` 曲目重新关联到 `toDocumentId` 文档：
    /// - 已有绑定时保留该曲目的 userDelayMs 与提示字段，仅换目标文档并刷新时间；
    /// - 无既有绑定时新建默认绑定（userDelayMs = 0）；
    /// - 原关联文档原样保留（本方法绝不删除任何文档）；
    /// - 目标文档不存在抛 documentNotFound；trackKey 非法抛 invalidTrackKey。
    /// v2：trackKey 支持目录与脚本两个命名空间。
    @discardableResult
    public func reassociate(trackKey: String, toDocumentId: UUID) async throws -> SongBinding {
        do {
            guard try await store.document(id: toDocumentId) != nil else {
                throw LyricsLibraryError.documentNotFound(toDocumentId)
            }
            let existing = try await store.allBindings().first { $0.trackKey == trackKey }
            let binding: SongBinding
            switch SongBinding.trackIdentity(fromTrackKey: trackKey) {
            case .scriptPersistentID(let persistentID):
                binding = SongBinding(
                    persistentID: persistentID,
                    lyricDocumentId: toDocumentId,
                    userDelayMs: existing?.userDelayMs ?? 0,
                    titleHint: existing?.titleHint,
                    artistHint: existing?.artistHint,
                    durationHintMs: existing?.durationHintMs
                )
            case .catalog(let track):
                binding = SongBinding(
                    track: track,
                    lyricDocumentId: toDocumentId,
                    userDelayMs: existing?.userDelayMs ?? 0,
                    titleHint: existing?.titleHint,
                    artistHint: existing?.artistHint,
                    durationHintMs: existing?.durationHintMs
                )
            case nil:
                throw LyricsLibraryError.invalidTrackKey(trackKey)
            }
            var refreshed = binding
            refreshed.updatedAt = LyricTimestamp.now()
            try await store.updateBinding(refreshed)
            return refreshed
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }
}
