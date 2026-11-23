import Foundation
import ShinAppleKit

/// 清洗后的词典例句/短语条目。
public struct DictionaryExampleItem: Equatable, Sendable, Identifiable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// 清洗后的单个词典义项。
public struct DictionarySenseItem: Equatable, Sendable, Identifiable {
    public let id: Int
    public let numberLabel: String
    public let qualifier: String?
    public let definition: String
    public let examples: [DictionaryExampleItem]

    public init(
        id: Int,
        numberLabel: String,
        qualifier: String? = nil,
        definition: String,
        examples: [DictionaryExampleItem] = []
    ) {
        self.id = id
        self.numberLabel = numberLabel
        self.qualifier = qualifier
        self.definition = definition
        self.examples = examples
    }
}

/// 按词性组织的词典释义分节。
public struct DictionaryPOSSection: Equatable, Sendable, Identifiable {
    public let id: Int
    public let partOfSpeechLabel: String
    public let compactTag: String
    public let isContextMatch: Bool
    public let senses: [DictionarySenseItem]

    public init(
        id: Int,
        partOfSpeechLabel: String,
        compactTag: String,
        isContextMatch: Bool,
        senses: [DictionarySenseItem]
    ) {
        self.id = id
        self.partOfSpeechLabel = partOfSpeechLabel
        self.compactTag = compactTag
        self.isContextMatch = isContextMatch
        self.senses = senses
    }
}

/// 面向划词弹窗与生词本默认释义的结构化词典结果。
public struct FormattedDictionaryEntry: Equatable, Sendable {
    public let headword: String?
    public let phonetics: String?
    public let sections: [DictionaryPOSSection]
    public let conciseMeaning: String
    public let fallbackRawText: String?

    public init(
        headword: String?,
        phonetics: String?,
        sections: [DictionaryPOSSection],
        conciseMeaning: String,
        fallbackRawText: String?
    ) {
        self.headword = headword
        self.phonetics = phonetics
        self.sections = sections
        self.conciseMeaning = conciseMeaning
        self.fallbackRawText = fallbackRawText
    }
}

/// 本机系统词典纯文本的结构化清洗与解析器。
public enum LocalDictionaryFormatter {
    private struct ParsedSection {
        let label: String
        let compactTag: String
        let isMatch: Bool
        let senses: [DictionarySenseItem]
    }

    /// 将 `LocalDictionaryLookupResult` 解析为结构化释义；当 `systemDefinition` 为空或全空白时返回 `nil`。
    public static func format(_ lookup: LocalDictionaryLookupResult) -> FormattedDictionaryEntry? {
        guard let raw = lookup.systemDefinition?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let normalized = normalizeWhitespace(raw)
        let header = DictionaryHeaderExtractor.extract(from: normalized)
        let hasHeader = header.headword != nil || header.phonetics != nil
        let rawSections = DictionaryPOSMapper.splitSections(in: header.body, hasHeader: hasHeader)
        let contextPOS = lookup.partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines)

        var matched: [ParsedSection] = []
        var unmatched: [ParsedSection] = []

        for rawSection in rawSections {
            let senses = DictionarySenseParser.parseSenses(from: rawSection.body)
            guard !senses.isEmpty else { continue }
            let isMatch = DictionaryPOSMapper.matches(
                category: rawSection.descriptor.category,
                compactTag: rawSection.descriptor.compactTag,
                contextPOS: contextPOS
            )
            let item = ParsedSection(
                label: rawSection.descriptor.label,
                compactTag: rawSection.descriptor.compactTag,
                isMatch: isMatch,
                senses: senses
            )
            if isMatch {
                matched.append(item)
            } else {
                unmatched.append(item)
            }
        }

        let sections = (matched + unmatched).enumerated().map { index, item in
            DictionaryPOSSection(
                id: index,
                partOfSpeechLabel: item.label,
                compactTag: item.compactTag,
                isContextMatch: item.isMatch,
                senses: item.senses
            )
        }

        let fallbackRaw: String?
        if sections.isEmpty {
            let source = header.body.isEmpty ? normalized : header.body
            let cleanedBody = PinyinNoiseCleaner.clean(source)
            fallbackRaw = cleanedBody.isEmpty ? normalized : cleanedBody
        } else {
            fallbackRaw = nil
        }

        let concise = ConciseMeaningBuilder.build(from: sections, fallbackText: fallbackRaw)
        let fallbackReading = lookup.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPhonetics = header.phonetics
            ?? ((fallbackReading?.isEmpty == false) ? fallbackReading : nil)

        return FormattedDictionaryEntry(
            headword: header.headword,
            phonetics: resolvedPhonetics,
            sections: sections,
            conciseMeaning: concise,
            fallbackRawText: fallbackRaw
        )
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 头部音标提取

private enum DictionaryHeaderExtractor {
    struct HeaderResult {
        let headword: String?
        let phonetics: String?
        let body: String
    }

    static func extract(from text: String) -> HeaderResult {
        if let oxford = extractOxfordPipeHeader(from: text) {
            return oxford
        }
        if let japanese = extractJapaneseHeader(from: text) {
            return japanese
        }
        if let slashIPA = extractSlashIPAHeader(from: text) {
            return slashIPA
        }
        return HeaderResult(headword: nil, phonetics: nil, body: text)
    }

    private static func extractOxfordPipeHeader(from text: String) -> HeaderResult? {
        let pattern = #"^([^|\n]{1,60}?)\s*\|\s*([^|\n]{1,140}?)\s*\|\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let headRange = Range(match.range(at: 1), in: text),
              let phonRange = Range(match.range(at: 2), in: text),
              let bodyRange = Range(match.range(at: 3), in: text) else {
            return nil
        }

        let rawHead = String(text[headRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPhon = String(text[phonRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        let headword = cleanHeadword(rawHead)
        let phonetics = formatOxfordPhonetics(rawPhon)
        return HeaderResult(headword: headword, phonetics: phonetics, body: body)
    }

    private static func cleanHeadword(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func formatOxfordPhonetics(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hasBrE = trimmed.contains("BrE ")
        let hasAmE = trimmed.contains("AmE ")
        guard hasBrE || hasAmE else {
            return wrapSinglePhonetic(trimmed)
        }

        var parts: [String] = []
        if let brIPA = extractRegionalIPA(marker: "BrE ", otherMarker: "AmE ", from: trimmed) {
            parts.append("BrE \(wrapCommaIPA(brIPA))")
        }
        if let amIPA = extractRegionalIPA(marker: "AmE ", otherMarker: "BrE ", from: trimmed) {
            parts.append("AmE \(wrapCommaIPA(amIPA))")
        }
        return parts.isEmpty ? trimmed : parts.joined(separator: " · ")
    }

    private static func extractRegionalIPA(marker: String, otherMarker: String, from text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let afterMarker = text[markerRange.upperBound...]
        let end = afterMarker.range(of: otherMarker)?.lowerBound ?? afterMarker.endIndex
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        let ipa = String(afterMarker[..<end]).trimmingCharacters(in: trimSet)
        return ipa.isEmpty ? nil : ipa
    }

    private static func wrapCommaIPA(_ raw: String) -> String {
        raw.split(separator: ",")
            .map { wrapSinglePhonetic(String($0).trimmingCharacters(in: .whitespaces)) }
            .joined(separator: ", ")
    }

    private static func wrapSinglePhonetic(_ token: String) -> String {
        guard !token.isEmpty else { return token }
        if (token.hasPrefix("/") && token.hasSuffix("/")) || (token.hasPrefix("[") && token.hasSuffix("]")) {
            return token
        }
        return "/\(token)/"
    }

    private static func extractJapaneseHeader(from text: String) -> HeaderResult? {
        let pattern = #"^([ぁ-んァ-ヶー・･‐\-\s]{1,40}?)\s*【([^】\n]{1,40})】\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let readingRange = Range(match.range(at: 1), in: text),
              let wordRange = Range(match.range(at: 2), in: text),
              let bodyRange = Range(match.range(at: 3), in: text) else {
            return nil
        }

        let reading = String(text[readingRange])
            .replacingOccurrences(of: #"[‐\-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard reading.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) else {
            return nil
        }
        let word = String(text[wordRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return HeaderResult(
            headword: word.isEmpty ? nil : word,
            phonetics: reading.isEmpty ? nil : reading,
            body: body
        )
    }

    private static func extractSlashIPAHeader(from text: String) -> HeaderResult? {
        let pattern = #"^([^\s/|:,;\(\)\n][^/|:,;\(\)\n]{0,30}?)\s+/(\S[^/\n]{0,58}?\S|\S)/(?:\s+(.*)|$)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let headRange = Range(match.range(at: 1), in: text),
              let ipaRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let headword = String(text[headRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let ipa = String(text[ipaRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let bodyRange = Range(match.range(at: 3), in: text) {
            body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = ""
        }
        guard !headword.isEmpty, !ipa.isEmpty else { return nil }
        return HeaderResult(headword: headword, phonetics: "/\(ipa)/", body: body)
    }
}

// MARK: - 精炼释义摘要

private enum ConciseMeaningBuilder {
    private static let maxLength = 85

    static func build(from sections: [DictionaryPOSSection], fallbackText: String?) -> String {
        var sectionParts: [String] = []

        for section in sections.prefix(2) {
            var glosses: [String] = []
            for sense in section.senses.prefix(2) {
                let gloss = extractCoreGloss(from: sense.definition)
                if !gloss.isEmpty, !glosses.contains(gloss) {
                    glosses.append(gloss)
                }
            }
            guard !glosses.isEmpty else { continue }
            let joinedGloss = glosses.joined(separator: "；")
            if section.compactTag.isEmpty {
                sectionParts.append(joinedGloss)
            } else {
                sectionParts.append("\(section.compactTag) \(joinedGloss)")
            }
        }

        var combined = sectionParts.joined(separator: " · ")
        if combined.isEmpty, let fallbackText {
            combined = extractCoreGloss(from: fallbackText)
        }
        combined = combined
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if combined.count <= maxLength {
            return combined
        }

        if sectionParts.count > 1, sectionParts[0].count <= maxLength {
            return sectionParts[0]
        }
        return String(combined.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func extractCoreGloss(from rawDefinition: String) -> String {
        var text = rawDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = text.replacingOccurrences(of: #"‹[^›]+›"#, with: "", options: .regularExpression)

        if text.contains(where: DictionaryCharClassifier.isCJK) {
            if let englishTagRange = text.range(of: #"\s+English\b"#, options: .regularExpression) {
                let prefix = String(text[..<englishTagRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if prefix.contains(where: DictionaryCharClassifier.isCJK) {
                    text = prefix
                }
            }
            text = text.replacingOccurrences(of: #"\([^()\n]*\)"#, with: "", options: .regularExpression)
            let registerPattern = #"\b(?:figurative|literal|informal|formal|dated|literary|"#
                + #"British|US|before noun|attributive|postpositive)\b"#
            text = text.replacingOccurrences(of: registerPattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。：:·"))
        let primarySegment = text
            .split(whereSeparator: { $0 == ";" || $0 == "；" })
            .map { String($0).trimmingCharacters(in: trimSet) }
            .first(where: { !$0.isEmpty }) ?? ""

        return primarySegment
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
