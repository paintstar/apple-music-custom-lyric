import Foundation
import ShinAIProvider
import ShinAppleData
import ShinAppleKit

// MARK: - AI 学习批处理预览与提交模型

/// 批量 AI 学习生成任务类型。
public enum AIStudyBatchTaskKind: Equatable, Sendable {
    case pronunciation(PronunciationStyle)
    case translation(targetLanguage: String)
}

/// 批量生成预览单行：按稳定 `lineId` 绑定原文、现存值与生成结果。
public struct AIStudyPreviewLine: Equatable, Sendable, Identifiable {
    public let lineId: UUID
    public let originalText: String
    public var existingText: String?
    public var existingIsManual: Bool
    public var generatedText: String
    public var isSelected: Bool

    public var id: UUID { lineId }

    public init(
        lineId: UUID,
        originalText: String,
        existingText: String? = nil,
        existingIsManual: Bool = false,
        generatedText: String,
        isSelected: Bool = true
    ) {
        self.lineId = lineId
        self.originalText = originalText
        self.existingText = existingText
        self.existingIsManual = existingIsManual
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
