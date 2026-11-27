import Foundation
import ShinAppleData
import ShinAppleKit

extension AIStudyWorkflowService {
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
    /// - 只更新文档，关联信息与时间偏移由其各自的写入路径维护。
    public func applyPreviewToStore(
        documentId: UUID,
        expectedRevision: Int,
        task: AIStudyBatchTaskKind,
        modelName: String?,
        items: [AIStudyPreviewLine]
    ) async throws -> LyricDocument {
        try Self.checkCancellation()
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

        let sourceByLineID = Dictionary(loaded.lines.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        for item in items where item.isSelected && Self.normalizedNonEmpty(item.generatedText) != nil {
            guard let storedText = sourceByLineID[item.lineId], storedText == item.originalText else {
                throw AIStudyWorkflowError.editingError(.storeRejection("待应用行的原文已改变，请重新打开 AI 预览。"))
            }
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
            try Self.checkCancellation()
            try await store.updateDocument(submit)
            return submit
        } catch {
            throw Self.mapStoreError(error, expectedRevision: expectedRevision)
        }
    }

    private func loadExistingDocument(id: UUID, expectedRevision: Int) async throws -> LyricDocument {
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

    private static func applying(
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

    private static func normalizedModelName(_ raw: String?) -> String? {
        normalizedNonEmpty(raw)
    }
}
