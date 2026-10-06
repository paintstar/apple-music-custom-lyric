import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 歌词编辑器状态机：包裹应用服务层的 LyricsEditingService。
// - 所有编辑只发生在服务层草稿上；本模型只做快照投递与行内错误定位；
// - 时间输入框的原始文本按行 id 暂存（timeInputs）：解析成功即推送服务层，
//   解析失败只在该行内联显示错误，不触碰草稿（不静默归零）；
// - 保存成功后经 onDidCommit 通知宿主刷新歌词面板，译文/待复核即时生效；
// - shouldConfirmClose 透传服务层守卫：有未保存修改时 App 层弹「放弃修改？」。

@MainActor
final class LyricsEditorModel: ObservableObject {

    enum Phase: Equatable {
        case closed
        case loading
        case editing
    }

    /// 译文输入使用的语言（v1 固定简体中文）。
    static let translationLanguage = "zh-Hans"

    @Published private(set) var phase: Phase = .closed
    @Published private(set) var snapshot: LyricsEditingSnapshot?
    /// 指向本文档的绑定数量（> 1 时 UI 提示「保存会影响所有相关歌曲」）。
    @Published private(set) var sharedBindingCount = 0
    @Published private(set) var isSaving = false
    /// 顶层错误/提示（中文）；nil 表示无。
    @Published var alertMessage: String?
    /// 行内联错误（key = line.id）：时间非法等定位到行的消息。
    @Published var lineMessages: [UUID: String] = [:]
    /// 时间输入框的原始文本（key = line.id）；正在编辑的行保留用户原文。
    @Published private(set) var timeInputs: [UUID: String] = [:]

    /// 保存成功后的回调（宿主用于刷新歌词面板）。
    var onDidCommit: (() -> Void)?

    private let service: LyricsEditingService
    /// 最近一次打开的文档 id（冲突后「重新载入」复用）。
    private var lastOpenedDocumentId: UUID?

    init(store: GRDBLyricsStore) {
        service = LyricsEditingService(store: store)
    }

    // MARK: - 只读视图状态

    var isEditing: Bool { phase == .editing }
    var documentId: UUID? { snapshot?.documentId }
    var lineCount: Int { snapshot?.lines.count ?? 0 }
    var canUndo: Bool { snapshot?.canUndo ?? false }
    var canRedo: Bool { snapshot?.canRedo ?? false }
    var hasUnsavedChanges: Bool { snapshot?.hasUnsavedChanges ?? false }

    /// 关闭守卫：编辑器打开且有未保存修改（透传服务层，App 层据此弹确认）。
    var shouldConfirmClose: Bool {
        isEditing && hasUnsavedChanges
    }

    /// 保存影响面提示（该歌词被多首歌曲共享时）。
    var sharedNotice: String? {
        guard sharedBindingCount > 1 else { return nil }
        return "这份歌词还被另外 \(sharedBindingCount - 1) 首歌曲共享；保存后所有相关歌曲都会使用新版本。"
    }

    // MARK: - 打开 / 关闭 / 放弃

    /// 打开编辑器（读取库内文档生成草稿）。
    func open(documentId: UUID) async {
        phase = .loading
        alertMessage = nil
        lineMessages = [:]
        lastOpenedDocumentId = documentId
        do {
            let opened = try await service.openEditor(documentId: documentId)
            snapshot = opened
            timeInputs = Self.initialTimeInputs(for: opened)
            phase = .editing
            await refreshSharedBindingCount()
        } catch {
            snapshot = nil
            phase = .closed
            alertMessage = "无法打开歌词编辑器：\(ErrorText.describe(error))"
        }
    }

    /// 结束编辑会话（放弃未保存修改——调用方必须已通过确认或无修改）。
    /// 幂等。
    func close() async {
        await service.closeEditor()
        snapshot = nil
        timeInputs = [:]
        lineMessages = [:]
        phase = .closed
    }

    /// 放弃未保存修改（不关闭编辑器）：回到打开时（或上次保存后）的状态。
    func discardEdits() async {
        await service.discard()
        guard let restored = await service.currentSnapshot() else { return }
        snapshot = restored
        timeInputs = Self.initialTimeInputs(for: restored)
        lineMessages = [:]
        alertMessage = nil
    }

    /// 冲突等场景下的「载入库中最新版本」：关闭会话后按原文档重新打开
    /// （本地未保存修改被放弃）。
    func reloadFromStore() async {
        guard let documentId = lastOpenedDocumentId else { return }
        await close()
        await open(documentId: documentId)
    }

    // MARK: - 行编辑（全部按 line.id）

    func setLineText(lineId: UUID, to text: String) {
        Task {
            await perform(preserveTimeInputOf: lineId) {
                try await self.service.setLineText(lineId: lineId, text: text)
            }
        }
    }

    func setTranslation(lineId: UUID, to text: String) {
        Task {
            await perform(preserveTimeInputOf: lineId) {
                try await self.service.setTranslation(
                    lineId: lineId, language: Self.translationLanguage, text: text
                )
            }
        }
    }

    /// 时间输入框变化：先本地解析；失败只标行内错误（草稿不动），成功才推送。
    func updateTimeRaw(lineId: UUID, raw: String) {
        timeInputs[lineId] = raw
        switch LyricTimeInputParser.parse(raw) {
        case .success:
            lineMessages[lineId] = nil
            Task {
                await perform(preserveTimeInputOf: lineId) {
                    try await self.service.setLineTime(lineId: lineId, rawTimeString: raw)
                }
            }
        case .failure(let failure):
            lineMessages[lineId] = "时间「\(raw)」无法识别：\(Self.failureHint(failure))"
        }
    }

    func addLine(after lineId: UUID?) {
        Task {
            await perform {
                try await self.service.addLine(after: lineId, text: "", startMs: nil)
            }
        }
    }

    func deleteLine(lineId: UUID) {
        Task {
            await perform {
                try await self.service.deleteLine(lineId: lineId)
            }
        }
    }

    func moveLine(lineId: UUID, direction: LyricsEditingMoveDirection) {
        Task {
            await perform {
                try await self.service.moveLine(lineId: lineId, direction: direction)
            }
        }
    }

    func undo() {
        Task {
            await perform {
                try await self.service.undo()
            }
        }
    }

    func redo() {
        Task {
            await perform {
                try await self.service.redo()
            }
        }
    }

    // MARK: - 保存

    /// 显式保存（唯一写库提交点）。成功后通知宿主刷新面板。
    func save() async {
        guard isEditing, !isSaving else { return }
        isSaving = true
        alertMessage = nil
        defer { isSaving = false }
        do {
            let committed = try await service.commitChanges()
            snapshot = committed
            timeInputs = Self.initialTimeInputs(for: committed)
            lineMessages = [:]
            await refreshSharedBindingCount()
            onDidCommit?()
        } catch {
            // 冲突/失败：草稿保留；冲突提示用户可重新载入或重试。
            alertMessage = ErrorText.describe(error)
        }
    }

    // MARK: - 行内联字段读取（供视图绑定）

    func text(of lineId: UUID) -> String {
        snapshot?.lines.first { $0.id == lineId }?.text ?? ""
    }

    func translation(of lineId: UUID) -> String {
        snapshot?.lines.first { $0.id == lineId }?
            .translations[Self.translationLanguage]?.text ?? ""
    }

    // MARK: - 内部

    /// 统一执行入口：成功则更新快照；失败转中文提示。
    /// preserveTimeInputOf：该行时间输入框保留用户正在输入的原文，
    /// 其余行按快照重算显示文本（撤销/重做/提交后时间框同步）。
    private func perform(
        preserveTimeInputOf preserved: UUID? = nil,
        _ operation: () async throws -> LyricsEditingSnapshot
    ) async {
        do {
            let snapshot = try await operation()
            apply(snapshot, preservingTimeInputOf: preserved)
        } catch {
            alertMessage = ErrorText.describe(error)
        }
    }

    private func apply(
        _ snapshot: LyricsEditingSnapshot, preservingTimeInputOf preserved: UUID?
    ) {
        self.snapshot = snapshot
        var updated = timeInputs
        for line in snapshot.lines where line.id != preserved {
            updated[line.id] = LyricTimeInputParser.displayString(from: line.startMs)
        }
        // 只保留仍存在的行，删除已删行的条目。
        updated = updated.filter { id, _ in
            snapshot.lines.contains { $0.id == id }
        }
        if let preserved, updated[preserved] == nil {
            let current = snapshot.lines.first { $0.id == preserved }?.startMs
            updated[preserved] = LyricTimeInputParser.displayString(from: current)
        }
        timeInputs = updated
        if preserved == nil {
            lineMessages = [:]
        }
    }

    private func refreshSharedBindingCount() async {
        sharedBindingCount = (try? await service.bindingsSharingCurrentDocument())?.count ?? 0
    }

    private static func initialTimeInputs(
        for snapshot: LyricsEditingSnapshot
    ) -> [UUID: String] {
        Dictionary(
            uniqueKeysWithValues: snapshot.lines.map {
                ($0.id, LyricTimeInputParser.displayString(from: $0.startMs))
            }
        )
    }

    private static func failureHint(_ failure: LyricTimeInputParser.Failure) -> String {
        switch failure {
        case .malformed:
            return "支持 [mm:ss.fff]、秒（12.5）或毫秒（1250ms）；留空表示未打轴"
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
}
