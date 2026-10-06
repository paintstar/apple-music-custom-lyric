import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 导入流程状态机：包裹应用服务层的 ImportWorkflowService。
// - 文件读取与解析都在后台执行（服务为 actor；读文件用 detached Task），
//   主线程只做状态提交，界面不冻结；
// - 用代序号（generation）丢弃被取消/被取代的操作结果；
// - 双语模式：默认 .off；切换模式后用已 ingest 的原始解析产物
//   在后台重算（同样以 generation 防旧结果覆盖新模式结果）；
// - 解析失败回到「选择文件」状态并给出可恢复的中文错误；
// - 保存失败退回预览状态允许重试，绝不假报成功。
// - 粘贴导入：文本直接以 UTF-8 编码进入同一条
//   ingest → 预览 → 确认 链路（filename 传 nil）；String 的 UTF-8 编码
//   必然通过解析层的严格解码，无编码探测歧义。

@MainActor
final class ImportFlowModel: ObservableObject {

    enum Phase: Equatable {
        /// 会话已打开（或打开中失败），等待选择文件。
        case idle
        /// 正在读取/解析文件。
        case loadingPreview
        /// 预览就绪（含「将被替换」的现有绑定信息）。
        case ready(ImportPreview, existing: ExistingBindingInfo?)
        /// 正在保存。
        case saving
        /// 保存成功。
        case succeeded(ImportConfirmation)
    }

    @Published private(set) var phase: Phase = .idle
    /// 打开会话时固定的导入目标（不随后续播放变化）。
    @Published private(set) var target: ImportSessionTarget?
    /// 目标当前已有的绑定（提示性信息；查询失败不阻塞导入）。
    @Published private(set) var existingForTarget: ExistingBindingInfo?
    /// 双语导入模式（默认 .off：与单语导入行为完全一致）。
    @Published private(set) var bilingualMode: BilingualMode = .off
    /// 双语预览重算进行中（重算在后台执行，界面不冻结）。
    @Published private(set) var isRecomputingBilingual = false
    /// 可恢复错误说明（中文）；nil 表示无错误。
    @Published var alertMessage: String?
    /// 粘贴输入的歌词文本（idle 阶段文本框绑定）。「重新输入」保留内容便于修改重试；
    /// 成功/取消后随会话清理。
    @Published var pastedText = ""
    /// 确认成功后的回调（宿主用于刷新歌词面板）。
    var onDidConfirm: (() -> Void)?

    private let service: ImportWorkflowService
    /// 代序号：取消/重开/新操作使旧异步结果失效。
    private var generation = 0
    /// 最近一次就绪的预览（保存失败退回时复用）。
    private var lastReady: (preview: ImportPreview, existing: ExistingBindingInfo?)?
    /// 「包含译文」关掉前最后使用的非 off 模式（再次打开时恢复）。
    private var lastActiveBilingualMode: BilingualMode = .pairedTimestamps

    init(store: GRDBLyricsStore) {
        service = ImportWorkflowService(store: store)
    }

    /// 是否处于「包含译文」开启状态。
    var translationIncluded: Bool { bilingualMode != .off }

    /// 当前文件是否可用「同时间戳成对」模式（仅 LRC 且存在行组）。
    var pairedModeAvailable: Bool {
        if case let .ready(preview, _) = phase {
            return preview.pairedTimestampsAvailable
        }
        return false
    }

    // MARK: - 会话

    /// 打开导入会话：目标就此固定。导入过程中切歌不会改变该目标。
    /// - Parameter provenance: 在线获取路径传入来源注记（随确认写库）；
    ///   手动导入不传（文档不产生获取注记）。
    func openSession(
        target newTarget: ImportSessionTarget,
        provenance: FetchProvenance? = nil
    ) async {
        generation += 1
        target = newTarget
        phase = .idle
        alertMessage = nil
        existingForTarget = nil
        lastReady = nil
        pastedText = ""
        resetBilingualUIState()
        do {
            try await service.openImportSession(target: newTarget, provenance: provenance)
            // 目标已固定，此处查询结果只反映库中现状（提示卡数据源）。
            existingForTarget = try? await service.existingBindingInfo()
        } catch {
            alertMessage = ErrorText.describe(error)
        }
    }

    /// 在线获取的歌词文本进入既有 ingest → 预览 → 确认链路（与粘贴导入同一
    /// 语义，文本来自获取管线；filename 记 nil）。存在同时间戳行组时自动
    /// 启用「成对」双语模式（原文/译文相邻行对），用户仍可在预览里切换或关闭。
    func ingestFetchedText(_ text: String) async {
        generation += 1
        let currentGeneration = generation
        phase = .loadingPreview
        alertMessage = nil
        resetBilingualUIState()
        do {
            let preview = try await service.ingest(fileData: Data(text.utf8), filename: nil)
            guard currentGeneration == generation else { return }
            let existing = try? await service.existingBindingInfo()
            guard currentGeneration == generation else { return }
            lastReady = (preview, existing)
            phase = .ready(preview, existing: existing)
            // 有成对行组时自动开启双语预览（后台重算，generation 防旧覆盖）。
            if preview.pairedTimestampsAvailable {
                await setBilingualMode(.pairedTimestamps)
            }
        } catch {
            guard currentGeneration == generation else { return }
            phase = .idle
            alertMessage = ErrorText.describe(error)
        }
    }

    /// 读取所选文件并解析（重试同一会话内的下一个文件同样走这里）。
    func ingestFile(at url: URL) async {
        generation += 1
        let currentGeneration = generation
        phase = .loadingPreview
        alertMessage = nil
        resetBilingualUIState()
        do {
            // 沙盒下 fileImporter 授予的安全作用域只在本次读取内使用。
            let data = try await Self.readData(url)
            guard currentGeneration == generation else { return }
            let preview = try await service.ingest(fileData: data, filename: url.lastPathComponent)
            guard currentGeneration == generation else { return }
            // 确认页再次核实「将被替换」的现状（ingest 失败后重选文件同样有效）。
            let existing = try? await service.existingBindingInfo()
            guard currentGeneration == generation else { return }
            lastReady = (preview, existing)
            phase = .ready(preview, existing: existing)
        } catch {
            guard currentGeneration == generation else { return }
            // 解析/读取失败：回到选择文件状态，用户可直接重选（会话保持打开）。
            phase = .idle
            alertMessage = ErrorText.describe(error)
        }
    }

    /// 解析粘贴的歌词文本（与文件路径共用 ingest → 预览 → 确认 链路）。
    /// 空白文本不进入解析，直接提示；文本以 UTF-8 编码送入服务层。
    func ingestPastedText() async {
        let text = pastedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "粘贴内容为空：请先粘贴歌词文本（LRC 或纯文本）。"
            return
        }
        generation += 1
        let currentGeneration = generation
        phase = .loadingPreview
        alertMessage = nil
        resetBilingualUIState()
        do {
            let preview = try await service.ingest(fileData: Data(text.utf8), filename: nil)
            guard currentGeneration == generation else { return }
            let existing = try? await service.existingBindingInfo()
            guard currentGeneration == generation else { return }
            lastReady = (preview, existing)
            phase = .ready(preview, existing: existing)
        } catch {
            guard currentGeneration == generation else { return }
            // 解析失败：回到输入状态，已粘贴文本保留，用户可修改后重试。
            phase = .idle
            alertMessage = ErrorText.describe(error)
        }
    }

    /// 预览页「重新输入」：回到输入状态（会话保持打开，已粘贴文本保留）。
    func resetToIdle() {
        generation += 1
        phase = .idle
        alertMessage = nil
        lastReady = nil
        resetBilingualUIState()
    }

    /// 确认导入（唯一写库提交点）。成功后本会话结束。
    func confirm() async {
        generation += 1
        let currentGeneration = generation
        phase = .saving
        alertMessage = nil
        do {
            let confirmation = try await service.confirmImport()
            guard currentGeneration == generation else { return }
            phase = .succeeded(confirmation)
            onDidConfirm?()
        } catch {
            guard currentGeneration == generation else { return }
            alertMessage = ErrorText.describe(error)
            // 退回预览（若仍在）允许重试；二次确认等错误同样可读可恢复。
            if let ready = lastReady {
                phase = .ready(ready.preview, existing: ready.existing)
            } else {
                phase = .idle
            }
        }
    }

    /// 取消导入：服务层不写库；关闭面板即可。
    func cancel() async {
        generation += 1
        await service.cancel()
        target = nil
        existingForTarget = nil
        lastReady = nil
        phase = .idle
        alertMessage = nil
        pastedText = ""
        resetBilingualUIState()
    }

    /// 成功页点击「完成」：清理本地展示状态（库数据已提交）。
    func finish() {
        generation += 1
        target = nil
        existingForTarget = nil
        lastReady = nil
        phase = .idle
        alertMessage = nil
        pastedText = ""
        resetBilingualUIState()
    }

    // MARK: - 双语模式

    /// 切换「包含译文」开关。开启时恢复上次的非 off 模式；该模式在当前
    /// 文件不可用（如成对模式遇纯文本）则回退为分隔符模式（//）。
    func setTranslationIncluded(_ included: Bool) async {
        guard included else {
            await setBilingualMode(.off)
            return
        }
        switch lastActiveBilingualMode {
        case .inlineSeparator(let separator):
            await setBilingualMode(.inlineSeparator(separator))
        case .pairedTimestamps:
            await setBilingualMode(pairedModeAvailable ? .pairedTimestamps : .inlineSeparator(.doubleSlash))
        case .off:
            await setBilingualMode(.off)
        }
    }

    /// 切换为「同时间戳成对」模式（仅当当前文件存在行组时由 UI 提供）。
    func selectPairedMode() async {
        guard pairedModeAvailable else { return }
        await setBilingualMode(.pairedTimestamps)
    }

    /// 切换为「同行分隔符」模式并指定分隔符。
    func selectInlineMode(separator: InlineSeparator) async {
        await setBilingualMode(.inlineSeparator(separator))
    }

    /// 应用双语模式：用已 ingest 的原始解析产物在后台重算（服务 actor +
    /// 协作线程池，主线程只做状态提交），沿用 generation 代数防旧覆盖。
    func setBilingualMode(_ mode: BilingualMode) async {
        // 重复点击同一选项：无新意图，不打断进行中的重算。
        let unchanged = bilingualMode == mode && !isRecomputingBilingual
        bilingualMode = mode
        if mode != .off {
            lastActiveBilingualMode = mode
        }
        guard !unchanged else { return }
        guard case .ready = phase else { return }
        generation += 1
        let currentGeneration = generation
        isRecomputingBilingual = true
        let preview = await service.setBilingualMode(mode)
        guard currentGeneration == generation else { return }
        isRecomputingBilingual = false
        guard let preview else { return }
        let existing = lastReady?.existing
        lastReady = (preview, existing)
        phase = .ready(preview, existing: existing)
    }

    /// 双语 UI 状态复位（开关回默认 off；进行中的重算结果由代序号丢弃）。
    private func resetBilingualUIState() {
        bilingualMode = .off
        isRecomputingBilingual = false
    }

    // MARK: - 文件读取（后台）

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
