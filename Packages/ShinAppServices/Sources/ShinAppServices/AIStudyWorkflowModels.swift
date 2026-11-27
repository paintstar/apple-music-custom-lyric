import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

// MARK: - AI 学习批处理预览与提交模型

/// 批量 AI 学习生成任务类型。
public enum AIStudyBatchTaskKind: Hashable, Sendable {
    case pronunciation(PronunciationStyle)
    case translation(targetLanguage: String)
}

/// 重试同一次操作时复用已完成批次。新的重新生成操作创建独立的临时缓存。
public enum AIStudyBatchRequest: Sendable {
    case fillMissing
    case regenerate(lineIds: Set<UUID>, completedBatches: AIStudyPreviewCache)
}

/// 导入草稿和显式重新生成的会话缓存。每个实例只属于当前会话。
public actor AIStudyPreviewCache {
    private struct PendingBatch {
        let generation: UUID
        let indexKey: String
        let updateIndex: @Sendable (Data?) -> Data?
    }

    private struct Payload {
        let data: Data
        let pendingBatch: PendingBatch?
    }

    // 限制临时预览占用的内存，较早完成的批次优先淘汰。
    private static let byteLimit = 20 * 1_024 * 1_024
    private var payloads: [String: Payload] = [:]
    private var order: [String] = []
    private var totalBytes = 0

    public init() {}

    func payload(for key: String) -> Data? { payloads[key]?.data }

    func save(_ data: Data, for key: String) {
        save(data, for: key, pendingBatch: nil)
    }

    private func save(_ data: Data, for key: String, pendingBatch: PendingBatch?) {
        guard data.count <= Self.byteLimit else { return }
        let payload = Payload(data: data, pendingBatch: pendingBatch)
        if let previous = payloads.updateValue(payload, forKey: key) {
            totalBytes -= previous.data.count
            order.removeAll { $0 == key }
        }
        order.append(key)
        totalBytes += data.count
        while totalBytes > Self.byteLimit, let evictedKey = order.first {
            order.removeFirst()
            totalBytes -= payloads.removeValue(forKey: evictedKey)?.data.count ?? 0
        }
    }

    func saveBatch(
        _ data: Data, key: String, indexKey: String, generation: UUID?, updateIndex: @escaping @Sendable (Data?) -> Data?
    ) {
        guard data.count <= Self.byteLimit else { return }
        let index = updateIndex(payload(for: indexKey))
        let pendingBatch = generation.map { PendingBatch(generation: $0, indexKey: indexKey, updateIndex: updateIndex) }
        save(data, for: key, pendingBatch: pendingBatch)
        if let index {
            save(index, for: indexKey)
        }
    }

    /// 仅在这份草稿确认入库后迁移，为尚未应用的完整结果保留复用机会。
    public func persist(in store: GRDBLyricsStore, for documentID: UUID) async {
        let entries = order.compactMap { key in payloads[key].map { (key, $0) } }
        for (key, payload) in entries {
            guard !Task.isCancelled else { return }
            guard let batch = payload.pendingBatch else { continue }
            // 索引在通过代次校验后合并，草稿里的旧候选不会进入持久缓存。
            try? await store.saveAIStudyCacheBatch(
                payload.data, documentID: documentID, keys: (key, batch.indexKey),
                generation: batch.generation, updateIndex: batch.updateIndex
            )
        }
    }
}

/// 批量生成预览单行：按稳定 `lineId` 绑定原文、现存值与生成结果。
public struct AIStudyPreviewLine: Equatable, Sendable, Identifiable {
    public let lineId: UUID
    public let originalText: String
    public var existingText: String?
    public var existingIsManual: Bool
    public var existingNeedsReview: Bool
    public var existingUsesDifferentStyle: Bool
    public var generatedText: String
    public var isSelected: Bool

    public var id: UUID { lineId }

    public init(
        lineId: UUID,
        originalText: String,
        existingText: String? = nil,
        existingIsManual: Bool = false,
        existingNeedsReview: Bool = false,
        existingUsesDifferentStyle: Bool = false,
        generatedText: String,
        isSelected: Bool = true
    ) {
        self.lineId = lineId
        self.originalText = originalText
        self.existingText = existingText
        self.existingIsManual = existingIsManual
        self.existingNeedsReview = existingNeedsReview
        self.existingUsesDifferentStyle = existingUsesDifferentStyle
        self.generatedText = generatedText
        self.isSelected = isSelected
    }
}

/// 批量生成进度摘要。
public struct AIStudyBatchProgress: Equatable, Sendable {
    public let completedBatches: Int
    public let totalBatches: Int
    public let completedLines: Int
    public let totalLines: Int

    public var currentBatchNumber: Int {
        guard totalBatches > 0 else { return 0 }
        return min(completedBatches + 1, totalBatches)
    }

    public var fractionCompleted: Double {
        if totalLines > 0 {
            return min(1, max(0, Double(completedLines) / Double(totalLines)))
        }
        guard totalBatches > 0 else { return 0 }
        return min(1, max(0, Double(completedBatches) / Double(totalBatches)))
    }

    public init(
        completedBatches: Int,
        totalBatches: Int,
        completedLines: Int = 0,
        totalLines: Int = 0
    ) {
        self.completedBatches = completedBatches
        self.totalBatches = totalBatches
        self.completedLines = completedLines
        self.totalLines = totalLines
    }
}

/// AI 学习工作流类型化错误，统一包装配置、提供商、编辑、存储与冲突错误。
public enum AIStudyWorkflowError: Error, LocalizedError, Equatable, Sendable {
    case providerError(AIProviderError)
    case editingError(LyricsEditingError)
    case dataError(ShinAppleDataError)
    case cancelled
    case emptyLyrics
    case invalidTargetLanguage
    case documentNotFound(UUID)
    case revisionConflict(documentId: UUID, storedRevision: Int, expectedRevision: Int)
    case unexpected(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .providerError(let error):
            return error.userMessage
        case .editingError(let error):
            return error.message
        case .dataError(let error):
            return ShinDataFaultPresentation.message(for: error)
        case .cancelled:
            return "已取消 AI 学习生成任务。"
        case .emptyLyrics:
            return "当前歌词中没有可供 AI 处理的非空行。"
        case .invalidTargetLanguage:
            return "目标翻译语言不能为空。"
        case .documentNotFound(let id):
            return "目标歌词文档不存在（可能已被删除）：\(id.uuidString)"
        case .revisionConflict(let documentId, let storedRevision, let expectedRevision):
            return "文档已被修改（库中 revision \(storedRevision)，预览基线 \(expectedRevision)），"
                + "已取消本次写入以防覆盖最新内容：\(documentId.uuidString)"
        case .unexpected(let detail):
            return "AI 学习任务发生未预期错误：\(detail)"
        }
    }
}
