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
        case importDraft(onApply: @MainActor ([AIStudyPreviewLine], AIStudyBatchTaskKind, String?) async -> Void)
        case editorDraft(onApply: @MainActor ([AIStudyPreviewLine], AIStudyBatchTaskKind, String?) async -> Void)
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
            case .translation: return "生成中文译文"
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
    @Published private(set) var generationStartedAt: Date?
    @Published var selectedTaskOption: TaskOption = .pronunciation
    @Published var selectedStyle: PronunciationStyle
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
            ?? (isMock ? MockPreviewAIStudyClient() : OpenAICompatibleClient(credentialStore: resolvedCredentials))
        self.onApplied = onApplied

        let storedConfig = settingsStore.load()
        self.selectedStyle = Self.selectablePronunciationStyles.contains(storedConfig.preferredPronunciationStyle)
            ? storedConfig.preferredPronunciationStyle
            : .romaji
        self.workflowService = AIStudyWorkflowService(
            store: store,
            aiClient: resolvedClient,
            configurationProvider: { settingsStore.load() },
            apiKeyProvider: {
                guard !isMock else { return nil }
                let config = settingsStore.load()
                return try? resolvedCredentials.apiKey(for: config.preset)
            }
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
        if case let .preview(lines) = phase { return lines }
        return []
    }

    var selectedCount: Int {
        previewLines.filter {
            $0.isSelected && !$0.generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    var manualProtectedCount: Int {
        previewLines.filter(\.existingIsManual).count
    }

    var canApply: Bool {
        if case .preview = phase {
            return selectedCount > 0
        }
        return false
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
            let key = try credentialStore.apiKey(for: config.preset)
            missingKeyWarning = key == nil
                ? "尚未配置「\(config.preset.displayName)」的 API Key，请前往「设置 → AI 学习服务」保存密钥。"
                : nil
        } catch {
            missingKeyWarning = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func generate() {
        refreshServiceStatus()
        guard nonEmptyLineCount > 0 else {
            errorMessage = AIStudyWorkflowError.emptyLyrics.message
            return
        }
        currentTask?.cancel()
        generation += 1
        let expectedGeneration = generation
        let taskKind = currentTaskKind
        let config = settingsStore.load()
        let rawModelName = isMock ? "mock-study" : config.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalLines = nonEmptyLineCount
        let batchSize = AIStudyWorkflowService.defaultBatchSize
        let totalBatches = max(1, (totalLines + batchSize - 1) / batchSize)
        activeBatchTask = taskKind
        activeModelName = rawModelName.isEmpty ? nil : rawModelName
        errorMessage = nil
        generationStartedAt = Date()
        phase = .generating(
            AIStudyBatchProgress(
                completedBatches: 0,
                totalBatches: totalBatches,
                completedLines: 0,
                totalLines: totalLines
            )
        )

        let service = workflowService
        let sourceDocument = document
        let title = songTitle
        let artistName = artist
        let onProgress: @Sendable (AIStudyBatchProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration,
                      case .generating = self.phase else { return }
                self.phase = .generating(progress)
            }
        }

        currentTask = Task { [weak self] in
            do {
                let items = try await service.generatePreview(
                    for: sourceDocument,
                    task: taskKind,
                    songTitle: title,
                    artist: artistName,
                    onProgress: onProgress
                )
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.generationStartedAt = nil
                self.phase = .preview(items)
            } catch is CancellationError {
                guard let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.generationStartedAt = nil
                self.phase = .idle
            } catch let error as AIStudyWorkflowError where error == .cancelled {
                guard let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.generationStartedAt = nil
                self.phase = .idle
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.currentTask = nil
                self.generationStartedAt = nil
                self.phase = .idle
                self.errorMessage = Self.describeError(error)
            }
        }
    }

    func cancelGeneration() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        generationStartedAt = nil
        if case .generating = phase {
            phase = .idle
        }
    }

    func resetToIdle() {
        cancelGeneration()
        generationStartedAt = nil
        errorMessage = nil
        phase = .idle
    }

    func invalidate() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        generationStartedAt = nil
        onApplied = nil
    }

    func applyPreview() {
        guard case let .preview(lines) = phase, let taskKind = activeBatchTask else { return }
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
                    await onApply(lines, taskKind, modelName)
                case let .editorDraft(onApply):
                    await onApply(lines, taskKind, modelName)
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

    private var currentTaskKind: AIStudyBatchTaskKind {
        switch selectedTaskOption {
        case .pronunciation:
            return .pronunciation(selectedStyle)
        case .translation:
            return .translation(targetLanguage: LyricsSyncConstants.translationLanguage)
        }
    }

    private static func describeError(_ error: Error) -> String {
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError.message
        }
        return ErrorText.describe(error)
    }
}

extension AIStudyPreviewModel {
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

    func invertSelection() {
        updateLines { lines in
            for index in lines.indices {
                let hasContent = !lines[index].generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                lines[index].isSelected = hasContent && !lines[index].isSelected
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
        guard case var .preview(lines) = phase else { return }
        mutate(&lines)
        phase = .preview(lines)
    }
}

/// 模拟模式下的本地示例生成器：绝不发送任何真实网络请求，不读取钥匙串。
private final class MockPreviewAIStudyClient: AIStudyProviding, Sendable {
    func testConnection(
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(latencyMs: 1, model: "mock-study", replyPreview: "连接正常")
    }

    func explainWord(
        _ word: String,
        inLine lineText: String,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AIWordExplanation {
        AIWordExplanation(surface: word, lemma: word, contextualMeaning: "模拟语境释义", generalMeaning: "模拟通用释义")
    }

    func explainLine(
        _ lineText: String,
        context: AILineContext,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> AILineExplanation {
        AILineExplanation(grammarSummary: "模拟句法要点")
    }

    func generatePronunciations(
        for lines: [LyricLine],
        style: PronunciationStyle,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIPronunciationLineItem] {
        try await Task.sleep(for: .milliseconds(120))
        return lines.map { line in
            AIPronunciationLineItem(
                lineId: line.id,
                pronunciation: "[模拟\(style.displayName)] \(line.text)"
            )
        }
    }

    func generateTranslations(
        for lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AITranslationLineItem] {
        try await Task.sleep(for: .milliseconds(120))
        return lines.map { line in
            AITranslationLineItem(
                lineId: line.id,
                translation: "[模拟译文] \(line.text)"
            )
        }
    }

    func extractKeyStudyPoints(
        from lines: [LyricLine],
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [AIKeyStudyPoint] {
        []
    }
}
