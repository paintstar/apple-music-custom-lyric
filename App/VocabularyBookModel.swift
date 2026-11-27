import Foundation
import ShinAppleData
import ShinAppleKit

enum VocabularyPlaybackSource: Equatable {
    case book
    case flashcard
}

// swiftlint:disable inclusive_language
/// 单词本与笔记页面状态机：负责检索筛选、详情编辑、原声点播与状态同步。
@MainActor
final class VocabularyBookModel: ObservableObject {
    @Published private(set) var entries: [VocabularyEntry] = []
    @Published private(set) var occurrencesByEntryId: [UUID: [VocabularyOccurrence]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published var statusMessage: String?
    @Published private(set) var statusTone: VocabularyBookStatusTone = .info
    @Published private var playingOccurrence: VocabularyPlaybackRequest?
    @Published private var pendingPlayback: VocabularyPendingPlayback?

    @Published var searchText: String = "" {
        didSet { ensureValidSelection() }
    }
    @Published var selectedMasteryFilter: VocabularyMastery? {
        didSet { ensureValidSelection() }
    }
    @Published var selectedLanguageFilter: String? {
        didSet { ensureValidSelection() }
    }
    @Published var selectedEntryId: UUID?

    @Published var pendingExport: VocabularyBookPendingExport?

    @Published var isFlashcardPresented = false
    @Published var flashcardDeck: [VocabularyEntry] = []
    @Published var flashcardIndex = 0
    @Published var isFlashcardRevealed = false
    @Published var flashcardCompleted = false
    @Published var flashcardStats = VocabularyFlashcardStats()

    private let store: GRDBLyricsStore
    private let onPlayOccurrence: @MainActor (VocabularyOccurrence) async -> VocabularyOccurrencePlaybackOutcome
    private let onConfirmPlayback: @MainActor (VocabularyPlaybackConfirmation) async -> VocabularyOccurrencePlaybackOutcome
    var onVocabularyChanged: (@MainActor () -> Void)?

    private var reloadSequence = 0
    private var pendingMutationTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var isInvalidated = false

    init(
        store: GRDBLyricsStore,
        onPlayOccurrence: @escaping @MainActor (VocabularyOccurrence) async -> VocabularyOccurrencePlaybackOutcome,
        onConfirmPlayback: @escaping @MainActor (
            VocabularyPlaybackConfirmation
        ) async -> VocabularyOccurrencePlaybackOutcome = { _ in .cancelled },
        onVocabularyChanged: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.onPlayOccurrence = onPlayOccurrence
        self.onConfirmPlayback = onConfirmPlayback
        self.onVocabularyChanged = onVocabularyChanged
    }

    var totalEntryCount: Int { entries.count }

    var needReviewCount: Int {
        entries.filter { $0.mastery != .mastered }.count
    }

    var availableLanguages: [String] {
        let codes = entries.compactMap { Self.normalizedLanguageCode($0.language) }
        return Array(Set(codes)).sorted()
    }

    var filteredEntries: [VocabularyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let masteryFilter = selectedMasteryFilter, entry.mastery != masteryFilter {
                return false
            }
            if let languageFilter = selectedLanguageFilter,
               Self.normalizedLanguageCode(entry.language) != languageFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return matchesSearch(entry: entry, query: query)
        }
    }

    var selectedEntry: VocabularyEntry? {
        guard let selectedEntryId else { return nil }
        return filteredEntries.first { $0.id == selectedEntryId }
    }

    var currentFlashcardEntry: VocabularyEntry? {
        guard !flashcardCompleted, flashcardDeck.indices.contains(flashcardIndex) else {
            return nil
        }
        return flashcardDeck[flashcardIndex]
    }

    func occurrences(for entryId: UUID) -> [VocabularyOccurrence] {
        occurrencesByEntryId[entryId] ?? []
    }

    func occurrenceCount(for entryId: UUID) -> Int {
        occurrencesByEntryId[entryId]?.count ?? 0
    }

    func reload() async {
        guard !isInvalidated else { return }
        reloadSequence += 1
        let expectedSequence = reloadSequence
        isLoading = true
        defer {
            if reloadSequence == expectedSequence {
                isLoading = false
            }
        }
        await pendingMutationTask?.value
        guard !Task.isCancelled, !isInvalidated, reloadSequence == expectedSequence else { return }
        do {
            let loadedEntries = try await store.allVocabularyEntries()
            let loadedOccurrences = try await store.allVocabularyOccurrences()
            guard !Task.isCancelled, !isInvalidated, reloadSequence == expectedSequence else { return }
            entries = loadedEntries
            occurrencesByEntryId = Self.groupOccurrences(loadedOccurrences)
            reconcileFlashcardDeck(with: loadedEntries)
            if let languageFilter = selectedLanguageFilter, !availableLanguages.contains(languageFilter) {
                selectedLanguageFilter = nil
            }
            ensureValidSelection()
        } catch is CancellationError {
            return
        } catch {
            guard !isInvalidated, reloadSequence == expectedSequence else { return }
            setStatus("读取单词本失败：\(ErrorText.describe(error))", tone: .warning)
        }
    }

    func updateMastery(_ mastery: VocabularyMastery, for entry: VocabularyEntry) {
        let targetId = entry.id
        enqueueMutation { [weak self] in
            guard let self else { return }
            var updated = self.entries.first(where: { $0.id == targetId }) ?? entry
            guard updated.mastery != mastery else { return }
            updated.mastery = mastery
            updated.updatedAt = LyricTimestamp.now()
            do {
                try await self.store.updateVocabularyEntry(updated)
                guard !self.isInvalidated else { return }
                self.replaceEntryInMemory(updated)
                self.onVocabularyChanged?()
            } catch {
                guard !self.isInvalidated else { return }
                self.setStatus("更新掌握程度失败：\(ErrorText.describe(error))", tone: .warning)
            }
        }
    }

    func updateEntryDetails(
        entryId: UUID,
        reading: String?,
        partOfSpeech: String?,
        generalMeaning: String,
        userNote: String?
    ) {
        enqueueMutation { [weak self] in
            guard let self,
                  var updated = self.entries.first(where: { $0.id == entryId }) else { return }
            let nextReading = Self.nonEmptyTrimmed(reading)
            let nextPOS = Self.nonEmptyTrimmed(partOfSpeech)
            let nextMeaning = generalMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextNote = Self.nonEmptyTrimmed(userNote)
            guard updated.reading != nextReading
                    || updated.partOfSpeech != nextPOS
                    || updated.generalMeaning != nextMeaning
                    || updated.userNote != nextNote else {
                return
            }
            updated.reading = nextReading
            updated.partOfSpeech = nextPOS
            updated.generalMeaning = nextMeaning
            updated.userNote = nextNote
            updated.updatedAt = LyricTimestamp.now()
            do {
                try await self.store.updateVocabularyEntry(updated)
                guard !self.isInvalidated else { return }
                self.replaceEntryInMemory(updated)
                self.setStatus("已保存「\(updated.surface)」的释义与笔记", tone: .success)
                self.onVocabularyChanged?()
            } catch {
                guard !self.isInvalidated else { return }
                self.setStatus("保存词条失败：\(ErrorText.describe(error))", tone: .warning)
            }
        }
    }

    func deleteEntry(_ id: UUID) {
        enqueueMutation { [weak self] in
            guard let self else { return }
            let surface = self.entries.first(where: { $0.id == id })?.surface
            do {
                try await self.store.deleteVocabularyEntry(id: id)
                guard !self.isInvalidated else { return }
                self.entries.removeAll { $0.id == id }
                self.occurrencesByEntryId.removeValue(forKey: id)
                self.flashcardDeck.removeAll { $0.id == id }
                if let languageFilter = self.selectedLanguageFilter,
                   !self.availableLanguages.contains(languageFilter) {
                    self.selectedLanguageFilter = nil
                }
                self.ensureValidSelection()
                if let surface {
                    self.setStatus("已删除词条「\(surface)」", tone: .info)
                }
                self.onVocabularyChanged?()
            } catch {
                guard !self.isInvalidated else { return }
                self.setStatus("删除词条失败：\(ErrorText.describe(error))", tone: .warning)
            }
        }
    }

    func deleteOccurrence(_ id: UUID) {
        enqueueMutation { [weak self] in
            guard let self else { return }
            do {
                try await self.store.deleteVocabularyOccurrence(id: id)
                guard !self.isInvalidated else { return }
                for (entryId, list) in self.occurrencesByEntryId {
                    let remaining = list.filter { $0.id != id }
                    if remaining.count != list.count {
                        if remaining.isEmpty {
                            self.occurrencesByEntryId.removeValue(forKey: entryId)
                        } else {
                            self.occurrencesByEntryId[entryId] = remaining
                        }
                        break
                    }
                }
                self.setStatus("已移除该条原声例句出处", tone: .info)
                self.onVocabularyChanged?()
            } catch {
                guard !self.isInvalidated else { return }
                self.setStatus("移除出处失败：\(ErrorText.describe(error))", tone: .warning)
            }
        }
    }

    func clearPendingExport() {
        pendingExport = nil
    }

    func closeFlashcards() {
        cancelOccurrencePlayback(source: .flashcard)
        isFlashcardPresented = false
    }

    func clearStatus() {
        statusMessage = nil
    }

    func reportWarning(_ message: String) {
        setStatus(message, tone: .warning)
    }

    func invalidate() {
        isInvalidated = true
        reloadSequence += 1
        cancelOccurrencePlayback()
        pendingMutationTask?.cancel()
        pendingMutationTask = nil
        onVocabularyChanged = nil
    }
}
// swiftlint:enable inclusive_language

private struct VocabularyPlaybackRequest {
    let id = UUID()
    let occurrence: VocabularyOccurrence
    let source: VocabularyPlaybackSource
}

private struct VocabularyPendingPlayback {
    let request: VocabularyPlaybackRequest
    let confirmation: VocabularyPlaybackConfirmation
}

extension VocabularyBookModel {
    var playingOccurrenceId: UUID? { playingOccurrence?.occurrence.id }

    func playOccurrence(_ occurrence: VocabularyOccurrence, source: VocabularyPlaybackSource = .book) {
        guard pendingPlayback == nil else { return }
        let handler = onPlayOccurrence
        startOccurrencePlayback(VocabularyPlaybackRequest(occurrence: occurrence, source: source)) {
            await handler(occurrence)
        }
    }

    func playbackConfirmation(for source: VocabularyPlaybackSource) -> VocabularyPlaybackConfirmation? {
        pendingPlayback?.request.source == source ? pendingPlayback?.confirmation : nil
    }

    func dismissPlaybackConfirmation(_ confirmation: VocabularyPlaybackConfirmation) {
        guard pendingPlayback?.confirmation.id == confirmation.id else { return }
        pendingPlayback = nil
    }

    func confirmPlayback(_ confirmation: VocabularyPlaybackConfirmation) {
        guard let pendingPlayback, pendingPlayback.confirmation.id == confirmation.id else { return }
        self.pendingPlayback = nil
        let handler = onConfirmPlayback
        startOccurrencePlayback(pendingPlayback.request) { await handler(confirmation) }
    }

    private func startOccurrencePlayback(
        _ request: VocabularyPlaybackRequest,
        operation: @escaping @MainActor () async -> VocabularyOccurrencePlaybackOutcome
    ) {
        guard !isInvalidated, playingOccurrence == nil else { return }
        playingOccurrence = request
        statusMessage = nil
        playTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let result = await operation()
            guard let self, self.playingOccurrence?.id == request.id else { return }
            self.playingOccurrence = nil
            self.playTask = nil
            guard !self.isInvalidated, !Task.isCancelled else { return }
            self.applyOccurrencePlaybackOutcome(result, request: request)
        }
    }

    func cancelOccurrencePlayback(source: VocabularyPlaybackSource? = nil) {
        if source == nil || pendingPlayback?.request.source == source {
            pendingPlayback = nil
        }
        guard let request = playingOccurrence, source == nil || request.source == source else { return }
        playTask?.cancel()
        playTask = nil
        playingOccurrence = nil
    }

    func cancelOccurrencePlaybackOutsideEntry(_ entryId: UUID?, source: VocabularyPlaybackSource) {
        guard let request = pendingPlayback?.request ?? playingOccurrence,
              request.source == source, request.occurrence.entryId != entryId else { return }
        cancelOccurrencePlayback(source: source)
    }

    private func applyOccurrencePlaybackOutcome(_ result: VocabularyOccurrencePlaybackOutcome, request: VocabularyPlaybackRequest) {
        switch result {
        case .played, .cancelled:
            break
        case .requiresQueueConfirmation(let confirmation):
            pendingPlayback = VocabularyPendingPlayback(request: request, confirmation: confirmation)
        case .information(let message):
            setStatus(message, tone: .info)
        case .warning(let message):
            setStatus(message, tone: .warning)
        }
    }
}

// MARK: - 内部队列、检索与分组助手

extension VocabularyBookModel {
    private func enqueueMutation(_ operation: @escaping @MainActor () async -> Void) {
        guard !isInvalidated else { return }
        let previous = pendingMutationTask
        pendingMutationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.isInvalidated else { return }
            self.isMutating = true
            defer { self.isMutating = false }
            await operation()
        }
    }

    private func replaceEntryInMemory(_ updated: VocabularyEntry) {
        if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[idx] = updated
        }
        if let deckIdx = flashcardDeck.firstIndex(where: { $0.id == updated.id }) {
            flashcardDeck[deckIdx] = updated
        }
    }

    private func reconcileFlashcardDeck(with loadedEntries: [VocabularyEntry]) {
        guard !flashcardDeck.isEmpty else { return }
        let byId = Dictionary(uniqueKeysWithValues: loadedEntries.map { ($0.id, $0) })
        flashcardDeck = flashcardDeck.map { byId[$0.id] ?? $0 }
    }

    private func ensureValidSelection() {
        let current = filteredEntries
        if let selectedEntryId, current.contains(where: { $0.id == selectedEntryId }) {
            return
        }
        selectedEntryId = current.first?.id
    }

    private func setStatus(_ message: String, tone: VocabularyBookStatusTone) {
        statusMessage = message
        statusTone = tone
    }

    private func matchesSearch(entry: VocabularyEntry, query: String) -> Bool {
        let fields: [String?] = [
            entry.surface,
            entry.lemma,
            entry.reading,
            entry.partOfSpeech,
            entry.generalMeaning,
            entry.userNote
        ]
        if fields.contains(where: { $0?.localizedCaseInsensitiveContains(query) == true }) {
            return true
        }
        let occs = occurrencesByEntryId[entry.id] ?? []
        return occs.contains { occ in
            occ.surfaceInLine.localizedCaseInsensitiveContains(query)
                || occ.contextualMeaning.localizedCaseInsensitiveContains(query)
                || occ.lineTextSnapshot.localizedCaseInsensitiveContains(query)
                || occ.lineTranslationSnapshot?.localizedCaseInsensitiveContains(query) == true
                || occ.trackTitleHint?.localizedCaseInsensitiveContains(query) == true
                || occ.artistHint?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private static func groupOccurrences(_ items: [VocabularyOccurrence]) -> [UUID: [VocabularyOccurrence]] {
        var grouped: [UUID: [VocabularyOccurrence]] = [:]
        for item in items {
            grouped[item.entryId, default: []].append(item)
        }
        for (entryId, list) in grouped {
            grouped[entryId] = list.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    if let lhsDate = LyricTimestamp.date(from: lhs.createdAt),
                       let rhsDate = LyricTimestamp.date(from: rhs.createdAt),
                       lhsDate != rhsDate {
                        return lhsDate > rhsDate
                    }
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
        return grouped
    }
}
