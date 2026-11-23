import Foundation

enum DictionarySenseParser {
    private static let leadingGrammarTokens: Set<String> = [
        "uncountable", "countable", "formal", "informal", "plural", "singular",
        "usually", "dated", "literary", "attributive", "postpositive", "also",
        "only", "before", "noun", "passive", "figurative", "literal"
    ]

    private enum NumberedStyle {
        case bracketed
        case dotted
    }

    static func parseSenses(from sectionBody: String) -> [DictionarySenseItem] {
        let trimmed = sectionBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let chunks = splitSenseChunks(from: trimmed)
        var items: [DictionarySenseItem] = []

        for chunk in chunks {
            if let sense = buildSense(id: items.count, numberLabel: chunk.label, rawContent: chunk.body) {
                items.append(sense)
            }
        }
        return items
    }

    private static func splitSenseChunks(from text: String) -> [(label: String, body: String)] {
        let circled = splitByCircledNumbers(text)
        if !circled.isEmpty { return circled }
        let bracketed = splitBySequentialPattern(text, style: .bracketed)
        if !bracketed.isEmpty { return bracketed }
        let dotted = splitBySequentialPattern(text, style: .dotted)
        if !dotted.isEmpty { return dotted }
        return [("", text)]
    }

    private static func splitByCircledNumbers(_ text: String) -> [(label: String, body: String)] {
        var markers: [(index: String.Index, label: String)] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if DictionaryCharClassifier.isCircledNumber(char) {
                markers.append((idx, String(char)))
            }
            idx = text.index(after: idx)
        }
        guard !markers.isEmpty else { return [] }

        var result: [(String, String)] = []
        if markers[0].index > text.startIndex {
            let prefix = String(text[text.startIndex..<markers[0].index]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty, !isPureGrammarMetadataStub(prefix) {
                result.append(("", prefix))
            }
        }

        for i in markers.indices {
            let bodyStart = text.index(after: markers[i].index)
            let bodyEnd = i + 1 < markers.count ? markers[i + 1].index : text.endIndex
            let body = String(text[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result.append((markers[i].label, body))
            }
        }
        return result
    }

    private static func splitBySequentialPattern(_ text: String, style: NumberedStyle) -> [(label: String, body: String)] {
        let accepted = collectSequentialMarkers(in: text, style: style)
        guard accepted.count >= 2 || (accepted.count == 1 && accepted[0].range.lowerBound == text.startIndex) else {
            return []
        }

        var result: [(String, String)] = []
        for i in accepted.indices {
            let start = accepted[i].range.upperBound
            let end = i + 1 < accepted.count ? accepted[i + 1].range.lowerBound : text.endIndex
            let body = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result.append((String(accepted[i].num), body))
            }
        }
        return result
    }

    private static func collectSequentialMarkers(
        in text: String,
        style: NumberedStyle
    ) -> [(range: Range<String.Index>, num: Int)] {
        let pattern = style == .bracketed
            ? #"(?:^|(?<=[\s\n]))([1-9][0-9]?)(?=\[[^\]]+\])"#
            : #"(?:^|(?<=[\s\n]))([1-9][0-9]?)\.\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let firstExampleIdx = text.range(of: "▸")?.lowerBound
        var accepted: [(range: Range<String.Index>, num: Int)] = []
        var expected = 1

        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let fullRange = Range(match.range, in: text),
                  let numRange = Range(match.range(at: 1), in: text),
                  let num = Int(text[numRange]),
                  num == expected else {
                continue
            }
            if style == .dotted, expected == 1, let firstExampleIdx, fullRange.lowerBound > firstExampleIdx {
                continue
            }
            accepted.append((fullRange, num))
            expected += 1
        }
        return accepted
    }

    private static func buildSense(id: Int, numberLabel: String, rawContent: String) -> DictionarySenseItem? {
        let parts = rawContent.split(separator: "▸", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawDefinition = parts.first else { return nil }

        let (qualifier, definitionRemainder) = extractQualifier(from: rawDefinition)
        let cleanedDefinition = PinyinNoiseCleaner.clean(definitionRemainder)
        let cleanedQualifier = qualifier.map { PinyinNoiseCleaner.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }

        var examples: [DictionaryExampleItem] = []
        for rawExample in parts.dropFirst() {
            let cleanedExample = PinyinNoiseCleaner.clean(rawExample)
            guard !cleanedExample.isEmpty else { continue }
            examples.append(DictionaryExampleItem(id: examples.count, text: cleanedExample))
        }

        let finalDef = cleanedDefinition.isEmpty ? PinyinNoiseCleaner.clean(rawDefinition) : cleanedDefinition
        guard !finalDef.isEmpty || !examples.isEmpty else { return nil }

        return DictionarySenseItem(
            id: id,
            numberLabel: numberLabel,
            qualifier: cleanedQualifier,
            definition: finalDef,
            examples: examples
        )
    }

    private static func extractQualifier(from raw: String) -> (String?, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let closeIdx = trimmed.firstIndex(of: "]") {
            let afterClose = trimmed.index(after: closeIdx)
            let remainder = String(trimmed[afterClose...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return (String(trimmed[...closeIdx]), remainder)
            }
        }

        let tagPrefix = #"(?:uncountable|countable|formal|informal|plural|singular|attributive|postpositive|usually plural|before noun)"#
        let pattern = #"^((?:\#(tagPrefix)\s+){0,3}\([^()\n]+\))\s+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let qualRange = Range(match.range(at: 1), in: trimmed),
           let restRange = Range(match.range(at: 2), in: trimmed) {
            let qual = String(trimmed[qualRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(trimmed[restRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty {
                return (qual, rest)
            }
        }
        return (nil, trimmed)
    }

    private static func isPureGrammarMetadataStub(_ text: String) -> Bool {
        if text.contains(where: DictionaryCharClassifier.isCJK) { return false }
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { leadingGrammarTokens.contains($0) }
    }
}

enum DictionaryCharClassifier {
    static func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    static func isCircledNumber(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else {
            return false
        }
        return (0x2460...0x2473).contains(scalar.value)
    }
}
