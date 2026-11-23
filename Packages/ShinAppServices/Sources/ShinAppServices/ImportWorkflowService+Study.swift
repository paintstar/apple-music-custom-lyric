import Foundation
import ShinAppleKit

// MARK: - 导入工作流：预览期 AI 注音与译文合入

extension ImportWorkflowService {

    /// 获取导入预览期当前待保存的草稿文档（含已应用的双语映射与 AI 学习注解）。
    /// 仅在 `.open` 且已成功 `ingest` 时返回文档，其余状态返回 nil。
    public func currentDraftDocumentForStudy() -> LyricDocument? {
        guard phase == .open, let file = ingested else { return nil }
        let baseDocument = bilingualOutcome?.document ?? file.document
        return mergingStudyAnnotations(into: baseDocument)
    }

    /// 在导入预览期合入预览确认后的行级注音与译文（按稳定 `line.id` 匹配）。
    /// - 仅更新当前预览文档中存在的有效行且非空的注解；
    /// - 多次分批合入（如先生成注音再生成译文）互不清除；
    /// - 重新 `ingest` 或切换 `setBilingualMode` 会重置已缓存的 AI 注解。
    @discardableResult
    public func applyStudyAnnotations(
        pronunciations: [UUID: LinePronunciation],
        translations: [UUID: Translation],
        language: String
    ) -> ImportPreview? {
        guard phase == .open, let file = ingested else { return nil }
        let baseDocument = bilingualOutcome?.document ?? file.document
        let baseLinesByID = Dictionary(
            baseDocument.lines.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for (lineId, incoming) in pronunciations {
            guard let baseLine = baseLinesByID[lineId] else { continue }
            let cleanText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            var normalized = incoming
            normalized.text = cleanText
            if baseLine.pronunciation == normalized {
                studyPronunciations.removeValue(forKey: lineId)
            } else {
                studyPronunciations[lineId] = normalized
            }
        }

        let cleanLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLanguage.isEmpty && !translations.isEmpty {
            for (lineId, incoming) in translations {
                guard let baseLine = baseLinesByID[lineId] else { continue }
                let cleanText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanText.isEmpty else { continue }
                var normalized = incoming
                normalized.text = cleanText
                if baseLine.translations[cleanLanguage] == normalized {
                    studyTranslationsByLanguage[cleanLanguage]?.removeValue(forKey: lineId)
                } else {
                    studyTranslationsByLanguage[cleanLanguage, default: [:]][lineId] = normalized
                }
            }
        }

        return makeCurrentPreview(for: file)
    }

    func resetStudyAnnotations() {
        studyPronunciations = [:]
        studyTranslationsByLanguage = [:]
    }

    func mergingStudyAnnotations(into document: LyricDocument) -> LyricDocument {
        guard !studyPronunciations.isEmpty || !studyTranslationsByLanguage.isEmpty else {
            return document
        }
        var merged = document
        for index in merged.lines.indices {
            let lineId = merged.lines[index].id
            if let pronunciation = studyPronunciations[lineId] {
                merged.lines[index].pronunciation = pronunciation
            }
            for (language, map) in studyTranslationsByLanguage {
                if let translation = map[lineId] {
                    merged.lines[index].translations[language] = translation
                }
            }
        }
        return merged
    }
}
