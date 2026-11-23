import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

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

    /// 用户显式触发的 AI 整句解析：按稳定 `lineId` 提取目标行与前后非空邻行组成 `AILineContext`。
    public func explainLineWithAI(
        document: LyricDocument,
        lineId: UUID,
        songTitle: String?,
        artist: String?
    ) async throws -> AILineExplanation {
        _ = (songTitle, artist)
        if Task.isCancelled {
            throw AIStudyWorkflowError.cancelled
        }

        guard let targetIndex = document.lines.firstIndex(where: { $0.id == lineId }) else {
            throw AIStudyWorkflowError.editingError(.lineNotFound(lineId: lineId))
        }

        let targetLine = document.lines[targetIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetLine.isEmpty else {
            throw AIStudyWorkflowError.providerError(.invalidConfiguration("待解析歌词行不能为空。"))
        }

        let context = AILineContext(
            previousLine: Self.nearestNonEmptyLine(in: document.lines, before: targetIndex),
            nextLine: Self.nearestNonEmptyLine(in: document.lines, after: targetIndex),
            sourceLanguage: Self.normalizedNonEmpty(document.sourceLanguage)
        )
        let configuration = configurationProvider()
        let apiKey = apiKeyProvider()

        do {
            let result = try await aiClient.explainLine(
                targetLine,
                context: context,
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
