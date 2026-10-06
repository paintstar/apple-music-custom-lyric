import Foundation
import ShinAppleKit
import ShinAppleData

// MARK: - 歌词编辑服务

/// 歌词编辑会话：草稿式编辑 + 撤销/重做 + 显式保存。
///
/// 关键保证（均有对应单元测试）：
/// - **草稿隔离**：openEditor 对库内文档做值拷贝（LyricDocument 及其行、
///   译文均为值类型，拷贝即深拷贝）；所有编辑只发生在草稿上，提交前
///   store 一个字节不变；discard() 后库内文档与打开时逐字节一致。
/// - **行身份**：一切行操作按稳定 `line.id` 定位，绝不用数组下标；
///   排序/移动/改时间不会让译文错配（译文挂在行上随 id 走）。
/// - **原文改动 → 待复核**：setLineText 实际改变文本时，该行已有译文
///   全部标 needsReview = true；无译文的行保持空对象不受影响。
/// - **撤销/重做**：草稿内栈；不改变已提交版本；commit 后历史重置；
///   撤销可一路回到打开时状态（此时 hasUnsavedChanges 回到 false）。
///   同一行的连续文本/译文/时间按键合并为一条撤销记录（lastCoalesceKey）。
/// - **revision 乐观并发**：commit 经 store.save 提交 baseRevision + 1；
///   库中已被并发更新时抛类型化冲突，草稿与历史保留，绝不静默覆盖。
/// - **关闭守卫**：phase == .open 且有未保存修改时 shouldConfirmClose == true，
///   App 层据此弹「放弃修改？」确认。
///
/// 线程模型：actor 串行化内部状态；快照为 Sendable 值类型。
/// 有绑定时提交经 store.save(document:binding:) 原子写入，绑定行取
/// 当前指向本文档的绑定原样写回（内容不变）；读取绑定与写入之间存在理论上
/// 的竞争窗口（绑定字段可能被回写为读取时的值），文档内容的并发保护由
/// store 的 revision 检查原子完成。无绑定文档经 store.updateDocument 保存；
/// 同一文档的并发编辑由 revision 冲突检测保护。
public actor LyricsEditingService {

    /// 会话阶段。
    public enum Phase: Equatable, Sendable {
        case idle
        case open
    }

    /// 撤销栈容量上限（整文档快照，防止长时间编辑内存无界增长）。
    static let maxUndoEntries = 100

    private let store: GRDBLyricsStore
    private var phase: Phase = .idle
    /// 基线：打开时（或上次成功保存后）的文档快照。
    private var baseDocument: LyricDocument?
    /// 工作草稿：所有编辑只发生在这里。
    private var workingDocument: LyricDocument?
    private var undoStack: [LyricDocument] = []
    private var redoStack: [LyricDocument] = []
    /// 连续同类编辑的合并键（如 "text:<lineId>"）；nil 表示不合并。
    private var lastCoalesceKey: String?

    public init(store: GRDBLyricsStore) {
        self.store = store
    }

    // MARK: - 会话状态

    /// 当前会话阶段。
    public var currentPhase: Phase { phase }

    /// 是否存在未保存修改（未打开会话时为 false）。
    public var hasUnsavedChanges: Bool {
        guard phase == .open, let base = baseDocument, let working = workingDocument else {
            return false
        }
        return working != base
    }

    /// 关闭守卫：编辑器打开且有未保存修改时为 true（App 层据此弹确认）。
    public var shouldConfirmClose: Bool {
        phase == .open && hasUnsavedChanges
    }

    /// 当前草稿快照；未打开会话返回 nil。
    public func currentSnapshot() -> LyricsEditingSnapshot? {
        guard phase == .open else { return nil }
        return makeSnapshot()
    }

    // MARK: - 会话生命周期

    /// 打开编辑器：读取库内文档并生成草稿（深拷贝）。
    /// 已有打开的会话时抛 `editorAlreadyOpen`（先关闭再开）。
    public func openEditor(documentId: UUID) async throws -> LyricsEditingSnapshot {
        guard phase != .open else {
            throw LyricsEditingError.editorAlreadyOpen
        }
        let document: LyricDocument
        do {
            guard let loaded = try await store.document(id: documentId) else {
                throw LyricsEditingError.documentNotFound(documentId)
            }
            document = loaded
        } catch {
            throw LyricsEditingError.mapStoreError(error)
        }
        phase = .open
        baseDocument = document
        workingDocument = document
        undoStack = []
        redoStack = []
        lastCoalesceKey = nil
        return makeSnapshot()
    }

    /// 放弃全部未保存修改：草稿回到打开时（或上次保存后）的状态，
    /// 历史清空。不触碰存储。未打开会话时为幂等 no-op。
    public func discard() {
        guard phase == .open else { return }
        workingDocument = baseDocument
        undoStack = []
        redoStack = []
        lastCoalesceKey = nil
    }

    /// 关闭编辑器（隐含放弃未保存修改——调用方必须先检查 shouldConfirmClose）。
    /// 幂等。
    public func closeEditor() {
        discard()
        phase = .idle
        baseDocument = nil
        workingDocument = nil
    }

    // MARK: - 行编辑（全部按 line.id 定位）

    /// 修改行原文。文本实际变化时：该行已有译文全部标 needsReview = true
    /// （原无译文则保持空对象）；文本相同则整体 no-op。
    @discardableResult
    public func setLineText(lineId: UUID, text: String) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: "text:\(lineId.uuidString)") { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            guard document.lines[index].text != text else { return }
            document.lines[index].text = text
            // 原文变化：该行已有译文全部标待复核（键快照后再改值，避免边遍历边写）。
            let translationKeys = Array(document.lines[index].translations.keys)
            for key in translationKeys {
                document.lines[index].translations[key]?.needsReview = true
            }
        }
    }

    /// 修改行的译文（language 为 BCP-47，如 "zh-Hans"）。
    /// - 空文本 → 删除该语言译文（无译文时合理降级）；
    /// - 非空 → 以 manual 来源写入并清除 needsReview（人工改写即视为已复核）；
    /// - 文本与现值相同 → no-op。
    @discardableResult
    public func setTranslation(
        lineId: UUID,
        language: String,
        text: String
    ) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: "translation:\(lineId.uuidString):\(language)") { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            if text.isEmpty {
                document.lines[index].translations[language] = nil
            } else {
                document.lines[index].translations[language] = Translation(
                    text: text, source: .manual, needsReview: false
                )
            }
        }
    }

    /// 修改行起始时间。输入规则见 `LyricTimeInputParser`：
    /// 空白 = 未打轴（startMs = nil）；非法输入抛定位到该行的类型化错误，
    /// 绝不静默归零；解析结果与现值相同则 no-op。
    @discardableResult
    public func setLineTime(
        lineId: UUID,
        rawTimeString: String
    ) async throws -> LyricsEditingSnapshot {
        let parsedMs: Int64?
        switch LyricTimeInputParser.parse(rawTimeString) {
        case .success(let ms):
            parsedMs = ms
        case .failure(let reason):
            throw LyricsEditingError.invalidTimeInput(
                lineId: lineId, rawInput: rawTimeString, reason: reason
            )
        }
        return try await mutate(coalesceKey: "time:\(lineId.uuidString)") { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            document.lines[index].startMs = parsedMs
        }
    }

    /// 新增一行：`after` 为 nil 时追加到末尾，否则插到指定行之后。
    /// 新行获得全新稳定 id，无译文；startMs 为 nil 表示未打轴。
    @discardableResult
    public func addLine(
        after lineId: UUID?,
        text: String,
        startMs: Int64? = nil
    ) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: nil) { document in
            guard document.lines.count < LyricsEditingError.lineLimit else {
                throw LyricsEditingError.lineLimitReached(limit: LyricsEditingError.lineLimit)
            }
            let newLine = LyricLine(startMs: startMs, text: text)
            if let anchor = lineId {
                guard let index = Self.lineIndex(of: anchor, in: document) else {
                    throw LyricsEditingError.lineNotFound(lineId: anchor)
                }
                document.lines.insert(newLine, at: document.lines.index(after: index))
            } else {
                document.lines.append(newLine)
            }
        }
    }

    /// 删除一行。译文挂在行上，随行一起删除。
    @discardableResult
    public func deleteLine(lineId: UUID) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: nil) { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            document.lines.remove(at: index)
        }
    }

    /// 上移/下移一行。只在数组顺序上交换位置：行 id 与译文都随行走，
    /// 排序/移动绝不改变翻译归属。已在边界时为 no-op（无历史记录）。
    @discardableResult
    public func moveLine(
        lineId: UUID,
        direction: LyricsEditingMoveDirection
    ) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: nil) { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            let target = direction == .up ? index - 1 : index + 1
            guard document.lines.indices.contains(target) else { return }
            document.lines.swapAt(index, target)
        }
    }

    // MARK: - 撤销 / 重做

    /// 撤销：回到上一条历史状态（可一路回到打开时状态）。栈空时 no-op。
    /// 只影响草稿，绝不改变已提交版本。
    @discardableResult
    public func undo() throws -> LyricsEditingSnapshot {
        guard phase == .open, let current = workingDocument else {
            throw LyricsEditingError.noOpenEditor
        }
        guard let previous = undoStack.popLast() else {
            return makeSnapshot()
        }
        redoStack.append(current)
        workingDocument = previous
        lastCoalesceKey = nil
        return makeSnapshot()
    }

    /// 重做：恢复被撤销的状态。栈空时 no-op。
    @discardableResult
    public func redo() throws -> LyricsEditingSnapshot {
        guard phase == .open, let current = workingDocument else {
            throw LyricsEditingError.noOpenEditor
        }
        guard let next = redoStack.popLast() else {
            return makeSnapshot()
        }
        undoStack.append(current)
        workingDocument = next
        lastCoalesceKey = nil
        return makeSnapshot()
    }

    // MARK: - 保存

    /// 显式保存：提交 baseRevision + 1。
    /// - 无未保存修改时不写库、不升 revision（幂等成功）；
    /// - revision 冲突（库中已被并发更新）抛类型化错误，草稿与历史保留；
    /// - 有绑定时经 store.save 原子写入文档与绑定（绑定行原样写回，内容不变）；
    ///   无绑定时经 store.updateDocument 文档级通道保存，
    ///   供歌词库管理与导出流程使用；
    /// - 成功后基线更新为新版本，撤销/重做历史重置（已提交版本不可被
    ///   撤销改变）。
    @discardableResult
    public func commitChanges() async throws -> LyricsEditingSnapshot {
        guard phase == .open, let base = baseDocument, let working = workingDocument else {
            throw LyricsEditingError.noOpenEditor
        }
        guard working != base else { return makeSnapshot() }
        var submit = working
        submit.revision = base.revision + 1
        submit.updatedAt = LyricTimestamp.now()
        do {
            let bindings = try await store.bindings(referencing: base.id)
            if let anchor = bindings.first {
                try await store.save(document: submit, binding: anchor)
            } else {
                try await store.updateDocument(submit)
            }
        } catch {
            // 冲突/失败：草稿与历史原样保留，用户可重试或放弃。
            throw LyricsEditingError.mapStoreError(error)
        }
        baseDocument = submit
        workingDocument = submit
        undoStack = []
        redoStack = []
        lastCoalesceKey = nil
        return makeSnapshot()
    }

    /// 当前指向本编辑会话文档的全部绑定（共享提示：数量 > 1 表示该歌词
    /// 还被其他歌曲引用，保存后它们都会使用新版本）。
    public func bindingsSharingCurrentDocument() async throws -> [SongBinding] {
        guard let base = baseDocument, phase == .open else {
            throw LyricsEditingError.noOpenEditor
        }
        do {
            return try await store.bindings(referencing: base.id)
        } catch {
            throw LyricsEditingError.mapStoreError(error)
        }
    }

    // MARK: - 内部

    /// 行查找唯一入口：按稳定 id，绝不用数组下标当身份。
    private static func lineIndex(
        of lineId: UUID, in document: LyricDocument
    ) -> Array<LyricLine>.Index? {
        document.lines.firstIndex { $0.id == lineId }
    }

    /// 统一的变更入口：拷贝草稿 → 变换 → 无变化则 no-op（不产生历史），
    /// 否则按合并键压栈/合并、清空重做分支、更新工作副本。
    private func mutate(
        coalesceKey: String?,
        _ transform: (inout LyricDocument) throws -> Void
    ) async throws -> LyricsEditingSnapshot {
        guard phase == .open, let current = workingDocument else {
            throw LyricsEditingError.noOpenEditor
        }
        var updated = current
        try transform(&updated)
        guard updated != current else { return makeSnapshot() }
        let coalesced = coalesceKey != nil
            && coalesceKey == lastCoalesceKey
            && !undoStack.isEmpty
        if !coalesced {
            undoStack.append(current)
            if undoStack.count > Self.maxUndoEntries {
                undoStack.removeFirst()
            }
        }
        lastCoalesceKey = coalesceKey
        redoStack = []
        workingDocument = updated
        return makeSnapshot()
    }

    private func makeSnapshot() -> LyricsEditingSnapshot {
        guard let base = baseDocument, let working = workingDocument else {
            preconditionFailure("快照只在会话打开时生成")
        }
        return LyricsEditingSnapshot(
            documentId: base.id,
            baseRevision: base.revision,
            lines: working.lines,
            canUndo: !undoStack.isEmpty,
            canRedo: !redoStack.isEmpty,
            hasUnsavedChanges: working != base
        )
    }
}
