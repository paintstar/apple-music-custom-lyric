import SwiftUI
import UniformTypeIdentifiers
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 本地歌词库页（全中文）：
// - 文档列表（文件名/标题提示、行数、打轴统计、关联数与曲目提示、详情）；
// - 操作：编辑（打开编辑器）、重新关联当前歌曲、删除（确认对话框
//   列出受影响歌曲绑定，确认后单事务删除，不留悬空引用）、导出 LRC；
// - 备份：导出 JSON 完整备份到用户选择位置；导入备份（选文件 → 冲突预览
//   → 确认导入 → 完成反馈）；
// - 存储位置与风险说明：数据目录展示 + 数据不会随删除 App 自动消失/备份的提示。

// MARK: - 歌词库页

struct LyricsLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var library: LyricsLibraryModel
    @Environment(\.dismiss) private var dismiss
    /// 嵌入模式：作为侧边栏「学习歌曲」页展示（隐藏「关闭」、
    /// 弹性尺寸、底部留出悬浮播放条空间）；false = 原 sheet 形态。
    var isEmbedded = false
    var bottomContentInset: CGFloat = 96
    @State private var isBackupImporterPresented = false
    @State private var isBackupExporterPresented = false
    @State private var isLRCFileExporterPresented = false
    /// 待确认的重新关联目标（行按钮设置，确认对话框消费）。
    @State private var reassociateTarget: LyricsLibraryOverviewItem?

    var body: some View {
        mainColumn
            .task { await library.refresh() }
            .sheet(
                isPresented: Binding(
                    get: { library.lrcExport != nil },
                    set: { if !$0 { library.cancelLRCExport() } }
                )
            ) {
                LRCExportSheet(library: library)
            }
            .confirmationDialog(
                "重新关联当前歌曲？",
                isPresented: Binding(
                    get: { reassociateTarget != nil },
                    set: { if !$0 { reassociateTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: reassociateTarget
            ) { target in
                Button("关联到这份歌词（原关联文档保留）") {
                    if let trackKey = model.currentTrackKey {
                        Task { await library.reassociate(trackKey: trackKey, to: target) }
                    }
                    reassociateTarget = nil
                }
                Button("取消", role: .cancel) { reassociateTarget = nil }
            } message: { target in
                Text("当前歌曲将改用「\(LyricsLibraryModel.displayName(for: target))」；它当前的播放延迟会保留。")
            }
            .confirmationDialog(
                "删除这份歌词？",
                isPresented: Binding(
                    get: { library.deletionPreview != nil },
                    set: { if !$0 { library.cancelDeletion() } }
                ),
                titleVisibility: .visible,
                presenting: library.deletionPreview
            ) { preview in
                Button("删除歌词并解除 \(preview.bindings.count) 个歌曲关联", role: .destructive) {
                    Task { await library.confirmDeletion() }
                }
                Button("取消", role: .cancel) { library.cancelDeletion() }
            } message: { preview in
                Text(Self.deletionMessage(preview))
            }
    }

    /// 主栏（含文件导入/导出面板）。
    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            storageNote
            if let message = library.alertMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            documentList
            backupSection
        }
        .padding(20)
        .frame(
            maxWidth: isEmbedded ? .infinity : 700,
            maxHeight: isEmbedded ? .infinity : 580
        )
        // 嵌入模式：底部留出悬浮播放条空间，列表不被遮挡。
        .padding(.bottom, isEmbedded ? bottomContentInset : 0)
        .fileImporter(
            isPresented: $isBackupImporterPresented,
            allowedContentTypes: [.json, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await library.beginBackupImport(at: url) }
            }
        }
        .fileExporter(
            isPresented: $isBackupExporterPresented,
            document: library.pendingBackupExport.map(BackupJSONDocument.init(data:)),
            contentType: .json,
            defaultFilename: Self.backupFilename()
        ) { _ in
            library.clearBackupExport()
        }
        .fileExporter(
            isPresented: $isLRCFileExporterPresented,
            document: library.lrcExport?.result.map { LRCFileDocument(text: $0.text) },
            contentType: LRCFileDocument.lrcType,
            defaultFilename: Self.lrcFilename(for: library.lrcExport?.item)
        ) { _ in
            library.cancelLRCExport()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("本地歌词库")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                Task { await library.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("刷新列表")
            .help("刷新列表")
            if !isEmbedded {
                Button("关闭") { dismiss() }
            }
        }
    }

    private var storageNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "歌词数据只保存在本机（\(model.lyricsDatabaseNote)）",
                systemImage: "internaldrive"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("注意：数据目录在应用外的普通文件夹中，删除 App 不会自动删除数据，也不会自动备份。JSON 备份是唯一可靠备份方式，请定期导出完整备份并妥善保存。")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 文档列表

    private var documentList: some View {
        Group {
            if library.isLoading && library.items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取歌词库……")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if library.items.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有本地歌词。")
                        .foregroundStyle(.secondary)
                    Text("播放一首歌曲后点击「导入歌词」，即可建立第一份本地歌词。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(library.items, id: \.documentId) { item in
                    LibraryItemRow(
                        item: item,
                        canReassociate: model.currentTrackKey != nil,
                        onEdit: {
                            model.beginLyricsEditing(documentId: item.documentId)
                            dismiss()
                        },
                        onExportLRC: { Task { await library.beginLRCExport(item) } },
                        onReassociate: { reassociateTarget = item },
                        onDelete: { Task { await library.requestDeletion(item) } }
                    )
                }
            }
        }
    }

    // MARK: - 备份区

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("备份与恢复")
                    .font(.headline)
                Spacer()
                Button("导出完整备份（JSON）…") {
                    Task {
                        await library.prepareBackupExport()
                        if library.pendingBackupExport != nil {
                            isBackupExporterPresented = true
                        }
                    }
                }
                Button("导入备份…") {
                    isBackupImporterPresented = true
                }
            }
            backupStageContent
        }
    }

    @ViewBuilder
    private var backupStageContent: some View {
        switch library.backupStage {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在导入备份……")
            }
        case let .preview(parsed, preview):
            BackupPreviewSection(parsed: parsed, preview: preview) {
                Task { await library.confirmBackupImport() }
            } onCancel: {
                library.cancelBackupImport()
            }
        case let .completed(message):
            HStack {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Spacer()
                Button("完成") { library.cancelBackupImport() }
            }
        }
    }

    // MARK: - 文案

    static func deletionMessage(_ preview: LyricsLibraryModel.DeletionPreview) -> String {
        let names = preview.bindings.map { binding in
            binding.titleHint ?? binding.trackKey
        }
        let listing = names.isEmpty ? "（当前没有歌曲关联这份歌词）" : names.joined(separator: "、")
        return "将删除「\(preview.displayName)」并解除以下歌曲的关联：\(listing)。删除不可撤销；完整备份可用来恢复。"
    }

    static func backupFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.timeZone = TimeZone.current
        return "ShinApple-歌词备份-\(formatter.string(from: Date())).json"
    }

    static func lrcFilename(for item: LyricsLibraryOverviewItem?) -> String {
        let base: String
        if let filename = item?.originalFilename {
            base = (filename as NSString).deletingPathExtension
        } else if let title = item?.titleHint {
            base = title
        } else {
            base = "歌词导出"
        }
        return "\(base).lrc"
    }
}

// MARK: - 文档行

private struct LibraryItemRow: View {
    let item: LyricsLibraryOverviewItem
    let canReassociate: Bool
    let onEdit: () -> Void
    let onExportLRC: () -> Void
    let onReassociate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(LyricsLibraryModel.displayName(for: item))
                    .font(.body.weight(.medium))
                Spacer()
                Text("关联 \(item.bindingCount) 首歌曲")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(item.bindingCount > 1 ? .orange : .secondary)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !item.trackHints.isEmpty {
                Text("关联歌曲：\(item.trackHints.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Button("编辑", action: onEdit)
                Button("导出 LRC", action: onExportLRC)
                Button("重新关联当前歌曲", action: onReassociate)
                    .disabled(!canReassociate)
                    .help(canReassociate
                        ? "把当前播放/选定的歌曲改用这份歌词"
                        : "没有当前歌曲：先在搜索结果或播放中选择一首歌曲")
                Spacer()
                Button("删除", role: .destructive, action: onDelete)
            }
            .font(.callout)
            DisclosureGroup("文档详情") {
                VStack(alignment: .leading, spacing: 2) {
                    detailRows
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let filename = item.originalFilename ?? "无来源文件名"
        return "共 \(item.lineCount) 行（已打轴 \(item.timedLineCount) / 未打轴 \(item.untimedLineCount)）"
            + " · 来源：\(filename)"
            + " · revision \(item.revision)"
    }

    @ViewBuilder
    private var detailRows: some View {
        Text("文档 id：\(item.documentId.uuidString)")
        Text("更新时间：\(item.updatedAt)")
        Text("文件 offset（sourceOffsetMs）：\(item.sourceOffsetMs) ms（显示时间 = 行时间 − offset + 用户延迟）")
        if item.bindings.isEmpty {
            Text("未关联任何歌曲（可被「重新关联当前歌曲」重新使用，或删除）。")
        } else {
            ForEach(item.bindings, id: \.trackKey) { binding in
                Text(bindingDetail(binding))
            }
        }
    }

    private func bindingDetail(_ binding: LyricsLibraryBindingSummary) -> String {
        var text = "• \(binding.titleHint ?? "未知歌名（\(binding.trackKey)）")"
        if let artist = binding.artistHint {
            text += " / \(artist)"
        }
        text += " · 延迟 \(binding.userDelayMs) ms"
        return text
    }
}

// MARK: - 备份预览区

private struct BackupPreviewSection: View {
    let parsed: BackupParseResult
    let preview: BackupConflictPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("确认导入以下变更（确认前不会改动本机歌词库）：")
                .font(.callout.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !preview.documentsToAdd.isEmpty {
                        addedDocuments
                    }
                    if !preview.documentReplacements.isEmpty {
                        replacedDocuments
                    }
                    if !preview.bindingsToAdd.isEmpty {
                        addedBindings
                    }
                    if !preview.bindingReplacements.isEmpty {
                        replacedBindings
                    }
                    ForEach(Array(parsed.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warningText(warning), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            HStack {
                Button("确认导入", action: onConfirm)
                Button("取消", action: onCancel)
            }
        }
    }

    private func names(_ values: [String]) -> String {
        values.isEmpty ? "（未命名）" : values.joined(separator: "、")
    }

    private var addedDocuments: some View {
        let list = names(preview.documentsToAdd.map(Self.documentName))
        return Text("将新增歌词文档 \(preview.documentsToAdd.count) 份：\(list)")
    }

    private var replacedDocuments: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("将替换歌词文档 \(preview.documentReplacements.count) 份（现有版本会被备份版本覆盖）：")
            ForEach(preview.documentReplacements, id: \.existing.id) { replacement in
                Text("• \(Self.documentName(replacement.incoming))"
                    + "（revision \(replacement.existing.revision) → \(replacement.incoming.revision)）")
            }
        }
    }

    private var addedBindings: some View {
        let hints = preview.bindingsToAdd.compactMap(\.titleHint)
        return Text("将新增歌曲关联 \(preview.bindingsToAdd.count) 条：\(names(hints))")
    }

    private var replacedBindings: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("将替换歌曲关联 \(preview.bindingReplacements.count) 条：")
            ForEach(preview.bindingReplacements, id: \.existing.trackKey) { replacement in
                Text("• \(replacement.existing.titleHint ?? replacement.existing.trackKey)"
                    + "（延迟 \(replacement.existing.userDelayMs) ms → \(replacement.incoming.userDelayMs) ms）")
            }
        }
    }

    /// 备份内文档的展示名（标题提示 / 文件名兜底）。
    private static func documentName(_ document: LyricDocument) -> String {
        document.metadata["ti"]?.first ?? document.originalFilename ?? "未命名歌词"
    }

    private func warningText(_ warning: BackupWarning) -> String {
        switch warning {
        case let .unknownKey(path, key):
            return "备份含未知字段（已跳过）：\(path).\(key)"
        case let .settingNotInAllowlist(key):
            return "设置项「\(key)」不在可移植白名单内，未导入。"
        case .utf8BomStripped:
            return "备份文件带 UTF-8 BOM，已自动剥离后解析。"
        }
    }
}
