import SwiftUI
import ShinAppleKit
import ShinAppServices

// 歌词编辑器（全中文）：行式编辑表。
// 每行 = 原文输入框 + 时间输入框 + 译文输入框（简体中文）+ 行操作
// （上移/下移/删除/在下方插入）；时间等错误定位到对应行内联显示；
// 未打轴行明确标识；脏标记 + 关闭/放弃确认（接 shouldConfirmClose）。
// 本视图只读写 LyricsEditorModel（服务层草稿），不直接触碰数据库。
//
// 键盘约定（本 sheet 不注册窗口级空格/Return 热键）：
// - ⌘Return = 保存；普通 Return 在原文多行输入框内换行，在时间/译文
//   单行输入框内仅结束该行输入——都不触发保存或其他全局动作；
// - Esc = 请求关闭（有未保存修改时先弹确认，不直接丢弃）；
// - 撤销/重做只用按钮：不挂 ⌘Z/⇧⌘Z 快捷键，避免劫持输入框自身的
//   文本级撤销。空格在输入框内始终是普通字符。

struct LyricsEditorView: View {
    @ObservedObject var model: LyricsEditorModel
    /// 关闭请求（宿主收起 sheet；sheet onDismiss 统一收尾编辑会话）。
    let onClose: () -> Void

    @State private var showCloseConfirm = false
    @State private var showDiscardConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let message = model.alertMessage {
                alertBanner(message)
            }
            if let snapshot = model.snapshot {
                rowsArea(snapshot)
            } else {
                VStack {
                    ProgressView().controlSize(.small)
                    Text("正在载入歌词……")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 780, height: 620)
        .interactiveDismissDisabled(model.shouldConfirmClose)
        .confirmationDialog(
            "放弃未保存的修改并关闭编辑器？",
            isPresented: $showCloseConfirm,
            titleVisibility: .visible
        ) {
            Button("放弃修改并关闭", role: .destructive) {
                Task {
                    await model.discardEdits()
                    onClose()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关闭后本次未保存的修改将丢失；已保存过的内容不受影响。")
        }
        .confirmationDialog(
            "放弃未保存的修改？",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("放弃修改，恢复到已保存版本", role: .destructive) {
                Task { await model.discardEdits() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("歌词将恢复为打开编辑器（或上次保存）时的内容；本机歌词库不变。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("编辑歌词").font(.title3.weight(.semibold))
                dirtyBadge
                Spacer()
                Text("共 \(model.lineCount) 行　·　库内版本 r\(model.snapshot?.baseRevision ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = model.sharedNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var dirtyBadge: some View {
        if model.isSaving {
            Text("正在保存……")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.hasUnsavedChanges {
            Label("有未保存修改", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        } else if model.isEditing {
            Text("已保存").font(.caption).foregroundStyle(.green)
        }
    }

    private func alertBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if model.hasUnsavedChanges {
                Button("载入库中最新版本（放弃本地修改）") {
                    Task { await model.reloadFromStore() }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 行编辑表

    private func rowsArea(_ snapshot: LyricsEditingSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(snapshot.lines.enumerated()), id: \.element.id) { index, line in
                    EditorLineRow(
                        model: model,
                        index: index + 1,
                        line: line,
                        canMoveUp: index > 0,
                        canMoveDown: index < snapshot.lines.count - 1
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack(spacing: 8) {
            Button("撤销") { model.undo() }
                .disabled(!model.canUndo)
                .help("撤销上一步编辑（只影响未保存的草稿）")
            Button("重做") { model.redo() }
                .disabled(!model.canRedo)
                .help("重做被撤销的编辑")
            Button("放弃修改") { showDiscardConfirm = true }
                .disabled(!model.hasUnsavedChanges)
                .help("恢复为已保存版本")
            Spacer()
            Button("关闭") {
                if model.shouldConfirmClose {
                    showCloseConfirm = true
                } else {
                    onClose()
                }
            }
            .keyboardShortcut(.cancelAction)
            Button(model.isSaving ? "正在保存……" : "保存") {
                Task { await model.save() }
            }
            // ⌘Return = 保存。不用 .defaultAction（窗口级 Return
            // 热键），否则普通 Return 会被保存抢占，无法在原文框内换行。
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.hasUnsavedChanges || model.isSaving)
            .help("保存到本机歌词库（版本 +1），并同步到歌词面板（⌘Return）")
        }
    }
}

// MARK: - 单行编辑

private struct EditorLineRow: View {
    @ObservedObject var model: LyricsEditorModel
    let index: Int
    let line: LyricLine
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            controlsLine
            TextField("原文", text: bindingForOriginal, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .font(.body)
            TextField(
                "译文（简体中文，留空表示无译文）",
                text: bindingForTranslation
            )
            .textFieldStyle(.roundedBorder)
            .font(.body)
            if let message = model.lineMessages[line.id] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controlsLine: some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .leading)
            TextField("mm:ss.fff", text: bindingForTime)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 104)
                .help("支持 [mm:ss.fff]、秒（12.5）或毫秒（1250ms）；留空 = 未打轴")
            if line.startMs == nil {
                Text("未打轴")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("该行没有起始时间，只静态显示，不参与同步高亮")
            }
            if line.translations[LyricsEditorModel.translationLanguage]?.needsReview == true {
                Text("待复核")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("原文已修改，请核对译文后重新保存")
            }
            Spacer()
            rowOperationButtons
        }
    }

    private var rowOperationButtons: some View {
        HStack(spacing: 4) {
            Button {
                model.moveLine(lineId: line.id, direction: .up)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!canMoveUp)
            .accessibilityLabel("上移该行")
            .help("上移（译文随行走，不受影响）")
            Button {
                model.moveLine(lineId: line.id, direction: .down)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(!canMoveDown)
            .accessibilityLabel("下移该行")
            .help("下移（译文随行走，不受影响）")
            Button {
                model.addLine(after: line.id)
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .accessibilityLabel("在此行下方插入新行")
            .help("在此行下方插入新行（默认未打轴）")
            Button {
                model.deleteLine(lineId: line.id)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("删除该行")
            .help("删除该行（其译文一并删除；可用撤销恢复）")
        }
        .controlSize(.small)
    }

    // MARK: - 输入绑定

    private var bindingForOriginal: Binding<String> {
        Binding(
            get: { model.text(of: line.id) },
            set: { model.setLineText(lineId: line.id, to: $0) }
        )
    }

    private var bindingForTranslation: Binding<String> {
        Binding(
            get: { model.translation(of: line.id) },
            set: { model.setTranslation(lineId: line.id, to: $0) }
        )
    }

    private var bindingForTime: Binding<String> {
        Binding(
            get: {
                model.timeInputs[line.id]
                    ?? LyricTimeInputParser.displayString(from: line.startMs)
            },
            set: { model.updateTimeRaw(lineId: line.id, raw: $0) }
        )
    }
}
