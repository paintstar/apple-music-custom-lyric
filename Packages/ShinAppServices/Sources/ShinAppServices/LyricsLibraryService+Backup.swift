import Foundation
import ShinAppleKit
import ShinAppleData

// MARK: - 歌词库服务：完整备份包装与 LRC 导出

extension LyricsLibraryService {

    // MARK: - 完整 JSON 备份（权威无损出口）

    /// 导出完整备份（含原文/译文/时间/offset/绑定/revision/schema/白名单设置）。
    /// 同一 Date 参数下输出字节确定。结构上不含 token/密钥/音频。
    public func exportBackup(at date: Date = Date()) async throws -> Data {
        do {
            return try await store.exportBackup(at: date)
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    /// 解析备份字节（不写库）。非法备份抛类型化拒绝原因，原库不变。
    public func parseBackup(_ data: Data) throws -> BackupParseResult {
        do {
            return try store.parseBackup(data)
        } catch let error as ShinAppleDataError {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    /// 冲突预览（确认页数据源）：列出将新增/替换的文档、绑定与设置。
    /// 纯读操作，可在确认页停留期间反复调用。
    public func backupConflictPreview(
        for parsed: BackupParseResult
    ) async throws -> BackupConflictPreview {
        do {
            return try await store.backupConflictPreview(for: parsed)
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    /// 用户确认后提交导入（单事务；备份对同 id 文档/同键绑定是权威替换）。
    /// 必须先经 parseBackup + backupConflictPreview 展示并取得用户确认。
    public func importBackup(_ parsed: BackupParseResult) async throws {
        do {
            try await store.importBackup(parsed)
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }

    // MARK: - LRC 互操作导出

    /// 按文档导出 LRC（语义见 `LRCExporter`）。
    ///
    /// 用户延迟解析规则（`.appliedOffset` 模式）：
    /// - 显式传入 `userDelayMs` 时以传入值为准；
    /// - 否则取指向本文档的绑定中 trackKey 最小者的当前延迟（输出确定）；
    /// - 无绑定时按 0 处理。实际应用的延迟值已写入损失说明。
    public func exportLRC(
        documentId: UUID,
        mode: LRCExportMode,
        userDelayMs explicitDelay: Int64? = nil
    ) async throws -> LRCExportResult {
        do {
            guard let document = try await store.document(id: documentId) else {
                throw LyricsLibraryError.documentNotFound(documentId)
            }
            let delay: Int64
            if let explicitDelay {
                delay = explicitDelay
            } else {
                // bindings(referencing:) 按 trackKey 排序 → 取值确定。
                delay = try await store.bindings(referencing: documentId).first?.userDelayMs ?? 0
            }
            return LRCExporter.export(document: document, mode: mode, userDelayMs: delay)
        } catch {
            throw LyricsLibraryError.mapStoreError(error)
        }
    }
}
