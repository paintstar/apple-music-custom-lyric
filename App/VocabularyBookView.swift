import SwiftUI
import UniformTypeIdentifiers
import ShinAppleData
import ShinAppleKit
import ShinAppServices

/// 单词本侧边栏容器：按当前 `GRDBLyricsStore` 身份绑定独立状态机并在跨页面修改时自动刷新。
struct VocabularyBookContainerView: View {
    let store: GRDBLyricsStore
    let bottomContentInset: CGFloat
    @StateObject private var book: VocabularyBookModel

    init(store: GRDBLyricsStore, model: AppModel, bottomContentInset: CGFloat) {
        self.store = store
        self.bottomContentInset = bottomContentInset
        _book = StateObject(
            wrappedValue: VocabularyBookModel(
                store: store,
                onPlayOccurrence: { [weak model] occurrence in
                    guard let model else { return "应用状态不可用。" }
                    return await model.playVocabularyOccurrence(occurrence)
                },
                onVocabularyChanged: { [weak model] in
                    model?.lyricsPanel?.reloadStudyMarks()
                }
            )
        )
    }

    var body: some View {
        VocabularyBookView(book: book, bottomContentInset: bottomContentInset)
            .task { await book.reload() }
            .onReceive(NotificationCenter.default.publisher(for: .shinVocabularyDidChange)) { notification in
                if let sender = notification.object as? GRDBLyricsStore, sender !== store {
                    return
                }
                Task { await book.reload() }
            }
            .onDisappear { book.invalidate() }
    }
}

/// 侧边栏「单词本与笔记」主页面：检索筛选、双栏主从详情、原声点播、闪卡自测与多格式导出。
struct VocabularyBookView: View {
    @ObservedObject var book: VocabularyBookModel
    var bottomContentInset: CGFloat = 96
    @State private var pendingDeleteEntry: VocabularyEntry?

    var body: some View {
        VStack(spacing: 0) {
            toolbarSection
            if let message = book.statusMessage {
                statusBanner(message)
            }
            Divider()
            mainContent
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(isPresented: $book.isFlashcardPresented) {
            VocabularyFlashcardView(book: book)
        }
        .fileExporter(
            isPresented: Binding(
                get: { book.pendingExport != nil },
                set: { if !$0 { book.clearPendingExport() } }
            ),
            document: book.pendingExport?.document,
            contentType: book.pendingExport?.contentType ?? .plainText,
            defaultFilename: book.pendingExport?.defaultFilename ?? "ShinApple-单词本.txt"
        ) { result in
            if case let .failure(error) = result {
                book.reportWarning("导出失败：\(ErrorText.describe(error))")
            }
            book.clearPendingExport()
        }
        .confirmationDialog(
            "删除这个生词词条？",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteEntry
        ) { target in
            Button("删除词条", role: .destructive) {
                book.deleteEntry(target.id)
                pendingDeleteEntry = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: { target in
            let count = book.occurrenceCount(for: target.id)
            Text("将删除「\(target.surface)」及关联的 \(count) 条原声例句出处（原歌词文档不受影响）。此操作不可撤销。")
        }
    }

    // MARK: - 顶部工具栏

    private var toolbarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text("单词本与学习笔记")
                    .font(.system(size: 22, weight: .bold))
                statBadge("共 \(book.totalEntryCount) 词", tint: .secondary)
                statBadge("待巩固 \(book.needReviewCount) 词", tint: book.needReviewCount > 0 ? .orange : .green)
                Spacer(minLength: 8)
                Button {
                    book.startFlashcards()
                } label: {
                    Text("🃏 闪卡自测")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.appleMusicPink)
                .controlSize(.regular)
                .disabled(book.filteredEntries.isEmpty)

                exportMenu
            }

            HStack(spacing: 10) {
                searchField
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        masteryFilterCapsules
                        if !book.availableLanguages.isEmpty {
                            Divider().frame(height: 16).padding(.horizontal, 2)
                            languageFilterCapsules
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var exportMenu: some View {
        Menu {
            ForEach(VocabularyExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) {
                    book.prepareExport(format: format)
                }
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .disabled(book.filteredEntries.isEmpty)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索单词、读音、释义、笔记或原句", text: $book.searchText)
                .textFieldStyle(.plain)
            if !book.searchText.isEmpty {
                Button { book.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(width: 240, height: 30)
        .background(.primary.opacity(0.045), in: Capsule())
        .overlay {
            Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    // swiftlint:disable inclusive_language
    @ViewBuilder
    private var masteryFilterCapsules: some View {
        filterCapsule(
            title: "全部",
            isSelected: book.selectedMasteryFilter == nil,
            tint: Color.appleMusicPink
        ) {
            book.selectedMasteryFilter = nil
        }
        ForEach(VocabularyMastery.allCases, id: \.self) { level in
            filterCapsule(
                title: level.displayName,
                isSelected: book.selectedMasteryFilter == level,
                tint: masteryColor(level)
            ) {
                book.selectedMasteryFilter = book.selectedMasteryFilter == level ? nil : level
            }
        }
    }
    // swiftlint:enable inclusive_language

    @ViewBuilder
    private var languageFilterCapsules: some View {
        filterCapsule(
            title: "全部语种",
            isSelected: book.selectedLanguageFilter == nil,
            tint: .accentColor
        ) {
            book.selectedLanguageFilter = nil
        }
        ForEach(book.availableLanguages, id: \.self) { code in
            filterCapsule(
                title: VocabularyBookModel.languageDisplayName(code) ?? code.uppercased(),
                isSelected: book.selectedLanguageFilter == code,
                tint: .accentColor
            ) {
                book.selectedLanguageFilter = book.selectedLanguageFilter == code ? nil : code
            }
        }
    }

    // MARK: - 主从内容区

    @ViewBuilder
    private var mainContent: some View {
        if book.isLoading && book.entries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在读取单词本……")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomContentInset)
        } else if book.entries.isEmpty {
            emptyBookPlaceholder
        } else {
            HSplitView {
                entryListPane
                    .frame(minWidth: 230, idealWidth: 280, maxWidth: 380)
                detailPane
                    .frame(minWidth: 280, maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var entryListPane: some View {
        let items = book.filteredEntries
        if items.isEmpty {
            VStack(spacing: 10) {
                Text("没有符合当前筛选条件的词条")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重置筛选") {
                    book.searchText = ""
                    book.selectedMasteryFilter = nil
                    book.selectedLanguageFilter = nil
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomContentInset)
        } else {
            List(selection: $book.selectedEntryId) {
                ForEach(items) { entry in
                    VocabularyListRow(
                        entry: entry,
                        occurrenceCount: book.occurrenceCount(for: entry.id)
                    )
                    .tag(entry.id)
                }
                Color.clear
                    .frame(height: bottomContentInset)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selected = book.selectedEntry {
            VocabularyEntryDetailView(
                book: book,
                entry: selected,
                bottomContentInset: bottomContentInset,
                onRequestDelete: { pendingDeleteEntry = $0 }
            )
            .id(selected.id)
        } else {
            Text("请选择左侧词条查看详情与原声例句")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, bottomContentInset)
        }
    }

    private var emptyBookPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("单词本还没有词条")
                .font(.headline)
            Text("在歌曲歌词区划词并点击「加入单词库」或快捷收录，即可在这里复习原声例句与笔记。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, bottomContentInset)
    }

    // MARK: - 辅助组件

    private func statusBanner(_ message: String) -> some View {
        let icon: String
        let color: Color
        switch book.statusTone {
        case .info:
            icon = "info.circle.fill"
            color = .secondary
        case .success:
            icon = "checkmark.circle.fill"
            color = .green
        case .warning:
            icon = "exclamationmark.triangle.fill"
            color = .orange
        }
        return HStack(spacing: 8) {
            Label(message, systemImage: icon)
                .font(.callout)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                book.clearStatus()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private func statBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func filterCapsule(
        title: String,
        isSelected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? tint : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? tint.opacity(0.14) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // swiftlint:disable inclusive_language
    private func masteryColor(_ mastery: VocabularyMastery) -> Color {
        switch mastery {
        case .learning: return .orange
        case .reviewing: return .blue
        case .mastered: return .green
        }
    }
    // swiftlint:enable inclusive_language
}

// MARK: - 左侧词条列表行

private struct VocabularyListRow: View {
    let entry: VocabularyEntry
    let occurrenceCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.surface)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let lemma = VocabularyBookModel.nonEmptyTrimmed(entry.lemma),
                   lemma != entry.surface {
                    Text(lemma)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VocabularyMasteryBadge(mastery: entry.mastery)
            }

            if let reading = VocabularyBookModel.nonEmptyTrimmed(entry.reading) {
                Text(reading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 6) {
                Text(meaningSummary)
                    .font(.caption)
                    .foregroundStyle(hasMeaning ? .secondary : .tertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if occurrenceCount > 0 {
                    Text("\(occurrenceCount) 处")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var hasMeaning: Bool {
        VocabularyBookModel.nonEmptyTrimmed(entry.generalMeaning) != nil
    }

    private var meaningSummary: String {
        VocabularyBookModel.nonEmptyTrimmed(entry.generalMeaning) ?? "暂无通用释义"
    }
}
