import SwiftUI
import ShinAppServices

/// 管理当前歌词库中实际保存的歌词和译文，复用学习歌曲页的同一模型。
struct LocalResourceManagementView: View {
    @ObservedObject var library: LyricsLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selection: Set<UUID> = []
    @State private var deletionTarget: LyricsLibraryModel.ResourceDeletionPreview?

    private var filteredItems: [LyricsLibraryOverviewItem] { library.resources(matching: searchText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            counts
            Text("管理本机保存的歌词、译文和歌曲关联。删除后无法恢复；导出的备份、导入源文件和「音乐」App 中的歌曲不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("搜索歌名、文件名或关联歌曲", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Button("刷新") { Task { await library.refresh() } }
                    .disabled(library.isLoading || library.isDeletingResources)
            }
            resourceList
            if let message = library.alertMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .interactiveDismissDisabled(library.isDeletingResources)
        .task { await library.refresh() }
        .onChange(of: library.items) { _, items in
            selection.formIntersection(Set(items.map(\.documentId)))
        }
        .onDisappear { if let target = deletionTarget { library.cancelResourceDeletion(target) } }
        .confirmationDialog(
            "删除本地歌词资源？", isPresented: Binding(
                get: { deletionTarget != nil },
                set: { presented in
                    if !presented {
                        if let target = deletionTarget { library.cancelResourceDeletion(target) }
                        deletionTarget = nil
                    }
                }
            ), titleVisibility: .visible, presenting: deletionTarget
        ) { target in
            Button("删除歌词和译文", role: .destructive) {
                library.beginResourceDeletion(target)
            }
            Button("取消", role: .cancel) { library.cancelResourceDeletion(target) }
        } message: { preview in
            Text(Self.deletionMessage(preview))
        }
    }

    private var header: some View {
        HStack {
            Text("缓存资源管理").font(.title2.bold())
            if library.isLoading || library.isDeletingResources {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(library.isDeletingResources)
        }
    }

    private var counts: some View {
        HStack(spacing: 24) {
            Text("歌词总数 \(library.items.count)")
            Text("已关联 \(library.associatedResourceCount)")
            Text("未关联 \(library.unassociatedResourceCount)")
        }
        .font(.subheadline)
    }

    private var resourceList: some View {
        List {
            if filteredItems.isEmpty {
                Text(library.isLoading ? "正在读取本地资源……" : searchText.isEmpty ? "暂无本地歌词资源。" : "没有找到匹配的资源。")
                    .foregroundStyle(.secondary)
            }
            ForEach(filteredItems, id: \.documentId) { item in
                let displayName = LyricsLibraryModel.displayName(for: item)
                let trackNames = LyricsLibraryModel.associatedTrackNames(for: item).joined(separator: "、")
                Toggle(isOn: Binding(
                    get: { selection.contains(item.documentId) },
                    set: { selected in
                        if selected { selection.insert(item.documentId) } else { selection.remove(item.documentId) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName).font(.body.weight(.medium))
                        if let filename = item.originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !filename.isEmpty, filename != displayName {
                            Text(filename).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(item.lineCount) 行 · \(item.bindingCount) 个歌曲关联")
                            .font(.caption).foregroundStyle(.secondary)
                        if !trackNames.isEmpty, trackNames != displayName {
                            Text(trackNames)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .toggleStyle(.checkbox)
                .disabled(library.isDeletingResources)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 180)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Text("已选 \(selection.count) 份").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("删除所选", role: .destructive) {
                requestDeletion(library.items.filter { selection.contains($0.documentId) })
            }
            .disabled(selection.isEmpty)
            Button("清理未关联", role: .destructive) {
                requestDeletion(library.items.filter { $0.bindingCount == 0 })
            }
            .disabled(library.unassociatedResourceCount == 0)
            Button("删除全部", role: .destructive) { requestDeletion(library.items) }
                .disabled(library.items.isEmpty)
        }
        .disabled(library.isDeletingResources || library.isLoading)
    }

    private func requestDeletion(_ items: [LyricsLibraryOverviewItem]) {
        deletionTarget = library.requestResourceDeletion(items)
    }

    static func deletionMessage(_ preview: LyricsLibraryModel.ResourceDeletionPreview) -> String {
        let names = Array(preview.trackHints.prefix(5))
        let affected = names.isEmpty ? "" : "关联歌曲：\(names.joined(separator: "、"))\(preview.bindingCount > names.count ? "等" : "")。"
        return "将删除 \(preview.documentCount) 份歌词及其中的全部译文（含人工译文），解除 \(preview.bindingCount) 个歌曲关联。"
            + affected + "此操作无法恢复。"
    }
}
