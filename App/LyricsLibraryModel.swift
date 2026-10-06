import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 本地歌词库状态机：包裹应用服务层的 LyricsLibraryService。
// - 概览刷新、删除确认（先取受影响绑定清单）、重新关联、
//   完整 JSON 备份导出/导入（解析 → 冲突预览 → 确认提交）、LRC 导出；
// - 所有写操作都要求显式确认；失败给出中文提示，不假报成功；
// - 库发生变化（删除/换绑/备份导入）后经 onLibraryChanged 通知宿主刷新
//   歌词面板，当前曲目状态即时反映。

@MainActor
final class LyricsLibraryModel: ObservableObject {

    /// 备份导入阶段：idle → 预览（确认页）→ 提交中 → 完成反馈。
    enum BackupStage: Equatable {
        case idle
        /// 预览就绪：解析结果 + 冲突预览（将新增/替换的文档与绑定）。
        case preview(BackupParseResult, BackupConflictPreview)
        case importing
        /// 导入完成，附反馈文案。
        case completed(String)
    }

    /// 删除确认数据：目标文档 + 受影响绑定清单。
    struct DeletionPreview: Equatable {
        let documentId: UUID
        let displayName: String
        let bindings: [SongBinding]
    }

    /// LRC 导出对话框状态。
    struct LRCExportState: Equatable {
        let item: LyricsLibraryOverviewItem
        var mode: LRCExportMode = .originalTimes
        /// 按当前模式计算的结果（文本 + 损失说明 + 裁剪行数）。
        var result: LRCExportResult?
    }

    @Published private(set) var items: [LyricsLibraryOverviewItem] = []
    @Published private(set) var isLoading = false
    /// 顶层错误/提示（中文）；nil 表示无。
    @Published var alertMessage: String?
    @Published private(set) var deletionPreview: DeletionPreview?
    @Published private(set) var backupStage: BackupStage = .idle
    /// 备份导出内容就绪后置位（视图据此呈现 fileExporter）。
    @Published private(set) var pendingBackupExport: Data?
    @Published private(set) var lrcExport: LRCExportState?

    /// 库发生变化后的回调（宿主刷新歌词面板）。
    var onLibraryChanged: (() -> Void)?

    private let service: LyricsLibraryService
    /// 代序号：关闭确认弹窗/新操作使旧异步结果失效。
    private var generation = 0

    init(store: GRDBLyricsStore) {
        service = LyricsLibraryService(store: store)
    }

    // MARK: - 概览

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.libraryOverview()
        } catch {
            alertMessage = ErrorText.describe(error)
        }
    }

    // MARK: - 删除（预览受影响绑定 → 确认 → 原子删除）

    func requestDeletion(_ item: LyricsLibraryOverviewItem) async {
        generation += 1
        let currentGeneration = generation
        do {
            let bindings = try await service.affectedBindings(forDeletionOf: item.documentId)
            guard currentGeneration == generation else { return }
            deletionPreview = DeletionPreview(
                documentId: item.documentId,
                displayName: Self.displayName(for: item),
                bindings: bindings
            )
        } catch {
            alertMessage = ErrorText.describe(error)
        }
    }

    /// 取消删除：只清空确认状态，不触碰库。
    func cancelDeletion() {
        generation += 1
        deletionPreview = nil
    }

    func confirmDeletion() async {
        generation += 1
        let currentGeneration = generation
        guard let preview = deletionPreview else { return }
        do {
            let deleted = try await service.deleteDocument(id: preview.documentId)
            guard currentGeneration == generation else { return }
            deletionPreview = nil
            alertMessage = "已删除「\(preview.displayName)」并解除 \(deleted.count) 个歌曲关联。"
            await refresh()
            onLibraryChanged?()
        } catch {
            guard currentGeneration == generation else { return }
            deletionPreview = nil
            alertMessage = ErrorText.describe(error)
        }
    }

    // MARK: - 重新关联（当前曲目 → 这份歌词）

    /// v2：按命名空间化 trackKey 重新关联（脚本身份或历史目录身份）。
    func reassociate(trackKey: String, to item: LyricsLibraryOverviewItem) async {
        generation += 1
        let currentGeneration = generation
        do {
            _ = try await service.reassociate(
                trackKey: trackKey,
                toDocumentId: item.documentId
            )
            guard currentGeneration == generation else { return }
            alertMessage = "已将当前歌曲关联到「\(Self.displayName(for: item))」；原关联的歌词文档保留在库中。"
            await refresh()
            onLibraryChanged?()
        } catch {
            guard currentGeneration == generation else { return }
            alertMessage = ErrorText.describe(error)
        }
    }

    // MARK: - LRC 导出

    /// 打开 LRC 导出对话框（默认「原始时间」模式并立即计算结果与损失说明）。
    func beginLRCExport(_ item: LyricsLibraryOverviewItem) async {
        let state = LRCExportState(item: item)
        lrcExport = state
        await recomputeLRCExport()
    }

    /// 切换导出模式：重新计算（偏移只在用户确认导出时写入文件）。
    func changeLRCMode(_ mode: LRCExportMode) async {
        guard lrcExport != nil else { return }
        lrcExport?.mode = mode
        await recomputeLRCExport()
    }

    func cancelLRCExport() {
        lrcExport = nil
    }

    private func recomputeLRCExport() async {
        guard let item = lrcExport?.item, let mode = lrcExport?.mode else { return }
        do {
            let result = try await service.exportLRC(documentId: item.documentId, mode: mode)
            lrcExport?.result = result
        } catch {
            alertMessage = ErrorText.describe(error)
        }
    }

    // MARK: - 完整 JSON 备份

    /// 生成备份数据（导出本身无风险；写文件位置由系统面板交给用户选择）。
    func prepareBackupExport() async {
        do {
            pendingBackupExport = try await service.exportBackup()
        } catch {
            alertMessage = ErrorText.describe(error)
        }
    }

    func clearBackupExport() {
        pendingBackupExport = nil
    }

    /// 读取所选备份文件并生成冲突预览（解析阶段绝不写库）。
    func beginBackupImport(at url: URL) async {
        generation += 1
        let currentGeneration = generation
        do {
            let data = try await Self.readData(url)
            guard currentGeneration == generation else { return }
            let parsed = try service.parseBackup(data)
            guard currentGeneration == generation else { return }
            let preview = try await service.backupConflictPreview(for: parsed)
            guard currentGeneration == generation else { return }
            if preview.isEmpty {
                backupStage = .completed("备份与当前库内容一致，没有需要导入的变更。")
            } else {
                backupStage = .preview(parsed, preview)
            }
        } catch {
            guard currentGeneration == generation else { return }
            alertMessage = "无法导入备份：\(ErrorText.describe(error))"
        }
    }

    /// 取消导入：解析/预览阶段从未写库，直接回 idle。
    func cancelBackupImport() {
        generation += 1
        backupStage = .idle
    }

    /// 确认导入（唯一写库提交点；单事务）。
    func confirmBackupImport() async {
        generation += 1
        let currentGeneration = generation
        guard case let .preview(parsed, _) = backupStage else { return }
        backupStage = .importing
        do {
            try await service.importBackup(parsed)
            guard currentGeneration == generation else { return }
            backupStage = .completed("备份导入完成：文档、绑定与可移植设置已恢复到本机歌词库。")
            await refresh()
            onLibraryChanged?()
        } catch {
            guard currentGeneration == generation else { return }
            backupStage = .idle
            alertMessage = "导入备份失败（原数据不受影响）：\(ErrorText.describe(error))"
        }
    }

    // MARK: - 展示辅助

    static func displayName(for item: LyricsLibraryOverviewItem) -> String {
        item.titleHint ?? item.originalFilename ?? "未命名歌词"
    }

    private static func readData(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try Data(contentsOf: url)
        }.value
    }
}
