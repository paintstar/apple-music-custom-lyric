import Foundation
import ShinAppleKit

// MARK: - 歌词编辑服务：逐行注音、学习笔记与批量 AI 预览写入

extension LyricsEditingService {

    /// 获取当前工作草稿的只读副本；未打开编辑会话时返回 nil。
    public func currentWorkingDocument() -> LyricDocument? {
        guard phase == .open else { return nil }
        return workingDocument
    }

    /// 修改单行注音标注。
    /// - 文本去掉首尾空白及换行后全空 → 清除 `pronunciation = nil`；
    /// - 非空 → 以 `style ?? existing?.style ?? .romaji`、`source: .manual()`、`needsReview: false` 写入；
    /// - 若 `style`、`text` 与 `needsReview == false` 均与现有注音一致，则为 no-op（保留原来源并避免多余历史）。
    @discardableResult
    public func setPronunciation(
        lineId: UUID,
        style: PronunciationStyle?,
        text: String
    ) async throws -> LyricsEditingSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let coalesceKey: String?
        if trimmed.isEmpty {
            coalesceKey = nil
        } else {
            let existingStyle = workingDocument?.lines.first { $0.id == lineId }?.pronunciation?.style
            let resolvedStyle = style ?? existingStyle ?? .romaji
            coalesceKey = "pronunciation:\(lineId.uuidString):\(resolvedStyle.rawValue)"
        }
        return try await mutate(coalesceKey: coalesceKey) { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            if trimmed.isEmpty {
                document.lines[index].pronunciation = nil
                return
            }
            let existing = document.lines[index].pronunciation
            let resolvedStyle = style ?? existing?.style ?? .romaji
            if let existing,
               existing.style == resolvedStyle,
               existing.text == trimmed,
               !existing.needsReview {
                return
            }
            document.lines[index].pronunciation = LinePronunciation(
                style: resolvedStyle,
                text: trimmed,
                source: .manual(),
                needsReview: false
            )
        }
    }

    /// 设置或清除单行学习讲解笔记（传 `nil` 清除），按稳定 `lineId` 定位并进入撤销历史。
    @discardableResult
    public func setLineStudyNote(
        lineId: UUID,
        note: LineStudyNote?
    ) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: nil) { document in
            guard let index = Self.lineIndex(of: lineId, in: document) else {
                throw LyricsEditingError.lineNotFound(lineId: lineId)
            }
            document.lines[index].studyNote = note
        }
    }

    /// 批量写入行级注音标注（用于编辑器内「AI 生成注音」预览确认后一次写入草稿），
    /// 按稳定 `line.id` 对齐并合并为单条撤销记录。
    @discardableResult
    public func applyBatchPronunciations(
        _ updates: [UUID: LinePronunciation]
    ) async throws -> LyricsEditingSnapshot {
        try await mutate(coalesceKey: nil) { document in
            guard !updates.isEmpty else { return }
            for index in document.lines.indices {
                let lineId = document.lines[index].id
                guard let incoming = updates[lineId] else { continue }
                let cleanText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanText.isEmpty else { continue }
                var normalized = incoming
                normalized.text = cleanText
                document.lines[index].pronunciation = normalized
            }
        }
    }

    /// 批量写入行级译文（用于编辑器内「AI 生成译文」预览确认后一次写入草稿），
    /// 按稳定 `line.id` 对齐并合并为单条撤销记录。
    @discardableResult
    public func applyBatchTranslations(
        _ updates: [UUID: Translation],
        language: String
    ) async throws -> LyricsEditingSnapshot {
        let cleanLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await mutate(coalesceKey: nil) { document in
            guard !cleanLanguage.isEmpty, !updates.isEmpty else { return }
            for index in document.lines.indices {
                let lineId = document.lines[index].id
                guard let incoming = updates[lineId] else { continue }
                let cleanText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanText.isEmpty else { continue }
                var normalized = incoming
                normalized.text = cleanText
                document.lines[index].translations[cleanLanguage] = normalized
            }
        }
    }
}
