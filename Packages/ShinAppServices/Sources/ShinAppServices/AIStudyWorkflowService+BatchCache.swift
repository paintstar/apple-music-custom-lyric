import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

// 单次预览冻结服务配置与输入语言；缓存键不含凭据和时间轴。
struct AIStudyBatchCacheContext {
    let documentID: UUID
    let sourceLanguage: String?
    let task: AIStudyBatchTaskKind
    let configuration: AIConfiguration

    func key(for batch: [LyricLine], isProjectionIndex: Bool = false) -> String {
        let taskName: String
        let option: String
        switch task {
        case .pronunciation(let style):
            taskName = "batchPronunciation"
            option = style.rawValue
        case .translation:
            taskName = "batchTranslation"
            option = configuration.preferredTargetLanguage
        }
        let inputs = [isProjectionIndex ? "projectionIndex" : "requestedLines",
                      documentID.uuidString, option, sourceLanguage ?? "自动识别"]
            + batch.flatMap { [$0.id.uuidString, $0.text] }
        return AIStudyCacheKey.make(task: taskName, configuration: configuration, inputs: inputs)
    }
}

extension AIStudyWorkflowService {
    private func cachePayload(key: String, documentID: UUID, from session: AIStudyPreviewCache? = nil) async -> Data? {
        if let cache = session ?? draftCache {
            return await cache.payload(for: key)
        }
        return try? await store.aiStudyCachePayload(documentID: documentID, key: key)
    }

    func cachedBatch(
        for ids: Set<UUID>, key: String, documentID: UUID, from session: AIStudyPreviewCache? = nil
    ) async -> [UUID: String]? {
        guard let payload = await cachePayload(key: key, documentID: documentID, from: session),
              let result = try? JSONDecoder().decode([UUID: String].self, from: payload),
              Set(result.keys) == ids,
              result.values.allSatisfy({ Self.normalizedNonEmpty($0) != nil }) else { return nil }
        return result
    }

    /// 候选行可来自多次请求。每行指向最近一次完整响应的输入，已写入的行不会取预览候选。
    private struct BatchProjection: Codable {
        let inputIDs: Set<UUID>
        var candidateIDs: Set<UUID>
    }

    func projectedResults(
        for ids: Set<UUID>,
        from group: [LyricLine],
        key: String,
        exact: [UUID: String]?,
        context: AIStudyBatchCacheContext
    ) async -> [UUID: String] {
        let indexPayload = await cachePayload(key: key, documentID: context.documentID)
        let projections = Self.batchProjections(from: indexPayload)
        var resolved: [UUID: String] = [:]
        for projection in projections {
            let candidateIDs = ids.intersection(projection.candidateIDs)
            guard !candidateIDs.isEmpty, !Task.isCancelled else { continue }
            let previousInput = group.filter { projection.inputIDs.contains($0.id) }
            guard previousInput.count == projection.inputIDs.count else { continue }
            let cached: [UUID: String]?
            if projection.inputIDs == ids, let exact {
                cached = exact
            } else {
                let resultKey = context.key(for: previousInput)
                cached = await cachedBatch(for: projection.inputIDs, key: resultKey, documentID: context.documentID)
            }
            for lineID in candidateIDs {
                resolved[lineID] = cached?[lineID]
            }
        }
        return resolved
    }

    private static func batchProjections(from payload: Data?) -> [BatchProjection] {
        guard let payload, let projections = try? JSONDecoder().decode([BatchProjection].self, from: payload) else { return [] }
        return projections
    }

    func saveBatch(
        _ data: Data, inputIDs: Set<UUID>, keys: (batch: String, index: String), documentID: UUID, generation: UUID?
    ) async {
        let updateIndex: @Sendable (Data?) -> Data? = { payload in
            var projections = Self.batchProjections(from: payload)
            // 一行只留一个最新候选，每组至多保留与原文行数相同的指向。
            for index in projections.indices {
                projections[index].candidateIDs.subtract(inputIDs)
            }
            projections.removeAll { $0.candidateIDs.isEmpty }
            projections.append(BatchProjection(inputIDs: inputIDs, candidateIDs: inputIDs))
            return try? JSONEncoder().encode(projections)
        }
        if let draftCache {
            await draftCache.saveBatch(data, key: keys.batch, indexKey: keys.index, generation: generation, updateIndex: updateIndex)
        } else if let generation {
            try? await store.saveAIStudyCacheBatch(
                data, documentID: documentID, keys: keys, generation: generation, updateIndex: updateIndex
            )
        }
    }
}
