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
    let apiKeyProvider: @Sendable () -> String?

    public init(
        store: GRDBLyricsStore,
        aiClient: any AIStudyProviding,
        configurationProvider: @escaping @Sendable () -> AIConfiguration,
        apiKeyProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.store = store
        self.aiClient = aiClient
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
    }

    /// 按批次生成预览行列表。
    /// - 过滤空白行后按 `batchSize` 分批，每批携带稳定 `line.id` 请求 AI 服务；
    /// - 按 `lineId` 精确回填，乱序或遗漏都不会造成行错位；
    /// - 已有来源为 `.manual` 的注音或译文时，默认 `isSelected = false`，否则仅在生成结果非空时选中；
    /// - 每批前/后检查 `Task.isCancelled`，取消时立即中止后续请求。
    public func generatePreview(
        for document: LyricDocument,
        task: AIStudyBatchTaskKind,
        songTitle: String? = nil,
        artist: String? = nil,
        batchSize: Int = AIStudyWorkflowService.defaultBatchSize,
        onProgress: (@Sendable (AIStudyBatchProgress) -> Void)? = nil
    ) async throws -> [AIStudyPreviewLine] {
        _ = (songTitle, artist)
        if Task.isCancelled {
            throw AIStudyWorkflowError.cancelled
        }

        let resolvedConfiguration = try resolvedConfiguration(for: task)
        let apiKey = apiKeyProvider()

        let nonEmptyLines = Self.nonEmptyLines(in: document)
        guard !nonEmptyLines.isEmpty else {
            throw AIStudyWorkflowError.emptyLyrics
        }

        let batches = Self.chunked(nonEmptyLines, size: max(1, batchSize))
        var generatedByLineId: [UUID: String] = [:]
        var completedLines = 0
        onProgress?(AIStudyBatchProgress(
            completedBatches: 0,
            totalBatches: batches.count,
            completedLines: 0,
            totalLines: nonEmptyLines.count
        ))

        for (batchIndex, batch) in batches.enumerated() {
            if Task.isCancelled {
                throw AIStudyWorkflowError.cancelled
            }
            let batchPairs = try await fetchBatch(
                batch: batch,
                task: task,
                sourceLanguage: document.sourceLanguage,
                configuration: resolvedConfiguration,
                apiKey: apiKey
            )
            if Task.isCancelled {
                throw AIStudyWorkflowError.cancelled
            }
            let validBatchIDs = Set(batch.map(\.id))
            for (lineId, rawText) in batchPairs {
                guard validBatchIDs.contains(lineId) else { continue }
                let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanText.isEmpty, generatedByLineId[lineId] == nil else { continue }
                generatedByLineId[lineId] = cleanText
            }
            completedLines += batch.count
            onProgress?(AIStudyBatchProgress(
                completedBatches: batchIndex + 1,
                totalBatches: batches.count,
                completedLines: completedLines,
                totalLines: nonEmptyLines.count
            ))
        }

        return Self.buildPreviewLines(
            from: nonEmptyLines,
            task: task,
            generatedByLineId: generatedByLineId
        )
    }

    /// 纯函数：将预览中勾选且非空的注音结果与文档原有注音按稳定 `lineId` 合并。
    public static func mergedPronunciations(
        in document: LyricDocument,
        items: [AIStudyPreviewLine],
        style: PronunciationStyle,
        modelName: String?
    ) -> [UUID: LinePronunciation] {
        let resolvedModel = normalizedModelName(modelName)
        var result: [UUID: LinePronunciation] = [:]
        var validLineIDs = Set<UUID>()
        for line in document.lines {
            validLineIDs.insert(line.id)
            if let existing = line.pronunciation {
                result[line.id] = existing
            }
        }
        for item in items where item.isSelected && validLineIDs.contains(item.lineId) {
            let cleanText = item.generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            result[item.lineId] = LinePronunciation(
                style: style,
                text: cleanText,
                source: .ai(model: resolvedModel),
                needsReview: false
            )
        }
        return result
    }

    /// 纯函数：将预览中勾选且非空的译文结果与文档原有该语言译文按稳定 `lineId` 合并。
    public static func mergedTranslations(
        in document: LyricDocument,
        items: [AIStudyPreviewLine],
        language: String
    ) -> [UUID: Translation] {
        let cleanLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLanguage.isEmpty else { return [:] }
        var result: [UUID: Translation] = [:]
        var validLineIDs = Set<UUID>()
        for line in document.lines {
            validLineIDs.insert(line.id)
            if let existing = line.translations[cleanLanguage] {
                result[line.id] = existing
            }
        }
        for item in items where item.isSelected && validLineIDs.contains(item.lineId) {
            let cleanText = item.generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            result[item.lineId] = Translation(
                text: cleanText,
                source: .imported,
                needsReview: false
            )
        }
        return result
    }

    /// 原子提交预览结果到已入库文档。
    /// - 先读取最新文档核对 `expectedRevision`，并发修改时拒绝覆盖；
    /// - 仅更新勾选且非空的行（`needsReview = false`），无有效变更时幂等返回原文档；
    /// - 有绑定时经 `store.save(document:binding:)`，无绑定时经 `store.updateDocument(_:)` 乐观并发提交。
    public func applyPreviewToStore(
        documentId: UUID,
        expectedRevision: Int,
        task: AIStudyBatchTaskKind,
        modelName: String?,
        items: [AIStudyPreviewLine]
    ) async throws -> LyricDocument {
        if case .translation(let targetLanguage) = task,
           targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIStudyWorkflowError.invalidTargetLanguage
        }

        let loaded = try await loadExistingDocument(id: documentId, expectedRevision: expectedRevision)
        guard loaded.revision == expectedRevision else {
            throw AIStudyWorkflowError.revisionConflict(
                documentId: documentId,
                storedRevision: loaded.revision,
                expectedRevision: expectedRevision
            )
        }

        let updatedLines = Self.applying(
            items: items,
            to: loaded,
            task: task,
            modelName: modelName
        )
        guard updatedLines != loaded.lines else {
            return loaded
        }

        var submit = loaded
        submit.lines = updatedLines
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
        } catch let dataError as ShinAppleDataError {
            throw Self.mapDataError(dataError, expectedRevision: expectedRevision)
        } catch {
            throw AIStudyWorkflowError.unexpected(String(describing: error))
        }
    }
}

// MARK: - 内部辅助

private extension AIStudyWorkflowService {

    func resolvedConfiguration(for task: AIStudyBatchTaskKind) throws -> AIConfiguration {
        var configuration = configurationProvider()
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

    func loadExistingDocument(id: UUID, expectedRevision: Int) async throws -> LyricDocument {
        do {
            guard let existing = try await store.document(id: id) else {
                throw AIStudyWorkflowError.documentNotFound(id)
            }
            return existing
        } catch let workflowError as AIStudyWorkflowError {
            throw workflowError
        } catch let dataError as ShinAppleDataError {
            throw Self.mapDataError(dataError, expectedRevision: expectedRevision)
        } catch {
            throw AIStudyWorkflowError.unexpected(String(describing: error))
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
            switch task {
            case .pronunciation:
                existingText = line.pronunciation?.text
                existingIsManual = line.pronunciation?.source.kind == .manual
            case .translation(let targetLanguage):
                let cleanLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
                let existing = line.translations[cleanLanguage]
                existingText = existing?.text
                existingIsManual = existing?.source == .manual
            }
            let isSelected = !generatedText.isEmpty && !existingIsManual
            return AIStudyPreviewLine(
                lineId: line.id,
                originalText: line.text,
                existingText: existingText,
                existingIsManual: existingIsManual,
                generatedText: generatedText,
                isSelected: isSelected
            )
        }
    }

    static func applying(
        items: [AIStudyPreviewLine],
        to document: LyricDocument,
        task: AIStudyBatchTaskKind,
        modelName: String?
    ) -> [LyricLine] {
        var lines = document.lines
        switch task {
        case .pronunciation(let style):
            let merged = mergedPronunciations(
                in: document,
                items: items,
                style: style,
                modelName: modelName
            )
            for index in lines.indices {
                if let updated = merged[lines[index].id] {
                    lines[index].pronunciation = updated
                }
            }
        case .translation(let targetLanguage):
            let cleanLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            let merged = mergedTranslations(
                in: document,
                items: items,
                language: cleanLanguage
            )
            for index in lines.indices {
                if let updated = merged[lines[index].id] {
                    lines[index].translations[cleanLanguage] = updated
                }
            }
        }
        return lines
    }

    static func chunked<Element>(_ array: [Element], size: Int) -> [[Element]] {
        guard size > 0, !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: size).map { start in
            Array(array[start..<min(start + size, array.count)])
        }
    }

    static func normalizedModelName(_ raw: String?) -> String? {
        normalizedNonEmpty(raw)
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
