import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

// MARK: - AI 学习批处理工作流服务

/// 编排批量 AI 注音/译文生成、预览对齐与原子写库。
/// 全程按稳定 `LyricLine.id` 对齐，不依赖数组下标，并保护人工成果（`.manual` 默认不勾选覆盖）。
public actor AIStudyWorkflowService {
    /// 默认每批处理歌词行数：缩小单批体积以降低思考模型超时风险并提供更细粒度的进度反馈。
    public static let defaultBatchSize = 10

    let store: GRDBLyricsStore
    let aiClient: any AIStudyProviding
    let configurationProvider: @Sendable () -> AIConfiguration
    private let apiKeyProvider: @Sendable () -> String?
    private let configuredAPIKeyProvider: (@Sendable (AIProviderPreset) throws -> String?)?
    let draftCache: AIStudyPreviewCache?

    public init(
        store: GRDBLyricsStore,
        aiClient: any AIStudyProviding,
        configurationProvider: @escaping @Sendable () -> AIConfiguration,
        apiKeyProvider: @escaping @Sendable () -> String? = { nil },
        configuredAPIKeyProvider: (@Sendable (AIProviderPreset) throws -> String?)? = nil,
        draftCache: AIStudyPreviewCache? = nil
    ) {
        self.store = store
        self.aiClient = aiClient
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
        self.configuredAPIKeyProvider = configuredAPIKeyProvider
        self.draftCache = draftCache
    }

    /// 读取已有内容和匹配的完整批次。打开预览时只访问本地缓存。
    public func cachedPreview(
        for document: LyricDocument,
        task: AIStudyBatchTaskKind,
        request: AIStudyBatchRequest = .fillMissing,
        batchSize: Int = AIStudyWorkflowService.defaultBatchSize,
        configuration: AIConfiguration? = nil
    ) async throws -> [AIStudyPreviewLine] {
        let options = PreviewOptions(task: task, request: request, batchSize: batchSize, configuration: configuration)
        return try await preview(for: document, options: options, allowNetwork: false, onProgress: nil)
    }

    /// 每批完成后独立缓存。失败或取消前已验证的批次可以在重试时恢复。
    public func generatePreview(
        for document: LyricDocument,
        task: AIStudyBatchTaskKind,
        songTitle: String? = nil,
        artist: String? = nil,
        batchSize: Int = AIStudyWorkflowService.defaultBatchSize,
        request: AIStudyBatchRequest = .fillMissing,
        configuration: AIConfiguration? = nil,
        onProgress: (@Sendable (AIStudyBatchProgress) -> Void)? = nil
    ) async throws -> [AIStudyPreviewLine] {
        let options = PreviewOptions(task: task, request: request, batchSize: batchSize, configuration: configuration)
        return try await preview(for: document, options: options, allowNetwork: true, onProgress: onProgress)
    }

    public static func localPreview(
        for document: LyricDocument, task: AIStudyBatchTaskKind
    ) -> [AIStudyPreviewLine] {
        buildPreviewLines(from: nonEmptyLines(in: document), task: task, generatedByLineId: [:])
    }

    public static func missingLineIDs(
        for document: LyricDocument, task: AIStudyBatchTaskKind
    ) -> Set<UUID> {
        Set(nonEmptyLines(in: document).filter { line in
            switch task {
            case .pronunciation:
                return normalizedNonEmpty(line.pronunciation?.text) == nil
            case .translation(let targetLanguage):
                let language = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalizedNonEmpty(line.translations[language]?.text) == nil
            }
        }.map(\.id))
    }

    private struct PreviewOptions {
        let task: AIStudyBatchTaskKind
        let request: AIStudyBatchRequest
        let batchSize: Int
        let configuration: AIConfiguration?
    }

    private func preview(
        for document: LyricDocument,
        options: PreviewOptions,
        allowNetwork: Bool,
        onProgress: (@Sendable (AIStudyBatchProgress) -> Void)?
    ) async throws -> [AIStudyPreviewLine] {
        try Self.checkCancellation()
        let task = options.task
        let configuration = try resolvedConfiguration(for: task, startingWith: options.configuration)
        let cacheContext = AIStudyBatchCacheContext(
            documentID: document.id, sourceLanguage: document.sourceLanguage, task: task, configuration: configuration
        )
        let lines = Self.nonEmptyLines(in: document)
        if allowNetwork && lines.isEmpty { throw AIStudyWorkflowError.emptyLyrics }

        let requestedIDs: Set<UUID>
        let refreshCache: AIStudyPreviewCache?
        switch options.request {
        case .fillMissing:
            requestedIDs = Self.missingLineIDs(for: document, task: task)
            refreshCache = nil
        case let .regenerate(lineIds, completedBatches):
            requestedIDs = lineIds
            refreshCache = completedBatches
        }

        // 先分批再筛选。已有条目或局部编辑不会让后续批次的输入整体移动。
        let batches = Self.chunked(lines, size: max(1, options.batchSize))
            .map { group in (group: group, requested: group.filter { requestedIDs.contains($0.id) }) }
            .filter { !$0.requested.isEmpty }
        let totalLines = batches.reduce(0) { $0 + $1.requested.count }
        var generatedByLineID: [UUID: String] = [:]
        var completedLines = 0
        var apiKey: String?
        var loadedAPIKey = false
        var cacheGeneration: UUID?

        onProgress?(AIStudyBatchProgress(
            completedBatches: 0, totalBatches: batches.count,
            completedLines: 0, totalLines: totalLines
        ))

        for (index, plan) in batches.enumerated() {
            try Self.checkCancellation()
            let batch = plan.requested
            let key = cacheContext.key(for: batch)
            let ids = Set(batch.map(\.id))
            let projectionKey = cacheContext.key(for: plan.group, isProjectionIndex: true)
            let exact = await cachedBatch(for: ids, key: key, documentID: document.id, from: refreshCache)
            var batchResult = exact ?? [:]
            if refreshCache == nil {
                let projected = await projectedResults(
                    for: ids, from: plan.group, key: projectionKey, exact: exact, context: cacheContext
                )
                batchResult.merge(projected) { _, newer in newer }
            }

            if allowNetwork, batchResult.count < batch.count {
                try Self.checkCancellation()
                if !loadedAPIKey {
                    apiKey = try resolveAPIKey(for: configuration.preset)
                    // 同一次生成的所有批次共用代次，清空后后续批次也不会写回。
                    cacheGeneration = try? await store.aiStudyCacheGeneration()
                    loadedAPIKey = true
                }
                let missing = batch.filter { batchResult[$0.id] == nil }
                let inputIDs = Set(missing.map(\.id))
                try Self.checkCancellation()
                let pairs = try await fetchBatch(
                    batch: missing, task: task, sourceLanguage: document.sourceLanguage,
                    configuration: configuration, apiKey: apiKey
                )
                try Self.checkCancellation()
                let validated = Self.validatedItems(pairs, for: inputIDs)
                if validated.count == missing.count,
                   let payload = try? JSONEncoder().encode(validated) {
                    let resultKey = cacheContext.key(for: missing)
                    await refreshCache?.save(payload, for: resultKey)
                    await saveBatch(
                        payload, inputIDs: inputIDs, keys: (resultKey, projectionKey), documentID: document.id, generation: cacheGeneration
                    )
                }
                batchResult.merge(validated) { _, newer in newer }
            }
            generatedByLineID.merge(batchResult) { _, new in new }
            completedLines += batch.count
            onProgress?(AIStudyBatchProgress(
                completedBatches: index + 1, totalBatches: batches.count,
                completedLines: completedLines, totalLines: totalLines
            ))
        }
        try Self.checkCancellation()
        return Self.buildPreviewLines(from: lines, task: task, generatedByLineId: generatedByLineID)
    }

    static func checkCancellation() throws {
        if Task.isCancelled { throw AIStudyWorkflowError.cancelled }
    }

    func resolveAPIKey(for preset: AIProviderPreset) throws -> String? {
        try Self.checkCancellation()
        do {
            let key: String?
            if let configuredAPIKeyProvider {
                key = try configuredAPIKeyProvider(preset)
            } else {
                key = apiKeyProvider()
            }
            try Self.checkCancellation()
            return key
        } catch {
            throw Self.mapAIError(error)
        }
    }

    private static func validatedItems(_ pairs: [(UUID, String)], for ids: Set<UUID>) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (lineID, rawText) in pairs {
            guard ids.contains(lineID), result[lineID] == nil,
                  let text = normalizedNonEmpty(rawText) else { continue }
            result[lineID] = text
        }
        return result
    }
}

// MARK: - 内部辅助

private extension AIStudyWorkflowService {

    func resolvedConfiguration(
        for task: AIStudyBatchTaskKind, startingWith snapshot: AIConfiguration?
    ) throws -> AIConfiguration {
        var configuration = snapshot ?? configurationProvider()
        switch task {
        case .pronunciation(let style):
            configuration.preferredPronunciationStyle = style
        case .translation(let targetLanguage):
            let cleanLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLanguage.isEmpty else {
                throw AIStudyWorkflowError.invalidTargetLanguage
            }
            configuration.preferredTargetLanguage = cleanLanguage
        }
        return configuration
    }

    func fetchBatch(
        batch: [LyricLine],
        task: AIStudyBatchTaskKind,
        sourceLanguage: String?,
        configuration: AIConfiguration,
        apiKey: String?
    ) async throws -> [(UUID, String)] {
        do {
            switch task {
            case .pronunciation(let style):
                let items = try await aiClient.generatePronunciations(
                    for: batch,
                    style: style,
                    sourceLanguage: sourceLanguage,
                    configuration: configuration,
                    apiKey: apiKey
                )
                return items.map { ($0.lineId, $0.pronunciation) }
            case .translation:
                let items = try await aiClient.generateTranslations(
                    for: batch,
                    sourceLanguage: sourceLanguage,
                    configuration: configuration,
                    apiKey: apiKey
                )
                return items.map { ($0.lineId, $0.translation) }
            }
        } catch {
            throw Self.mapAIError(error)
        }
    }

    static func buildPreviewLines(
        from lines: [LyricLine],
        task: AIStudyBatchTaskKind,
        generatedByLineId: [UUID: String]
    ) -> [AIStudyPreviewLine] {
        lines.map { line in
            let generatedText = generatedByLineId[line.id] ?? ""
            let existingText: String?
            let existingIsManual: Bool
            let existingNeedsReview: Bool
            var existingUsesDifferentStyle = false
            switch task {
            case .pronunciation(let style):
                existingText = line.pronunciation?.text
                existingIsManual = line.pronunciation?.source.kind == .manual
                existingNeedsReview = line.pronunciation?.needsReview == true
                existingUsesDifferentStyle = line.pronunciation.map { $0.style != style } ?? false
            case .translation(let targetLanguage):
                let cleanLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                let existing = line.translations[cleanLanguage]
                existingText = existing?.text
                existingIsManual = existing?.source == .manual
                existingNeedsReview = existing?.needsReview == true
            }
            let isSelected = !generatedText.isEmpty && !existingIsManual
            return AIStudyPreviewLine(
                lineId: line.id,
                originalText: line.text,
                existingText: existingText,
                existingIsManual: existingIsManual,
                existingNeedsReview: existingNeedsReview,
                existingUsesDifferentStyle: existingUsesDifferentStyle,
                generatedText: generatedText,
                isSelected: isSelected
            )
        }
    }

    static func chunked<Element>(_ array: [Element], size: Int) -> [[Element]] {
        guard size > 0, !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: size).map { start in
            Array(array[start..<min(start + size, array.count)])
        }
    }

}

extension AIStudyWorkflowService {

    static func nonEmptyLines(in document: LyricDocument) -> [LyricLine] {
        document.lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
        expectedRevision: Int
    ) -> AIStudyWorkflowError {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let workflowError = error as? AIStudyWorkflowError {
            return workflowError
        }
        if let dataError = error as? ShinAppleDataError {
            return mapDataError(dataError, expectedRevision: expectedRevision)
        }
        return .unexpected(String(describing: error))
    }

    static func normalizedNonEmpty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    static func mapDataError(
        _ error: ShinAppleDataError,
        expectedRevision: Int
    ) -> AIStudyWorkflowError {
        switch error {
        case let .revisionConflict(documentId, storedRevision, _):
            return .revisionConflict(
                documentId: documentId,
                storedRevision: storedRevision,
                expectedRevision: expectedRevision
            )
        case let .documentNotFound(id):
            return .documentNotFound(id)
        default:
            return .dataError(error)
        }
    }
}
