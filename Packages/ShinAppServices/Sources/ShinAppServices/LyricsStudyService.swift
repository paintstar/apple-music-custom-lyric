import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

/// 整句解析与追问实际提交的歌词文本。
public struct AILineInput: Equatable, Sendable {
    public let text: String
    public let context: AILineContext
}

/// 歌词学习协同服务：封装本机离线查词、AI 划词/整句解析、生词本入库与整句笔记持久化。
/// 全部 AI 解析由用户显式操作触发，不随切歌自动调用，也不静默覆盖人工成果。
public struct LyricsStudyService: Sendable {
    private let store: GRDBLyricsStore
    private let localDictionary: any LocalDictionaryLookupProviding
    private let aiClient: any AIStudyProviding
    private let configurationProvider: @Sendable () -> AIConfiguration
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        store: GRDBLyricsStore,
        localDictionary: any LocalDictionaryLookupProviding = LocalDictionaryService(),
        aiClient: any AIStudyProviding,
        configurationProvider: @escaping @Sendable () -> AIConfiguration,
        apiKeyProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.store = store
        self.localDictionary = localDictionary
        self.aiClient = aiClient
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
    }

    /// 本地词典快速查词（纯本机零网络）。
    public func lookupLocalWord(
        _ query: String,
        contextLine: String? = nil
    ) -> LocalDictionaryLookupResult {
        localDictionary.lookup(query, contextLine: contextLine)
    }

    /// 用户显式触发的 AI 划词深度解析；映射 `AIProviderError` 与 `CancellationError` 为 `AIStudyWorkflowError`。
    public func explainWordWithAI(
        surface: String,
        lineText: String,
        lineTranslation: String?,
        songTitle: String?,
        artist: String?
    ) async throws -> AIWordExplanation {
        if Task.isCancelled {
            throw AIStudyWorkflowError.cancelled
        }

        let cleanSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSurface.isEmpty else {
            throw AIStudyWorkflowError.providerError(.invalidConfiguration("查询词语不能为空。"))
        }

        let cleanLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        let localLookup = localDictionary.lookup(
            cleanSurface,
            contextLine: cleanLine.isEmpty ? nil : cleanLine
        )
        let contextualLine = Self.buildWordContextLine(
            lineText: cleanLine,
            lineTranslation: lineTranslation,
            songTitle: songTitle,
            artist: artist
        )
        let configuration = configurationProvider()
        let apiKey = apiKeyProvider()

        do {
            let result = try await aiClient.explainWord(
                cleanSurface,
                inLine: contextualLine,
                sourceLanguage: localLookup.detectedLanguage,
                configuration: configuration,
                apiKey: apiKey
            )
            if Task.isCancelled {
                throw AIStudyWorkflowError.cancelled
            }
            return result
        } catch {
            throw Self.mapAIError(error)
        }
    }

    /// 打开整句解析时优先复用相同的本地结果。主动重新解析可跳过读取缓存。
    public func explainLineWithAI(
        document: LyricDocument,
        lineId: UUID,
        songTitle: String? = nil,
        artist: String? = nil,
        useCache: Bool = true,
        configuration: AIConfiguration? = nil
    ) async throws -> AILineExplanation {
        _ = (songTitle, artist)
        do {
            try Task.checkCancellation()
            let input = try Self.requiredLineInput(document: document, lineId: lineId)
            let configuration = configuration ?? configurationProvider()
            let cacheKey = Self.lineExplanationCacheKey(lineId: lineId, input: input, configuration: configuration)

            if useCache, let cached = await cachedLineExplanation(documentId: document.id, key: cacheKey) {
                try Task.checkCancellation()
                return cached
            }
            let cacheGeneration = try? await store.aiStudyCacheGeneration()
            try Task.checkCancellation()
            let explanation = try await aiClient.explainLine(
                input.text,
                context: input.context,
                configuration: configuration,
                apiKey: apiKeyProvider()
            )
            try Task.checkCancellation()
            guard Self.normalizedNonEmpty(explanation.grammarSummary) != nil else {
                throw AIProviderError.emptyResult("句法解析结果缺少总结内容。")
            }
            if let cacheGeneration, let payload = try? JSONEncoder().encode(explanation) {
                try? await store.saveAIStudyCachePayload(
                    payload, documentID: document.id, key: cacheKey, generation: cacheGeneration
                )
            }
            try Task.checkCancellation()
            return explanation
        } catch {
            throw Self.mapAIError(error)
        }
    }

    /// 只把歌词上下文、原始 AI 解析及少量追问记录发给配置的服务。
    public func followUpLineWithAI(
        document: LyricDocument,
        lineId: UUID,
        analysis: AILineExplanation?,
        history: [AILineFollowUpTurn],
        question: String,
        configuration: AIConfiguration? = nil
    ) async throws -> String {
        do {
            let input = try Self.requiredLineInput(document: document, lineId: lineId)
            guard let question = Self.normalizedNonEmpty(question) else {
                throw AIProviderError.invalidConfiguration("追问不能为空。")
            }
            try await checkLineContext(documentId: document.id, lineId: lineId, expected: input)
            let configuration = configuration ?? configurationProvider()
            var aiAnalysis = analysis
            if aiAnalysis == nil {
                let key = Self.lineExplanationCacheKey(lineId: lineId, input: input, configuration: configuration)
                aiAnalysis = await cachedLineExplanation(documentId: document.id, key: key)
            }
            try Task.checkCancellation()
            let answer = try await aiClient.followUpLine(
                AILineFollowUpRequest(
                    lineText: input.text,
                    context: input.context,
                    analysis: aiAnalysis,
                    history: Array(history.suffix(3)),
                    question: question
                ),
                configuration: configuration,
                apiKey: apiKeyProvider()
            )
            try await checkLineContext(documentId: document.id, lineId: lineId, expected: input)
            guard let cleanedAnswer = Self.normalizedNonEmpty(answer) else {
                throw AIProviderError.emptyResult("整句追问缺少回答。")
            }
            return cleanedAnswer
        } catch {
            throw Self.mapAIError(error)
        }
    }

    public static func lineInput(document: LyricDocument, lineId: UUID) -> AILineInput? {
        guard let index = document.lines.firstIndex(where: { $0.id == lineId }),
              let targetLine = normalizedNonEmpty(document.lines[index].text) else { return nil }
        return AILineInput(
            text: targetLine,
            context: AILineContext(
                previousLine: nearestNonEmptyLine(in: document.lines, before: index),
                nextLine: nearestNonEmptyLine(in: document.lines, after: index),
                sourceLanguage: normalizedNonEmpty(document.sourceLanguage)
            )
        )
    }

    private static func requiredLineInput(document: LyricDocument, lineId: UUID) throws -> AILineInput {
        if let input = lineInput(document: document, lineId: lineId) { return input }
        guard document.lines.contains(where: { $0.id == lineId }) else {
            throw AIStudyWorkflowError.editingError(.lineNotFound(lineId: lineId))
        }
        throw AIProviderError.invalidConfiguration("待解析歌词行不能为空。")
    }

    private static func lineExplanationCacheKey(
        lineId: UUID, input: AILineInput, configuration: AIConfiguration
    ) -> String {
        AIStudyCacheKey.make(task: "line-explanation", configuration: configuration, inputs: [
            lineId.uuidString,
            input.text,
            input.context.sourceLanguage ?? "",
            input.context.previousLine ?? "",
            input.context.nextLine ?? "",
            configuration.preferredTargetLanguage
        ])
    }

    private func cachedLineExplanation(documentId: UUID, key: String) async -> AILineExplanation? {
        guard let payload = try? await store.aiStudyCachePayload(documentID: documentId, key: key),
              let explanation = try? JSONDecoder().decode(AILineExplanation.self, from: payload),
              Self.normalizedNonEmpty(explanation.grammarSummary) != nil else { return nil }
        return explanation
    }

    private func checkLineContext(documentId: UUID, lineId: UUID, expected: AILineInput) async throws {
        try Task.checkCancellation()
        guard let current = try await store.document(id: documentId),
              Self.lineInput(document: current, lineId: lineId) == expected else {
            throw AIStudyWorkflowError.cancelled
        }
        try Task.checkCancellation()
    }

    /// 保存生词词条及原声出处快照；同一词条不同位置自动归并去重。
    public func saveWord(
        entry: VocabularyEntry,
        occurrence: VocabularyOccurrence? = nil
    ) async throws -> VocabularyEntry {
        do {
            return try await store.saveVocabulary(entry: entry, occurrence: occurrence)
        } catch {
            throw Self.mapStoreError(error)
        }
    }

    /// 乐观并发保存整句学习笔记到指定歌词行：
    /// 核对 `expectedRevision`，写入 `studyNote` 并确保 `needsReview = false`，
    /// 递增 `revision` 并经 `save`（有绑定）或 `updateDocument`（无绑定）原子提交。
    public func saveLineStudyNote(
        documentId: UUID,
        expectedRevision: Int,
        lineId: UUID,
        note: LineStudyNote
    ) async throws -> LyricDocument {
        let loaded: LyricDocument
        do {
            guard let existing = try await store.document(id: documentId) else {
                throw AIStudyWorkflowError.documentNotFound(documentId)
            }
            loaded = existing
        } catch {
            throw Self.mapStoreError(error, expectedRevision: expectedRevision)
        }

        guard loaded.revision == expectedRevision else {
            throw AIStudyWorkflowError.revisionConflict(
                documentId: documentId,
                storedRevision: loaded.revision,
                expectedRevision: expectedRevision
            )
        }

        guard let targetIndex = loaded.lines.firstIndex(where: { $0.id == lineId }) else {
            throw AIStudyWorkflowError.editingError(.lineNotFound(lineId: lineId))
        }

        var normalizedNote = note
        normalizedNote.needsReview = false

        var submit = loaded
        submit.lines[targetIndex].studyNote = normalizedNote
        submit.revision = loaded.revision + 1
        submit.updatedAt = LyricTimestamp.now()

        do {
            let bindings = try await store.bindings(referencing: loaded.id)
            if let anchor = bindings.first {
                try await store.save(document: submit, binding: anchor)
            } else {
                try await store.updateDocument(submit)
            }
            return submit
        } catch {
            throw Self.mapStoreError(error, expectedRevision: expectedRevision)
        }
    }
}

// MARK: - 内部助手

private extension LyricsStudyService {

    static func buildWordContextLine(
        lineText: String,
        lineTranslation: String?,
        songTitle: String?,
        artist: String?
    ) -> String {
        var parts: [String] = []
        if !lineText.isEmpty {
            parts.append(lineText)
        }
        if let translation = normalizedNonEmpty(lineTranslation) {
            parts.append("参考译文：\(translation)")
        }
        let trackContext = [normalizedNonEmpty(songTitle), normalizedNonEmpty(artist)]
            .compactMap { $0 }
            .joined(separator: " - ")
        if !trackContext.isEmpty {
            parts.append("曲目：\(trackContext)")
        }
        return parts.joined(separator: "\n")
    }

    static func nearestNonEmptyLine(in lines: [LyricLine], before index: Int) -> String? {
        guard index > 0 else { return nil }
        for idx in stride(from: index - 1, through: 0, by: -1) {
            if let text = normalizedNonEmpty(lines[idx].text) {
                return text
            }
        }
        return nil
    }

    static func nearestNonEmptyLine(in lines: [LyricLine], after index: Int) -> String? {
        guard index + 1 < lines.count else { return nil }
        for idx in (index + 1)..<lines.count {
            if let text = normalizedNonEmpty(lines[idx].text) {
                return text
            }
        }
        return nil
    }

    static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func mapAIError(_ error: Error) -> AIStudyWorkflowError {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError
        }
        if let providerError = error as? AIProviderError {
            return .providerError(providerError)
        }
        return .unexpected(String(describing: error))
    }

    static func mapStoreError(
        _ error: Error,
        expectedRevision: Int? = nil
    ) -> AIStudyWorkflowError {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError
        }
        if let dataError = error as? ShinAppleDataError {
            switch dataError {
            case let .revisionConflict(documentId, storedRevision, submittedRevision):
                return .revisionConflict(
                    documentId: documentId,
                    storedRevision: storedRevision,
                    expectedRevision: expectedRevision ?? submittedRevision
                )
            case let .documentNotFound(id):
                return .documentNotFound(id)
            default:
                return .dataError(dataError)
            }
        }
        return .unexpected(String(describing: error))
    }
}
