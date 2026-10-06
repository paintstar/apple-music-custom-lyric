import Foundation
import ShinAppleKit
import ShinAppleData

// 导入会话状态机。
//
// 生命周期：idle → open（openImportSession，目标固定）→ completed（confirm 成功）；
// 任意时刻可 cancel 回到 idle，且 cancel 不产生任何数据库副作用。
//
// 关键保证：
// - 目标歌曲身份与提示信息在 openImportSession 时固定，本服务从不读取
//   播放状态，切歌不可能改变确认目标；
// - 确认前绝不写库：预览（ingest）只产出内存文档；confirm 唯一提交点，
//   经 store.save 的单事务原子写入（重导入 = 绑定替换、旧文档保留）；
// - 解析失败 / schema 拒绝后会话保持 open，用户可直接重选文件；
// - confirm 二次调用抛 alreadyConfirmed，防重复提交；
// - 解析在本 actor 执行（不占调用方主线程），UI 不冻结。

/// 歌词导入会话服务。actor 串行化内部状态，全部方法可安全并发调用。
public actor ImportWorkflowService {

    /// 会话阶段。
    public enum Phase: Equatable, Sendable {
        case idle
        case open
        case completed
    }

    /// 一次成功 ingest 的完整内存结果：文档 + 解析诊断。
    private struct IngestedFile: Sendable {
        let document: LyricDocument
        let diagnostics: [LyricDiagnostic]
    }

    private let store: GRDBLyricsStore
    private var phase: Phase = .idle
    private var target: ImportSessionTarget?
    private var ingested: IngestedFile?
    /// 在线获取来源注记：打开会话时固定，确认时写入文档
    /// metadata；nil = 手动导入（不产生任何注记，享有手动优先保护）。
    private var provenance: FetchProvenance?

    // 双语导入状态。ingested 永远保存「原始解析产物」；
    // 双语映射结果单独缓存，确认时按 mode 组合，重复应用不累积。
    private var bilingualMode: BilingualMode = .off
    /// 最近一次提交的双语映射结果；mode == .off 时为 nil。
    private var bilingualOutcome: BilingualMappingOutcome?
    /// 双语重算代序号：重新 ingest 或再次切换模式使旧重算结果失效。
    private var bilingualGeneration = 0
    /// 测试专用：重算提交前的挂起点（生产路径为 nil），供并发时序测试注入。
    private var bilingualRecomputePause: (@Sendable (BilingualMode) async -> Void)?

    public init(store: GRDBLyricsStore) {
        self.store = store
    }

    // MARK: - 会话状态（只读查询）

    /// 当前会话阶段。
    public var currentPhase: Phase { phase }

    /// 打开会话时固定的目标；无会话为 nil。
    /// 注意：本服务不订阅播放状态，该值一旦设定就不会改变。
    public func sessionTarget() -> ImportSessionTarget? {
        target
    }

    /// 最近一次成功 ingest 的预览；无则为 nil。包含已提交的双语映射结果（若有）。
    public func currentPreview() -> ImportPreview? {
        guard let file = ingested else { return nil }
        return Self.makePreview(for: file, bilingualOutcome: bilingualOutcome)
    }

    /// 当前生效的双语模式（默认 .off；重新 ingest 后回到 .off）。
    public func activeBilingualMode() -> BilingualMode {
        bilingualMode
    }

    // MARK: - 会话生命周期

    /// 打开导入会话：目标歌曲身份与提示信息就此固定。
    /// - Parameter provenance: 在线获取来源注记（在线获取路径传入；
    ///   手动导入不传，落库文档不产生获取注记）。
    /// 已有进行中的会话（open）时抛 `sessionAlreadyOpen`，调用方应先
    /// `cancel()`；已完成的会话可直接开新会话（覆盖常见「重新导入」路径，
    /// 二次确认保护只针对同一会话，不受影响）。
    public func openImportSession(
        target newTarget: ImportSessionTarget,
        provenance newProvenance: FetchProvenance? = nil
    ) async throws {
        guard phase != .open else {
            throw ImportWorkflowError.sessionAlreadyOpen
        }
        phase = .open
        target = newTarget
        provenance = newProvenance
        ingested = nil
        resetBilingualState()
    }

    /// 本会话固定的来源注记；无会话或手动导入为 nil。
    public func sessionProvenance() -> FetchProvenance? {
        provenance
    }

    /// 读取文件字节 → 解析 → schema 校验 → 生成预览。
    /// - Throws: `ImportWorkflowError`。解析失败/schema 拒绝后，
    ///   会话保持 open（target 不变），已 ingest 的内容被清空，可直接重选文件。
    @discardableResult
    public func ingest(fileData: Data, filename: String?) async throws -> ImportPreview {
        switch phase {
        case .idle:
            throw ImportWorkflowError.noOpenSession
        case .completed:
            throw ImportWorkflowError.sessionCompleted
        case .open:
            break
        }
        // 解析失败：清空旧预览（避免陈旧内容继续显示），会话保持打开。
        let result: LyricParseResult
        do {
            result = try LyricsParser.parse(fileData, filename: filename)
        } catch let error as LyricParseError {
            ingested = nil
            throw ImportWorkflowError.parseFailure(error)
        }
        // 防御性 schema 校验：解析产物理论上有稳定 UUID，不会重复，
        // 但任何入库路径都必须过同一道校验（与 store.save 一致）。
        let issues = LyricSchemaValidator.issues(in: result.document)
        guard issues.isEmpty else {
            ingested = nil
            throw ImportWorkflowError.schemaRejected(issues)
        }
        let file = IngestedFile(document: result.document, diagnostics: result.diagnostics)
        ingested = file
        // 新文件 = 新的原始解析产物：双语模式回到默认 .off，旧映射结果作废。
        resetBilingualState()
        return Self.makePreview(for: file, bilingualOutcome: nil)
    }

    /// 切换双语模式：用最近一次 ingest 的「原始解析产物」重新应用策略
    /// （幂等、非增量；不是在上一轮结果上继续改）。
    ///
    /// 映射为纯函数，在协作线程池后台执行（不占调用方线程）；actor 在 await
    /// 期间可重入，恢复后校验代序号——期间发生的再次切换或重新 ingest 会使
    /// 本结果整体丢弃，慢的旧策略结果绝不覆盖新模式结果（generation 防旧覆盖）。
    /// - Returns: 更新后的预览（含双语统计）；尚无已 ingest 内容时仅记录
    ///   模式并返回 nil（UI 只在预览态开放本入口）。
    @discardableResult
    public func setBilingualMode(_ mode: BilingualMode) async -> ImportPreview? {
        bilingualMode = mode
        bilingualGeneration &+= 1
        let myGeneration = bilingualGeneration
        guard let file = ingested else {
            bilingualOutcome = nil
            return nil
        }
        let original = file.document
        // 纯函数映射放到协作线程池执行（后台重算，UI 不冻结）。
        let outcome = await Task.detached(priority: .userInitiated) {
            BilingualImportMapper.apply(mode: mode, to: original)
        }.value
        // 测试注入的挂起点：映射完成后、提交判定前（生产路径为空操作）。
        if let pause = bilingualRecomputePause {
            await pause(mode)
        }
        guard myGeneration == bilingualGeneration, phase == .open else {
            // 已被更新模式/新文件/会话关闭取代：整体丢弃，不提交。
            return nil
        }
        bilingualOutcome = mode == .off ? nil : outcome
        return Self.makePreview(for: file, bilingualOutcome: bilingualOutcome)
    }

    /// 测试专用：注入重算提交前的挂起点（传 nil 恢复生产路径）。
    public func setBilingualRecomputePauseForTesting(
        _ pause: (@Sendable (BilingualMode) async -> Void)?
    ) {
        bilingualRecomputePause = pause
    }

    /// 目标歌曲当前已有的绑定信息（确认卡「将被替换」区域的数据源）。
    /// 目标固定，因此结果只反映库状态；无绑定时返回 nil。
    public func existingBindingInfo() async throws -> ExistingBindingInfo? {
        guard let fixedTarget = target else {
            throw ImportWorkflowError.noOpenSession
        }
        guard let binding = try await store.binding(forTrackKey: fixedTarget.trackKey) else {
            return nil
        }
        let document = try await store.document(id: binding.lyricDocumentId)
        let others = try await store.bindings(referencing: binding.lyricDocumentId)
            .filter { $0.trackKey != binding.trackKey }
        return ExistingBindingInfo(binding: binding, document: document, otherBindings: others)
    }

    /// 确认导入：唯一写库入口。新文档与（可能替换的）绑定在同一事务提交。
    /// - 重导入 = 绑定替换为新文档、旧文档保留（不删除任何历史文档）；
    /// - 新绑定 userDelayMs 从 0 开始（用户延迟是后续编辑的领域）；
    /// - 二次确认抛 `alreadyConfirmed`；成功后本会话进入 completed。
    public func confirmImport() async throws -> ImportConfirmation {
        guard let confirmation = try await commitImport(onlyIfUnbound: false, isValid: { true }) else {
            throw ImportWorkflowError.storeRejection("无法完成导入")
        }
        return confirmation
    }

    /// 自动路径：已有绑定时返回 nil；有效性检查随保存进入数据库事务。
    public func confirmImportIfUnbound(
        isValid: @escaping @Sendable () -> Bool
    ) async throws -> ImportConfirmation? {
        try await commitImport(onlyIfUnbound: true, isValid: isValid)
    }

    private func commitImport(
        onlyIfUnbound: Bool, isValid: @escaping @Sendable () -> Bool
    ) async throws -> ImportConfirmation? {
        switch phase {
        case .idle:
            throw ImportWorkflowError.noOpenSession
        case .completed:
            throw ImportWorkflowError.alreadyConfirmed
        case .open:
            break
        }
        guard let file = ingested else {
            throw ImportWorkflowError.nothingIngested
        }
        let preview = Self.makePreview(for: file, bilingualOutcome: bilingualOutcome)
        guard preview.isImportable else {
            throw ImportWorkflowError.previewHasErrors
        }
        guard let fixedTarget = target else {
            throw ImportWorkflowError.noOpenSession
        }
        // 双语译文已在映射时挂到文档行上（source = .imported）；确认走同一条
        // 提交路径，文档未启用双语时与原始解析产物相同。
        // 在线获取路径：来源注记随文档一同落库（手动导入不产生注记）。
        let baseDocument = bilingualOutcome?.document ?? file.document
        let effectiveDocument = Self.annotatedDocument(
            provenance: provenance, for: baseDocument
        )
        let binding = try importBinding(target: fixedTarget, document: effectiveDocument)
        do {
            // 替换信息在写入前读取（读取的正是将被本次提交替换的状态）。
            let replacement = try await store.reimportPreview(
                incomingDocument: effectiveDocument,
                binding: binding
            )
            guard try await persistImport(document: effectiveDocument, binding: binding,
                                          onlyIfUnbound: onlyIfUnbound, isValid: isValid)
            else { return nil }
            phase = .completed
            return ImportConfirmation(
                document: effectiveDocument,
                binding: binding,
                replacedBinding: replacement.replacedBinding,
                documentsLosingLastBinding: replacement.documentsLosingLastBinding
            )
        } catch {
            // 保存失败：会话保持 open 且已 ingest 内容不变，用户可重试确认。
            if error is CancellationError { throw error }
            throw ImportWorkflowError.mapStoreError(error)
        }
    }

    private func persistImport(
        document: LyricDocument, binding: SongBinding, onlyIfUnbound: Bool,
        isValid: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard isValid() else { throw CancellationError() }
        if onlyIfUnbound {
            return try await store.saveIfUnbound(document: document, binding: binding, isValid: isValid)
        }
        try await store.save(document: document, binding: binding)
        return true
    }

    private func importBinding(target: ImportSessionTarget, document: LyricDocument) throws -> SongBinding {
        switch SongBinding.trackIdentity(fromTrackKey: target.trackKey) {
        case .scriptPersistentID(let persistentID):
            return SongBinding(
                persistentID: persistentID,
                lyricDocumentId: document.id,
                userDelayMs: 0,
                titleHint: target.titleHint,
                artistHint: target.artistHint,
                durationHintMs: target.durationHintMs
            )
        case .catalog(let track):
            return SongBinding(
                track: track,
                lyricDocumentId: document.id,
                userDelayMs: 0,
                titleHint: target.titleHint,
                artistHint: target.artistHint,
                durationHintMs: target.durationHintMs
            )
        case nil:
            throw ImportWorkflowError.storeRejection(
                "导入目标曲目键非法（无法解析为已知命名空间）：\(target.trackKey)"
            )
        }
    }

    /// 取消会话：只清理内存状态，绝不写库；幂等。
    public func cancel() {
        phase = .idle
        target = nil
        provenance = nil
        ingested = nil
        resetBilingualState()
    }

    // MARK: - 预览构建

    /// 把来源注记写入待保存文档（在线获取路径）；手动导入原样返回。
    /// revisionAtFetch 记录注记时刻的文档 revision，是「落位后是否经人工编辑」
    /// 的判定基准（自动删除管线对照用）。
    private static func annotatedDocument(
        provenance: FetchProvenance?,
        for document: LyricDocument
    ) -> LyricDocument {
        guard let provenance else { return document }
        var annotated = document
        let fields = provenance.metadataFields(
            fetchedAt: LyricTimestamp.now(),
            revisionAtFetch: document.revision
        )
        for (key, values) in fields {
            annotated.metadata[key] = values
        }
        return annotated
    }

    /// 双语状态复位（开新会话 / 重新 ingest / 取消时调用）。
    private func resetBilingualState() {
        bilingualMode = .off
        bilingualOutcome = nil
        bilingualGeneration &+= 1
        bilingualRecomputePause = nil
    }

    /// 由 ingest 结果构建预览模型（统计、元信息、offset、诊断直传；
    /// 双语映射结果存在时附双语统计与对照区数据）。
    private static func makePreview(
        for file: IngestedFile,
        bilingualOutcome: BilingualMappingOutcome?
    ) -> ImportPreview {
        let document = file.document
        let timed = document.lines.filter { $0.startMs != nil }.count
        let bilingual = bilingualOutcome.map { outcome in
            BilingualPreviewInfo(
                mode: outcome.mode,
                originalLineCount: outcome.originalLineCount,
                translatedLineCount: outcome.translatedLineCount,
                warnings: outcome.warnings,
                pairRows: outcome.pairRows
            )
        }
        return ImportPreview(
            documentId: document.id,
            filename: document.originalFilename,
            sourceFormat: document.sourceFormat,
            diagnostics: file.diagnostics,
            totalLineCount: document.lines.count,
            timedLineCount: timed,
            untimedLineCount: document.lines.count - timed,
            metadata: document.metadata,
            sourceOffsetMs: document.sourceOffsetMs,
            pairedTimestampsAvailable: BilingualImportMapper.hasPairableGroups(document),
            bilingual: bilingual
        )
    }
}
