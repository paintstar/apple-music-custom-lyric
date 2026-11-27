import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit
import ShinAppServices

/// AI 一键注音 / 译文预览状态机：支持歌词面板直接提交、导入预览草稿与编辑器草稿三种模式。
@MainActor
final class AIStudyPreviewModel: ObservableObject {

    enum CommitTarget {
        case storedDocument(documentId: UUID, expectedRevision: Int)
        case importDraft(onApply: @MainActor ([AIStudyPreviewLine], AIStudyBatchTaskKind, String?) async throws -> Void)
        case editorDraft(onApply: @MainActor ([AIStudyPreviewLine], AIStudyBatchTaskKind, String?) async throws -> Void)
    }

    enum Phase: Equatable {
        case idle
        case generating(AIStudyBatchProgress)
        case preview([AIStudyPreviewLine])
        case applying
    }

    enum TaskOption: String, CaseIterable, Identifiable {
        case pronunciation
        case translation

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .pronunciation: return "生成逐行注音"
            case .translation: return "生成译文"
            }
        }
    }

    static let selectablePronunciationStyles: [PronunciationStyle] = [
        .romaji,
        .furigana,
        .ipa,
        .hangulRomanization
    ]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var generationSelection: Set<UUID> = []
    @Published private(set) var generationStartedAt: Date?
    @Published var selectedTaskOption: TaskOption = .pronunciation
    @Published var selectedStyle: PronunciationStyle
    @Published var selectedTargetLanguage: String
    let selectableTargetLanguages: [String]
    @Published private(set) var errorMessage: String?
    @Published private(set) var configuredServiceSummary = ""
    @Published private(set) var missingKeyWarning: String?

    let document: LyricDocument
    let songTitle: String?
    let artist: String?
    let isMock: Bool

    private let workflowService: AIStudyWorkflowService
    private let commitTarget: CommitTarget
    private let settingsStore: AIServiceSettingsStore
    private let credentialStore: any AICredentialStoring
    private var onApplied: (() -> Void)?
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    private var activeBatchTask: AIStudyBatchTaskKind?
    private var activeModelName: String?
    private var activeConfiguration: AIConfiguration?
    private var workingPreviews: [AIStudyBatchTaskKind: [AIStudyPreviewLine]] = [:]
    private var refreshRun: (lineIDs: Set<UUID>, cache: AIStudyPreviewCache)?

    init(
        store: GRDBLyricsStore,
        document: LyricDocument,
        songTitle: String?,
        artist: String?,
        commitTarget: CommitTarget,
        isMock: Bool,
        aiClient: (any AIStudyProviding)? = nil,
        settingsStore: AIServiceSettingsStore = AIServiceSettingsStore(),
        credentialStore: (any AICredentialStoring)? = nil,
        draftCache: AIStudyPreviewCache? = nil,
        onApplied: (() -> Void)? = nil
    ) {
        self.document = document
        self.songTitle = songTitle
        self.artist = artist
        self.commitTarget = commitTarget
        self.isMock = isMock
        self.settingsStore = settingsStore
        let resolvedCredentials: any AICredentialStoring = credentialStore
            ?? (isMock ? InMemoryAICredentialStore() : SystemKeychainCredentialStore())
        self.credentialStore = resolvedCredentials
        let resolvedClient: any AIStudyProviding = aiClient
            ?? (isMock ? MockPreviewAIStudyClient() : OpenAICompatibleClient())
        self.onApplied = onApplied

        let storedConfig = settingsStore.load()
        let preferredLanguage = storedConfig.preferredTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentLanguage = preferredLanguage.isEmpty ? LyricsSyncConstants.translationLanguage : preferredLanguage
        self.selectedTargetLanguage = currentLanguage
        let standardLanguages = [LyricsSyncConstants.translationLanguage, "zh-Hant", "en", "ja", "ko"]
        self.selectableTargetLanguages = standardLanguages.contains(currentLanguage)
            ? standardLanguages
            : standardLanguages + [currentLanguage]
        self.selectedStyle = Self.selectablePronunciationStyles.contains(storedConfig.preferredPronunciationStyle)
            ? storedConfig.preferredPronunciationStyle
            : .romaji
        self.workflowService = AIStudyWorkflowService(
            store: store,
            aiClient: resolvedClient,
            configurationProvider: { isMock ? AIConfiguration(modelName: "mock-study") : settingsStore.load() },
            configuredAPIKeyProvider: { preset in
                guard !isMock else { return nil }
                return try resolvedCredentials.apiKey(for: preset)
            },
            draftCache: draftCache
        )
        refreshServiceStatus()
    }

    var nonEmptyLineCount: Int {
        document.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }

    var isApplying: Bool {
        if case .applying = phase { return true }
        return false
    }

    var previewLines: [AIStudyPreviewLine] {
        if case let .preview(lines) = phase, activeBatchTask == currentTaskKind { return lines }
        return AIStudyWorkflowService.localPreview(for: document, task: currentTaskKind)
    }

    var selectedCount: Int {
        previewLines.filter {
            $0.isSelected && !$0.generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    var manualProtectedCount: Int {
        previewLines.filter(\.existingIsManual).count
    }

    var canApply: Bool { isPreviewReady && selectedCount > 0 }
    var canFillMissing: Bool {
        isPreviewReady && !AIStudyWorkflowService.missingLineIDs(for: document, task: currentTaskKind).isEmpty
    }

    var canRegenerate: Bool { isPreviewReady && !generationSelection.isEmpty }

    private var isPreviewReady: Bool {
        guard case .preview = phase else { return false }
        return activeBatchTask == currentTaskKind
    }

    func refreshServiceStatus() {
        if isMock {
            configuredServiceSummary = "模拟模式 · 本地示例生成（不发送网络请求）"
            missingKeyWarning = nil
            return
        }
        let config = settingsStore.load()
        let trimmedModel = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        configuredServiceSummary = "\(config.preset.displayName) · \(trimmedModel.isEmpty ? "未填写模型" : trimmedModel)"
        guard config.preset.requiresAPIKey else {
            missingKeyWarning = nil
            return
        }
        do {
            missingKeyWarning = try credentialStore.hasAPIKey(for: config.preset)
                ? nil
                : "尚未配置「\(config.preset.displayName)」的 API Key，请前往「设置 → AI 学习服务」保存密钥。"
        } catch {
            missingKeyWarning = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func invalidate() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        generationStartedAt = nil
        onApplied = nil
    }

    func applyPreview() {
        guard canApply, case let .preview(lines) = phase, let taskKind = activeBatchTask else { return }
        guard activeConfiguration == settingsStore.load() else {
            openTaskPreview()
            return
        }
        generation += 1
        let expectedGeneration = generation
        let modelName = activeModelName
        phase = .applying
        errorMessage = nil

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch self.commitTarget {
                case let .storedDocument(documentId, expectedRevision):
                    _ = try await self.workflowService.applyPreviewToStore(
                        documentId: documentId,
                        expectedRevision: expectedRevision,
                        task: taskKind,
                        modelName: modelName,
                        items: lines
                    )
                case let .importDraft(onApply):
                    try await onApply(lines, taskKind, modelName)
                case let .editorDraft(onApply):
                    try await onApply(lines, taskKind, modelName)
                }
                guard self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.onApplied?()
            } catch {
                guard self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.phase = .preview(lines)
                self.errorMessage = Self.describeError(error)
            }
        }
    }

    var currentTaskKind: AIStudyBatchTaskKind {
        switch selectedTaskOption {
        case .pronunciation:
            return .pronunciation(selectedStyle)
        case .translation:
            return .translation(targetLanguage: selectedTargetLanguage)
        }
    }

    private func requestConfiguration(_ snapshot: AIConfiguration) -> AIConfiguration {
        isMock ? AIConfiguration(modelName: "mock-study") : snapshot
    }

    private static func describeError(_ error: Error) -> String {
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError.message
        }
        return ErrorText.describe(error)
    }
}

extension AIStudyPreviewModel {
    func openTaskPreview() {
        if let activeBatchTask, case let .preview(oldLines) = phase {
            workingPreviews[activeBatchTask] = oldLines
        }
        generationSelection = []
        refreshRun = nil
        errorMessage = nil
        loadLocalPreview()
    }

    private func loadLocalPreview() {
        currentTask?.cancel()
        generation += 1
        let expectedGeneration = generation
        let taskKind = currentTaskKind
        let configuration = settingsStore.load()
        if activeConfiguration != configuration {
            workingPreviews.removeAll()
            refreshRun = nil
        }
        activeConfiguration = configuration
        activeBatchTask = taskKind
        let rawModelName = isMock ? "mock-study" : configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        activeModelName = rawModelName.isEmpty ? nil : rawModelName
        generationStartedAt = nil
        phase = .idle

        currentTask = Task { [weak self] in
            guard let self else { return }
            let local = AIStudyWorkflowService.localPreview(for: self.document, task: taskKind)
            let requestConfiguration = self.requestConfiguration(configuration)
            let cached = (try? await self.workflowService.cachedPreview(
                for: self.document, task: taskKind, configuration: requestConfiguration
            )) ?? local
            guard !Task.isCancelled, self.generation == expectedGeneration,
                  self.currentTaskKind == taskKind else { return }

            var lines = self.workingPreviews[taskKind] ?? cached
            lines = Self.combining(lines, with: cached, replacing: [])
            if let refresh = self.refreshRun {
                let request = AIStudyBatchRequest.regenerate(lineIds: refresh.lineIDs, completedBatches: refresh.cache)
                if let refreshed = try? await self.workflowService.cachedPreview(
                    for: self.document, task: taskKind, request: request, configuration: requestConfiguration
                ) {
                    let updatedIDs = Set(refreshed.filter { !$0.generatedText.isEmpty }.map(\.lineId))
                    lines = Self.combining(lines, with: refreshed, replacing: updatedIDs)
                }
            }
            guard !Task.isCancelled, self.generation == expectedGeneration,
                  self.currentTaskKind == taskKind else { return }
            self.currentTask = nil
            self.phase = .preview(lines)
        }
    }

    func setGenerationSelected(_ selected: Bool, for lineId: UUID) {
        guard isPreviewReady else { return }
        if selected {
            generationSelection.insert(lineId)
        } else {
            generationSelection.remove(lineId)
        }
        if refreshRun?.lineIDs != generationSelection {
            refreshRun = nil
        }
    }

    func generate(replacingSelected: Bool = false) {
        guard replacingSelected ? canRegenerate : canFillMissing else { return }
        refreshServiceStatus()
        let configuration = settingsStore.load()
        guard activeConfiguration == configuration else {
            openTaskPreview()
            return
        }

        let previous = previewLines
        let taskKind = currentTaskKind
        let requestedIDs: Set<UUID>
        let request: AIStudyBatchRequest
        if replacingSelected {
            let selected = generationSelection
            let cache = refreshRun?.cache ?? AIStudyPreviewCache()
            refreshRun = (selected, cache)
            requestedIDs = selected
            request = .regenerate(lineIds: selected, completedBatches: cache)
        } else {
            request = .fillMissing
            requestedIDs = AIStudyWorkflowService.missingLineIDs(for: document, task: taskKind)
        }

        currentTask?.cancel()
        generation += 1
        let expectedGeneration = generation
        workingPreviews[taskKind] = previous
        errorMessage = nil
        generationStartedAt = Date()
        phase = .generating(AIStudyBatchProgress(
            completedBatches: 0, totalBatches: 0, completedLines: 0, totalLines: requestedIDs.count
        ))

        let onProgress: @Sendable (AIStudyBatchProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration,
                      case let .generating(activeProgress) = self.phase,
                      progress.completedBatches >= activeProgress.completedBatches else { return }
                self.phase = .generating(progress)
            }
        }

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await self.workflowService.generatePreview(
                    for: self.document, task: taskKind, request: request,
                    configuration: self.requestConfiguration(configuration), onProgress: onProgress
                )
                guard !Task.isCancelled, self.generation == expectedGeneration,
                      self.currentTaskKind == taskKind else { return }
                self.finishGeneration(
                    items, previous: previous, requestedIDs: requestedIDs, replacingSelected: replacingSelected
                )
            } catch {
                guard self.generation == expectedGeneration, self.currentTaskKind == taskKind else { return }
                if !Task.isCancelled, (error as? AIStudyWorkflowError) != .cancelled {
                    self.errorMessage = Self.describeError(error)
                }
                self.loadLocalPreview()
            }
        }
    }

    private func finishGeneration(
        _ items: [AIStudyPreviewLine], previous: [AIStudyPreviewLine],
        requestedIDs: Set<UUID>, replacingSelected: Bool
    ) {
        currentTask = nil
        generationStartedAt = nil
        phase = .preview(Self.combining(previous, with: items, replacing: replacingSelected ? requestedIDs : []))
        let availableIDs = Set(items.filter { !$0.generatedText.isEmpty }.map(\.lineId))
        guard requestedIDs.isSubset(of: availableIDs) else {
            errorMessage = "部分行未返回有效结果，可重试未完成的批次。"
            return
        }
        if replacingSelected {
            generationSelection = []
            refreshRun = nil
        }
    }

    func cancelGeneration() {
        guard isGenerating else { return }
        errorMessage = nil
        loadLocalPreview()
    }

    private static func combining(
        _ previous: [AIStudyPreviewLine], with incoming: [AIStudyPreviewLine], replacing: Set<UUID>
    ) -> [AIStudyPreviewLine] {
        let indexed = Dictionary(previous.map { ($0.lineId, $0) }, uniquingKeysWith: { first, _ in first })
        return incoming.map { new in
            guard let old = indexed[new.lineId], !replacing.contains(new.lineId) else { return new }
            return old.generatedText.isEmpty ? new : old
        }
    }

    func setSelected(_ selected: Bool, for lineId: UUID) {
        updateLines { lines in
            guard let index = lines.firstIndex(where: { $0.lineId == lineId }) else { return }
            let hasContent = !lines[index].generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lines[index].isSelected = selected && hasContent
        }
    }

    func setGeneratedText(_ text: String, for lineId: UUID) {
        updateLines { lines in
            guard let index = lines.firstIndex(where: { $0.lineId == lineId }) else { return }
            lines[index].generatedText = text
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines[index].isSelected = false
            }
        }
    }

    func selectAllNonManual() {
        updateLines { lines in
            for index in lines.indices {
                let hasContent = !lines[index].generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                lines[index].isSelected = hasContent && !lines[index].existingIsManual
            }
        }
    }

    func deselectAll() {
        updateLines { lines in
            for index in lines.indices {
                lines[index].isSelected = false
            }
        }
    }

    private func updateLines(_ mutate: (inout [AIStudyPreviewLine]) -> Void) {
        guard isPreviewReady, case var .preview(lines) = phase else { return }
        mutate(&lines)
        phase = .preview(lines)
    }
}
