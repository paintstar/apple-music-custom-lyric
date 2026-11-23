import Foundation
import ShinAppleKit

/// 生词本导出格式。
public enum VocabularyExportFormat: String, CaseIterable, Equatable, Sendable {
    case ankiTSV
    case csv
    case markdown

    /// 面向界面展示的中文名称。
    public var displayName: String {
        switch self {
        case .ankiTSV: return "Anki 制卡 (.tsv)"
        case .csv: return "CSV 表格 (.csv)"
        case .markdown: return "Markdown 笔记 (.md)"
        }
    }

    /// 推荐导出文件扩展名（不含点号）。
    public var fileExtension: String {
        switch self {
        case .ankiTSV: return "tsv"
        case .csv: return "csv"
        case .markdown: return "md"
        }
    }
}

/// 生词本纯函数导出工具（无状态、无 I/O），支持 Anki TSV、CSV 与 Markdown。
public enum VocabularyExportService {

    /// 将生词词条与对应原声出处按确定性顺序导出为指定格式文本。
    public static func export(
        entries: [VocabularyEntry],
        occurrencesByEntryId: [UUID: [VocabularyOccurrence]],
        format: VocabularyExportFormat
    ) -> String {
        let sortedEntries = sortEntries(entries)
        switch format {
        case .ankiTSV:
            return exportAnkiTSV(entries: sortedEntries, occurrencesByEntryId: occurrencesByEntryId)
        case .csv:
            return exportCSV(entries: sortedEntries, occurrencesByEntryId: occurrencesByEntryId)
        case .markdown:
            return exportMarkdown(entries: sortedEntries, occurrencesByEntryId: occurrencesByEntryId)
        }
    }
}

// MARK: - 各格式实现

private extension VocabularyExportService {

    static func exportAnkiTSV(
        entries: [VocabularyEntry],
        occurrencesByEntryId: [UUID: [VocabularyOccurrence]]
    ) -> String {
        guard !entries.isEmpty else { return "" }
        let rows = entries.map { entry in
            let occurrences = sortOccurrences(occurrencesByEntryId[entry.id] ?? [])
            let front = buildAnkiFront(entry: entry, occurrences: occurrences)
            let back = buildAnkiBack(entry: entry, occurrences: occurrences)
            return "\(escapeTSVField(front))\t\(escapeTSVField(back))"
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func buildAnkiFront(
        entry: VocabularyEntry,
        occurrences: [VocabularyOccurrence]
    ) -> String {
        var sections: [String] = []

        var headword = entry.surface
        if let reading = nonEmptyTrimmed(entry.reading) {
            headword += " [\(reading)]"
        }
        let cleanLemma = entry.lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLemma.isEmpty, cleanLemma != entry.surface {
            headword += "（原型：\(cleanLemma)）"
        }
        sections.append(headword)

        let lineSnippets = occurrences.compactMap { occ -> String? in
            guard let lineText = nonEmptyTrimmed(occ.lineTextSnapshot) else { return nil }
            if let startMs = occ.startMsSnapshot {
                return "[\(formatTimestampMMSS(startMs))] \(lineText)"
            }
            return lineText
        }
        if !lineSnippets.isEmpty {
            sections.append(contentsOf: deduplicatedPreservingOrder(lineSnippets))
        }

        return sections.joined(separator: "\n")
    }

    static func buildAnkiBack(
        entry: VocabularyEntry,
        occurrences: [VocabularyOccurrence]
    ) -> String {
        var sections: [String] = []

        let pos = nonEmptyTrimmed(entry.partOfSpeech)
        let generalMeaning = nonEmptyTrimmed(entry.generalMeaning)
        switch (pos, generalMeaning) {
        case let (pos?, meaning?):
            sections.append("[\(pos)] \(meaning)")
        case let (pos?, nil):
            sections.append("词性：\(pos)")
        case let (nil, meaning?):
            sections.append(meaning)
        case (nil, nil):
            break
        }

        let contextualMeanings = deduplicatedPreservingOrder(
            occurrences.compactMap { nonEmptyTrimmed($0.contextualMeaning) }
        )
        if !contextualMeanings.isEmpty {
            sections.append("语境义：\(contextualMeanings.joined(separator: "；"))")
        }

        let formattedExamples = entry.examples.compactMap { formatExample($0) }
        if !formattedExamples.isEmpty {
            sections.append(contentsOf: formattedExamples.map { "例句：\($0)" })
        }

        if let userNote = nonEmptyTrimmed(entry.userNote) {
            sections.append("笔记：\(userNote)")
        }

        let attributions = deduplicatedPreservingOrder(
            occurrences.compactMap { formatTrackAttribution($0) }
        )
        if !attributions.isEmpty {
            sections.append("出处：\(attributions.joined(separator: "；"))")
        }

        return sections.joined(separator: "\n")
    }

    static func exportCSV(
        entries: [VocabularyEntry],
        occurrencesByEntryId: [UUID: [VocabularyOccurrence]]
    ) -> String {
        let headers = [
            "词语",
            "原型",
            "读音",
            "语种",
            "词性",
            "掌握度",
            "通用释义",
            "语境释义",
            "例句",
            "个人笔记",
            "歌词原句",
            "曲目出处"
        ]
        var rows: [String] = [headers.map(escapeCSVField).joined(separator: ",")]

        for entry in entries {
            let occurrences = sortOccurrences(occurrencesByEntryId[entry.id] ?? [])
            let contextual = deduplicatedPreservingOrder(
                occurrences.compactMap { nonEmptyTrimmed($0.contextualMeaning) }
            ).joined(separator: "\n")
            let examples = entry.examples
                .compactMap { formatExample($0) }
                .joined(separator: "\n")
            let lyricQuotes = occurrences.compactMap { formatOccurrenceLyricLine($0) }
                .joined(separator: "\n")
            let attributions = deduplicatedPreservingOrder(
                occurrences.compactMap { formatTrackAttribution($0) }
            ).joined(separator: "\n")

            let columns = [
                entry.surface,
                entry.lemma,
                entry.reading ?? "",
                entry.language ?? "",
                entry.partOfSpeech ?? "",
                entry.mastery.displayName,
                entry.generalMeaning,
                contextual,
                examples,
                entry.userNote ?? "",
                lyricQuotes,
                attributions
            ]
            rows.append(columns.map(escapeCSVField).joined(separator: ","))
        }

        return rows.joined(separator: "\n") + "\n"
    }

    static func exportMarkdown(
        entries: [VocabularyEntry],
        occurrencesByEntryId: [UUID: [VocabularyOccurrence]]
    ) -> String {
        var lines: [String] = ["# 生词本导出", ""]
        guard !entries.isEmpty else {
            lines.append("暂无生词记录。")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("共 \(entries.count) 个词条")

        for entry in entries {
            let occurrences = sortOccurrences(occurrencesByEntryId[entry.id] ?? [])
            lines.append("")
            lines.append("## \(normalizedInlineText(entry.surface))")
            lines.append("")

            appendMarkdownMetadata(for: entry, to: &lines)

            if let generalMeaning = nonEmptyTrimmed(entry.generalMeaning) {
                lines.append("")
                lines.append("### 通用释义")
                lines.append("")
                lines.append(normalizedNewlines(generalMeaning))
            }

            let formattedExamples = entry.examples.compactMap { formatExample($0) }
            if !formattedExamples.isEmpty {
                lines.append("")
                lines.append("### 例句")
                lines.append("")
                for example in formattedExamples {
                    lines.append("- \(indentedMultilineListContent(example))")
                }
            }

            if let userNote = nonEmptyTrimmed(entry.userNote) {
                lines.append("")
                lines.append("### 个人笔记")
                lines.append("")
                lines.append(normalizedNewlines(userNote))
            }

            if !occurrences.isEmpty {
                lines.append("")
                lines.append("### 关联歌曲原声")
                lines.append("")
                for occ in occurrences {
                    lines.append("- \(indentedMultilineListContent(formatMarkdownOccurrence(occ)))")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func appendMarkdownMetadata(for entry: VocabularyEntry, to lines: inout [String]) {
        let cleanLemma = entry.lemma.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLemma.isEmpty, cleanLemma != entry.surface {
            lines.append("- **原型**：\(normalizedInlineText(cleanLemma))")
        }
        if let reading = nonEmptyTrimmed(entry.reading) {
            lines.append("- **读音**：\(normalizedInlineText(reading))")
        }
        if let partOfSpeech = nonEmptyTrimmed(entry.partOfSpeech) {
            lines.append("- **词性**：\(normalizedInlineText(partOfSpeech))")
        }
        if let language = nonEmptyTrimmed(entry.language) {
            lines.append("- **语种**：\(normalizedInlineText(language))")
        }
        lines.append("- **掌握度**：`\(entry.mastery.displayName)`")
    }
}

// MARK: - 排序、格式化与转义助手

private extension VocabularyExportService {

    static func sortEntries(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        entries.sorted { lhs, rhs in
            if let ordered = compareTimestampDescending(lhs.updatedAt, rhs.updatedAt) {
                return ordered
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func sortOccurrences(_ occurrences: [VocabularyOccurrence]) -> [VocabularyOccurrence] {
        occurrences.sorted { lhs, rhs in
            if let ordered = compareTimestampDescending(lhs.createdAt, rhs.createdAt) {
                return ordered
            }
            let lhsTime = lhs.startMsSnapshot ?? Int64.max
            let rhsTime = rhs.startMsSnapshot ?? Int64.max
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            if lhs.utf16Location != rhs.utf16Location { return lhs.utf16Location < rhs.utf16Location }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func compareTimestampDescending(_ lhs: String, _ rhs: String) -> Bool? {
        guard lhs != rhs else { return nil }
        if let lhsDate = LyricTimestamp.date(from: lhs),
           let rhsDate = LyricTimestamp.date(from: rhs),
           lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs > rhs
    }

    /// TSV 字段转义：制表符替换为空格、换行替换为 Anki `<br>`，含双引号时按 RFC 规则包裹并内部 `""` 转义。
    static func escapeTSVField(_ value: String) -> String {
        let sanitized = normalizedNewlines(value)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: "<br>")
        guard sanitized.contains("\"") else {
            return sanitized
        }
        let escapedQuotes = sanitized.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escapedQuotes)\""
    }

    /// CSV RFC 4180 字段转义：含逗号、双引号或换行时以双引号包裹，并将内部双引号转义为 `""`。
    static func escapeCSVField(_ value: String) -> String {
        let normalized = normalizedNewlines(value)
        let needsQuotes = normalized.contains(",")
            || normalized.contains("\"")
            || normalized.contains("\n")
        guard needsQuotes else {
            return normalized
        }
        let escapedQuotes = normalized.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escapedQuotes)\""
    }

    static func formatTimestampMMSS(_ ms: Int64) -> String {
        let totalSeconds = max(0, ms) / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let minuteText = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        let secondText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "\(minuteText):\(secondText)"
    }

    static func formatTrackAttribution(_ occurrence: VocabularyOccurrence) -> String? {
        let trackTitle = nonEmptyTrimmed(occurrence.trackTitleHint)
        let artist = nonEmptyTrimmed(occurrence.artistHint)
        let trackPart: String?
        switch (trackTitle, artist) {
        case let (title?, artist?):
            trackPart = "\(title) - \(artist)"
        case let (title?, nil):
            trackPart = title
        case let (nil, artist?):
            trackPart = artist
        case (nil, nil):
            trackPart = nil
        }
        let timePart = occurrence.startMsSnapshot.map { "[\(formatTimestampMMSS($0))]" }
        let parts = [trackPart, timePart].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func formatExample(_ example: VocabularyExample) -> String? {
        guard let text = nonEmptyTrimmed(example.text) else { return nil }
        if let translation = nonEmptyTrimmed(example.translation) {
            return "\(text) — \(translation)"
        }
        return text
    }

    static func formatOccurrenceLyricLine(_ occurrence: VocabularyOccurrence) -> String? {
        guard let lineText = nonEmptyTrimmed(occurrence.lineTextSnapshot) else { return nil }
        var prefix = ""
        if let startMs = occurrence.startMsSnapshot {
            prefix = "[\(formatTimestampMMSS(startMs))] "
        }
        if let translation = nonEmptyTrimmed(occurrence.lineTranslationSnapshot) {
            return "\(prefix)\(lineText)（\(translation)）"
        }
        return "\(prefix)\(lineText)"
    }

    static func formatMarkdownOccurrence(_ occurrence: VocabularyOccurrence) -> String {
        var segments: [String] = []
        if let startMs = occurrence.startMsSnapshot {
            segments.append("[\(formatTimestampMMSS(startMs))]")
        }
        let trackParts = [
            nonEmptyTrimmed(occurrence.trackTitleHint),
            nonEmptyTrimmed(occurrence.artistHint)
        ].compactMap { $0 }
        if !trackParts.isEmpty {
            segments.append(trackParts.joined(separator: " - "))
        }
        let headerPrefix = segments.isEmpty ? "" : "\(segments.joined(separator: " "))："
        var body = "\(headerPrefix)\(occurrence.lineTextSnapshot.trimmingCharacters(in: .whitespacesAndNewlines))"
        if let translation = nonEmptyTrimmed(occurrence.lineTranslationSnapshot) {
            body += "（译文：\(translation)）"
        }
        if let contextual = nonEmptyTrimmed(occurrence.contextualMeaning) {
            body += " — 语境义：\(contextual)"
        }
        return body
    }

    static func normalizedNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func normalizedInlineText(_ text: String) -> String {
        normalizedNewlines(text)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func indentedMultilineListContent(_ text: String) -> String {
        normalizedNewlines(text)
            .replacingOccurrences(of: "\n", with: "\n  ")
    }

    static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func deduplicatedPreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }
}
