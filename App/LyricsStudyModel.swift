import CoreGraphics
import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
import ShinAppServices

/// 歌词学习面板交互协调模型：管理划词浮条、本地词典查词、显式 AI 词句解析与生词/笔记落库。
@MainActor
final class LyricsStudyModel: ObservableObject {
    // 遵循调用方注入的 `(trackKey, title, artist)` 三元组契约。
    // swiftlint:disable:next large_tuple
    typealias TrackHint = (trackKey: String?, title: String?, artist: String?)

    @Published var selectionBar: LyricsWordSelection?
    @Published var quickSaveMessage: String?
    @Published var wordPopover: WordPopoverState?
    @Published var linePopover: LinePopoverState?
    @Published var lineEditPopover: LineQuickEditState?
    @Published private(set) var clearSelectionToken = 0

    let store: GRDBLyricsStore
    let isMock: Bool
    let studyService: LyricsStudyService
    let settingsStore: AIServiceSettingsStore
    private let credentialStore: any AICredentialStoring
    let trackHintProvider: @MainActor () -> TrackHint
    var onVocabularyChanged: (@MainActor () -> Void)?
    var onDocumentNoteSaved: (@MainActor () -> Void)?

    var activeLineSourceDocument: LyricDocument?
    var activeLineProviderConfiguration: AIConfiguration?
    var isInvalidated = false
    private var wordRequestSequence = 0
    var lineRequestSequence = 0
    var wordSaveSequence = 0
    var lineSaveSequence = 0
    var lineEditSaveSequence = 0
    private var wordAITask: Task<Void, Never>?
    var lineAITask: Task<Void, Never>?
    var lineFollowUpTask: Task<Void, Never>?
    var wordSaveTask: Task<Void, Never>?
    var lineSaveTask: Task<Void, Never>?
    var lineEditSaveTask: Task<Void, Never>?

    init(
        store: GRDBLyricsStore,
        isMock: Bool,
        trackHintProvider: @escaping @MainActor () -> TrackHint,
        onVocabularyChanged: (@MainActor () -> Void)? = nil,
        onDocumentNoteSaved: (@MainActor () -> Void)? = nil,
        localDictionary: any LocalDictionaryLookupProviding = LocalDictionaryService(),
        aiClient: (any AIStudyProviding)? = nil,
        settingsStore: AIServiceSettingsStore = AIServiceSettingsStore(),
        credentialStore: (any AICredentialStoring)? = nil
    ) {
        self.store = store
        self.isMock = isMock
        self.trackHintProvider = trackHintProvider
        self.onVocabularyChanged = onVocabularyChanged
        self.onDocumentNoteSaved = onDocumentNoteSaved
        self.settingsStore = settingsStore

        let resolvedCredentials: any AICredentialStoring = credentialStore
            ?? (isMock ? InMemoryAICredentialStore() : SystemKeychainCredentialStore())
        self.credentialStore = resolvedCredentials
        let resolvedClient: any AIStudyProviding = aiClient
            ?? (isMock ? MockStudyDetailAIClient() : OpenAICompatibleClient(credentialStore: resolvedCredentials))

        self.studyService = LyricsStudyService(
            store: store,
            localDictionary: localDictionary,
            aiClient: resolvedClient,
            configurationProvider: { settingsStore.load() }
        )
    }

    var missingKeyWarning: String? {
        guard !isMock else { return nil }
        let config = settingsStore.load()
        guard config.preset.requiresAPIKey else { return nil }
        do {
            return try credentialStore.hasAPIKey(for: config.preset)
                ? nil
                : "尚未配置「\(config.preset.displayName)」API Key，请前往「设置 → AI 学习服务」保存密钥。"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 选区与浮条

    func updateSelection(_ selection: LyricsWordSelection?) {
        guard !isInvalidated else { return }
        guard let selection else {
            if selectionBar != nil { selectionBar = nil }
            if quickSaveMessage != nil { quickSaveMessage = nil }
            return
        }
        let clean = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            if selectionBar != nil { selectionBar = nil }
            if quickSaveMessage != nil { quickSaveMessage = nil }
            return
        }
        if selection.documentId != selectionBar?.documentId
            || selection.lineId != selectionBar?.lineId
            || selection.utf16Location != selectionBar?.utf16Location
            || selection.utf16Length != selectionBar?.utf16Length {
            if quickSaveMessage != nil { quickSaveMessage = nil }
        }
        if selectionBar != selection {
            selectionBar = selection
        }
    }

    func reconcileDocument(id activeDocumentId: UUID?) {
        if selectionBar?.documentId != activeDocumentId {
            selectionBar = nil
            quickSaveMessage = nil
        }
        if wordPopover?.documentId != activeDocumentId {
            dismissWordPopover(clearSelection: false)
        }
        if linePopover?.documentId != activeDocumentId {
            dismissLinePopover(clearSelection: false)
        }
        if lineEditPopover?.documentId != activeDocumentId {
            dismissLineQuickEdit(clearSelection: false)
        }
    }

    func clearTransientOverlays(forDocumentId documentId: UUID) {
        if selectionBar?.documentId == documentId {
            selectionBar = nil
            quickSaveMessage = nil
        }
        if wordPopover?.documentId == documentId {
            dismissWordPopover(clearSelection: false)
        }
        if linePopover?.documentId == documentId {
            dismissLinePopover(clearSelection: false)
        }
        if lineEditPopover?.documentId == documentId {
            dismissLineQuickEdit(clearSelection: false)
        }
    }

    // MARK: - 划词详情与本机离线查词

    func openWordStudy(from selection: LyricsWordSelection) {
        guard !isInvalidated else { return }
        dismissLinePopover(clearSelection: false)
        dismissLineQuickEdit(clearSelection: false)
        cancelWordRequests()
        selectionBar = nil
        quickSaveMessage = nil

        let localResult = studyService.lookupLocalWord(selection.surface, contextLine: selection.lineText)
        let formattedDictionary = LocalDictionaryFormatter.format(localResult)
        let prefilledGeneral = Self.prefillMeaning(from: localResult, formatted: formattedDictionary)
        wordPopover = WordPopoverState(
            id: UUID(),
            documentId: selection.documentId,
            documentRevision: selection.documentRevision,
            lineId: selection.lineId,
            lineText: selection.lineText,
            lineTranslation: selection.lineTranslation,
            startMs: selection.startMs,
            surface: selection.surface,
            utf16Location: selection.utf16Location,
            utf16Length: selection.utf16Length,
            anchorRectInScrollViewport: selection.anchorRectInScrollViewport,
            localResult: localResult,
            formattedDictionary: formattedDictionary,
            draftGeneralMeaning: prefilledGeneral
        )
    }

    func dismissWordPopover(clearSelection: Bool = true) {
        let hadPopover = wordPopover != nil
        cancelWordRequests()
        wordPopover = nil
        if clearSelection && hadPopover {
            clearSelectionForDismissedPopover()
        }
    }

    func clearSelectionForDismissedPopover() {
        selectionBar = nil
        quickSaveMessage = nil
        clearSelectionToken += 1
    }

    func requestAIWordExplanation() {
        guard !isInvalidated, var popover = wordPopover else { return }
        wordAITask?.cancel()
        wordRequestSequence += 1
        let expectedSequence = wordRequestSequence
        let targetPopoverId = popover.id
        let targetDocumentId = popover.documentId
        let targetLineId = popover.lineId
        let hints = trackHintProvider()

        popover.isLoadingAI = true
        popover.aiErrorMessage = nil
        wordPopover = popover

        let service = studyService
        wordAITask = Task { [weak self] in
            do {
                let explanation = try await service.explainWordWithAI(
                    surface: popover.surface,
                    lineText: popover.lineText,
                    lineTranslation: popover.lineTranslation,
                    songTitle: hints.title,
                    artist: hints.artist
                )
                guard !Task.isCancelled, let self, !self.isInvalidated,
                      self.wordRequestSequence == expectedSequence,
                      var current = self.wordPopover,
                      current.id == targetPopoverId,
                      current.documentId == targetDocumentId,
                      current.lineId == targetLineId else { return }
                current.isLoadingAI = false
                current.aiExplanation = explanation
                current.aiErrorMessage = nil
                if let aiGeneral = Self.nonEmpty(explanation.generalMeaning),
                   !current.hasEditedGeneralMeaning
                    || current.draftGeneralMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current.draftGeneralMeaning = aiGeneral
                }
                if let aiContextual = Self.nonEmpty(explanation.contextualMeaning),
                   !current.hasEditedContextualMeaning
                    || current.draftContextualMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current.draftContextualMeaning = aiContextual
                }
                self.wordPopover = current
            } catch is CancellationError {
                self?.finishCancelledWordAI(expectedSequence: expectedSequence, popoverId: targetPopoverId)
            } catch let error as AIStudyWorkflowError where error == .cancelled {
                self?.finishCancelledWordAI(expectedSequence: expectedSequence, popoverId: targetPopoverId)
            } catch {
                guard let self, !self.isInvalidated,
                      self.wordRequestSequence == expectedSequence,
                      var current = self.wordPopover,
                      current.id == targetPopoverId else { return }
                current.isLoadingAI = false
                current.aiErrorMessage = Self.describeError(error)
                self.wordPopover = current
            }
        }
    }

    func invalidate() {
        isInvalidated = true
        cancelWordRequests()
        cancelLineRequests()
        wordSaveSequence += 1
        lineSaveSequence += 1
        lineEditSaveSequence += 1
        wordSaveTask?.cancel()
        wordSaveTask = nil
        lineSaveTask?.cancel()
        lineSaveTask = nil
        lineEditSaveTask?.cancel()
        lineEditSaveTask = nil
        selectionBar = nil
        quickSaveMessage = nil
        wordPopover = nil
        linePopover = nil
        lineEditPopover = nil
        activeLineSourceDocument = nil
        activeLineProviderConfiguration = nil
        onVocabularyChanged = nil
        onDocumentNoteSaved = nil
    }

    private func cancelWordRequests() {
        wordRequestSequence += 1
        wordAITask?.cancel()
        wordAITask = nil
    }

    private func finishCancelledWordAI(expectedSequence: Int, popoverId: UUID) {
        guard !isInvalidated,
              wordRequestSequence == expectedSequence,
              var current = wordPopover,
              current.id == popoverId else { return }
        current.isLoadingAI = false
        wordPopover = current
    }
}
