import Foundation

enum DictionaryPOSCategory: Sendable {
    case noun
    case verb
    case adjective
    case adjectiveNa
    case adverb
    case preposition
    case conjunction
    case pronoun
    case interjection
    case determiner
    case particle
    case number
    case idiom
    case abbreviation
    case other
}

enum DictionaryPOSMapper {
    struct Descriptor {
        let label: String
        let compactTag: String
        let category: DictionaryPOSCategory
    }

    struct RawSection {
        let descriptor: Descriptor
        let body: String
    }

    private struct POSMatch {
        let range: Range<String.Index>
        let descriptor: Descriptor
    }

    private static let englishPhraseList: [(phrase: String, descriptor: Descriptor)] = [
        ("transitive and intransitive verb", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb)),
        ("transitive & intransitive verb", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb)),
        ("intransitive verb", Descriptor(label: "动词 (vi.)", compactTag: "vi.", category: .verb)),
        ("transitive verb", Descriptor(label: "动词 (vt.)", compactTag: "vt.", category: .verb)),
        ("phrasal verb", Descriptor(label: "短语动词 (phr. v.)", compactTag: "phr. v.", category: .verb)),
        ("auxiliary verb", Descriptor(label: "助动词 (aux.)", compactTag: "aux.", category: .verb)),
        ("modal verb", Descriptor(label: "助动词 (aux.)", compactTag: "aux.", category: .verb)),
        ("linking verb", Descriptor(label: "系动词 (link-v.)", compactTag: "link-v.", category: .verb)),
        ("noun", Descriptor(label: "名词 (n.)", compactTag: "n.", category: .noun)),
        ("verb", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb)),
        ("adjective", Descriptor(label: "形容词 (adj.)", compactTag: "adj.", category: .adjective)),
        ("adverb", Descriptor(label: "副词 (adv.)", compactTag: "adv.", category: .adverb)),
        ("preposition", Descriptor(label: "介词 (prep.)", compactTag: "prep.", category: .preposition)),
        ("conjunction", Descriptor(label: "连词 (conj.)", compactTag: "conj.", category: .conjunction)),
        ("pronoun", Descriptor(label: "代词 (pron.)", compactTag: "pron.", category: .pronoun)),
        ("exclamation", Descriptor(label: "感叹词 (int.)", compactTag: "int.", category: .interjection)),
        ("interjection", Descriptor(label: "感叹词 (int.)", compactTag: "int.", category: .interjection)),
        ("determiner", Descriptor(label: "限定词 (det.)", compactTag: "det.", category: .determiner)),
        ("number", Descriptor(label: "数词 (num.)", compactTag: "num.", category: .number)),
        ("abbreviation", Descriptor(label: "缩写 (abbr.)", compactTag: "abbr.", category: .abbreviation)),
        ("idiom", Descriptor(label: "习语", compactTag: "idiom", category: .idiom))
    ]

    private static let abbreviationMap: [(token: String, descriptor: Descriptor)] = [
        ("phr. v.", Descriptor(label: "短语动词 (phr. v.)", compactTag: "phr. v.", category: .verb)),
        ("interj.", Descriptor(label: "感叹词 (int.)", compactTag: "int.", category: .interjection)),
        ("prep.", Descriptor(label: "介词 (prep.)", compactTag: "prep.", category: .preposition)),
        ("conj.", Descriptor(label: "连词 (conj.)", compactTag: "conj.", category: .conjunction)),
        ("pron.", Descriptor(label: "代词 (pron.)", compactTag: "pron.", category: .pronoun)),
        ("abbr.", Descriptor(label: "缩写 (abbr.)", compactTag: "abbr.", category: .abbreviation)),
        ("adj.", Descriptor(label: "形容词 (adj.)", compactTag: "adj.", category: .adjective)),
        ("adv.", Descriptor(label: "副词 (adv.)", compactTag: "adv.", category: .adverb)),
        ("aux.", Descriptor(label: "助动词 (aux.)", compactTag: "aux.", category: .verb)),
        ("det.", Descriptor(label: "限定词 (det.)", compactTag: "det.", category: .determiner)),
        ("num.", Descriptor(label: "数词 (num.)", compactTag: "num.", category: .number)),
        ("int.", Descriptor(label: "感叹词 (int.)", compactTag: "int.", category: .interjection)),
        ("vi.", Descriptor(label: "动词 (vi.)", compactTag: "vi.", category: .verb)),
        ("vt.", Descriptor(label: "动词 (vt.)", compactTag: "vt.", category: .verb)),
        ("n.", Descriptor(label: "名词 (n.)", compactTag: "n.", category: .noun)),
        ("v.", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb))
    ]

    private static let japaneseMarkerMap: [(token: String, descriptor: Descriptor)] = [
        ("［動自］", Descriptor(label: "动词 (vi.)", compactTag: "vi.", category: .verb)),
        ("［動他］", Descriptor(label: "动词 (vt.)", compactTag: "vt.", category: .verb)),
        ("［自動］", Descriptor(label: "动词 (vi.)", compactTag: "vi.", category: .verb)),
        ("［他動］", Descriptor(label: "动词 (vt.)", compactTag: "vt.", category: .verb)),
        ("［形動］", Descriptor(label: "形容动词 (adj-na)", compactTag: "adj-na", category: .adjectiveNa)),
        ("[形動]", Descriptor(label: "形容动词 (adj-na)", compactTag: "adj-na", category: .adjectiveNa)),
        ("［名］", Descriptor(label: "名词 (n.)", compactTag: "n.", category: .noun)),
        ("[名]", Descriptor(label: "名词 (n.)", compactTag: "n.", category: .noun)),
        ("（名）", Descriptor(label: "名词 (n.)", compactTag: "n.", category: .noun)),
        ("［動］", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb)),
        ("[動]", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb)),
        ("（動）", Descriptor(label: "动词 (v.)", compactTag: "v.", category: .verb)),
        ("［形］", Descriptor(label: "形容词 (adj.)", compactTag: "adj.", category: .adjective)),
        ("[形]", Descriptor(label: "形容词 (adj.)", compactTag: "adj.", category: .adjective)),
        ("（形）", Descriptor(label: "形容词 (adj.)", compactTag: "adj.", category: .adjective)),
        ("［副］", Descriptor(label: "副词 (adv.)", compactTag: "adv.", category: .adverb)),
        ("[副]", Descriptor(label: "副词 (adv.)", compactTag: "adv.", category: .adverb)),
        ("（副）", Descriptor(label: "副词 (adv.)", compactTag: "adv.", category: .adverb)),
        ("［代］", Descriptor(label: "代词 (pron.)", compactTag: "pron.", category: .pronoun)),
        ("［接］", Descriptor(label: "连词 (conj.)", compactTag: "conj.", category: .conjunction)),
        ("［助］", Descriptor(label: "助词", compactTag: "助词", category: .particle)),
        ("［感］", Descriptor(label: "感叹词 (int.)", compactTag: "int.", category: .interjection)),
        ("［数］", Descriptor(label: "数词 (num.)", compactTag: "num.", category: .number))
    ]

    private static let contextPOSAliases: [String: DictionaryPOSCategory] = [
        "动词": .verb, "verb": .verb, "v": .verb, "v.": .verb,
        "名词": .noun, "noun": .noun, "n": .noun, "n.": .noun,
        "形容词": .adjective, "adjective": .adjective, "adj": .adjective, "adj.": .adjective,
        "形容动词": .adjectiveNa,
        "副词": .adverb, "adverb": .adverb, "adv": .adverb, "adv.": .adverb,
        "介词": .preposition, "preposition": .preposition, "prep": .preposition, "prep.": .preposition,
        "连词": .conjunction, "conjunction": .conjunction, "conj": .conjunction, "conj.": .conjunction,
        "代词": .pronoun, "pronoun": .pronoun, "pron": .pronoun, "pron.": .pronoun,
        "感叹词": .interjection, "exclamation": .interjection, "interjection": .interjection,
        "int.": .interjection, "interj.": .interjection,
        "限定词": .determiner, "determiner": .determiner, "det": .determiner, "det.": .determiner,
        "助词": .particle, "particle": .particle,
        "数词": .number, "number": .number, "num": .number, "num.": .number,
        "习语": .idiom, "idiom": .idiom
    ]

    static func splitSections(in body: String, hasHeader: Bool) -> [RawSection] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let markers = collectMarkers(in: trimmed, hasHeader: hasHeader)
        guard !markers.isEmpty else {
            return [RawSection(
                descriptor: Descriptor(label: "释义", compactTag: "", category: .other),
                body: trimmed
            )]
        }

        var result: [RawSection] = []
        if markers[0].range.lowerBound > trimmed.startIndex {
            let leading = String(trimmed[trimmed.startIndex..<markers[0].range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !leading.isEmpty {
                result.append(RawSection(
                    descriptor: Descriptor(label: "释义", compactTag: "", category: .other),
                    body: leading
                ))
            }
        }

        for index in markers.indices {
            let start = markers[index].range.upperBound
            let end = index + 1 < markers.count ? markers[index + 1].range.lowerBound : trimmed.endIndex
            let sectionBody = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sectionBody.isEmpty {
                result.append(RawSection(descriptor: markers[index].descriptor, body: sectionBody))
            }
        }
        return result
    }

    static func matches(category: DictionaryPOSCategory, compactTag: String, contextPOS: String?) -> Bool {
        guard let rawPOS = contextPOS?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPOS.isEmpty else {
            return false
        }
        let lower = rawPOS.lowercased()

        if lower == "vi" || lower == "vi." || rawPOS == "不及物动词" {
            return compactTag == "vi."
        }
        if lower == "vt" || lower == "vt." || rawPOS == "及物动词" {
            return compactTag == "vt."
        }

        guard let mapped = resolveContextCategory(lower: lower, original: rawPOS) else {
            return false
        }
        if mapped == .adjective && category == .adjectiveNa {
            return true
        }
        return category == mapped
    }

    private static func resolveContextCategory(lower: String, original: String) -> DictionaryPOSCategory? {
        if let direct = contextPOSAliases[lower] {
            return direct
        }
        if original.contains("动词") && !original.contains("形容动词") { return .verb }
        if original.contains("名词") { return .noun }
        if original.contains("形容词") { return .adjective }
        if original.contains("副词") { return .adverb }
        return nil
    }

    private static func collectMarkers(in text: String, hasHeader: Bool) -> [POSMatch] {
        var matches: [POSMatch] = []
        var parenDepth = 0
        var angleDepth = 0
        var inExample = false
        var index = text.startIndex

        while index < text.endIndex {
            let char = text[index]
            if char == "\n" {
                inExample = false
            } else if char == "▸" {
                inExample = true
            } else {
                parenDepth = updatedDepth(parenDepth, char: char, open: "(", close: ")")
                angleDepth = updatedDepth(angleDepth, char: char, open: "‹", close: "›")

                if parenDepth == 0, angleDepth == 0,
                   let hit = matchSectionHeader(in: text, at: index, inExample: inExample, hasHeader: hasHeader),
                   matches.last.map({ $0.range.upperBound <= hit.range.lowerBound }) ?? true {
                    matches.append(hit)
                    inExample = false
                    index = hit.range.upperBound
                    continue
                }
            }
            index = text.index(after: index)
        }
        return matches
    }

    private static func updatedDepth(_ depth: Int, char: Character, open: Character, close: Character) -> Int {
        if char == open { return depth + 1 }
        if char == close, depth > 0 { return depth - 1 }
        return depth
    }

    private static func matchSectionHeader(
        in text: String,
        at index: String.Index,
        inExample: Bool,
        hasHeader: Bool
    ) -> POSMatch? {
        let isStartOfLine = index == text.startIndex || text[text.index(before: index)] == "\n"

        if let prefixed = matchLetterPrefixedPOS(in: text, at: index) {
            return prefixed
        }
        if !inExample, let japanese = matchJapanesePOS(in: text, at: index) {
            return japanese
        }
        if isStartOfLine || !inExample, let abbrev = matchAbbrevPOS(in: text, at: index, isStartOfLine: isStartOfLine) {
            return abbrev
        }
        if isStartOfLine, let bare = matchBareEnglishPOSAtLineStart(
            in: text,
            at: index,
            allowEnglishBody: hasHeader && index == text.startIndex
        ) {
            return bare
        }
        return nil
    }

    private static func matchLetterPrefixedPOS(in text: String, at index: String.Index) -> POSMatch? {
        guard index == text.startIndex || !isASCIILetterOrDigit(text[text.index(before: index)]) else {
            return nil
        }
        let slice = text[index...]
        guard let first = slice.first, first >= "A" && first <= "Z" else { return nil }
        let afterLetter = slice.index(after: slice.startIndex)
        guard afterLetter < slice.endIndex, slice[afterLetter] == "." else { return nil }
        var posStart = slice.index(after: afterLetter)
        while posStart < slice.endIndex, slice[posStart] == " " {
            posStart = slice.index(after: posStart)
        }
        guard posStart > slice.index(after: afterLetter) else { return nil }
        for item in englishPhraseList {
            if let end = matchExactPhrase(item.phrase, in: text, from: posStart) {
                return POSMatch(range: index..<end, descriptor: item.descriptor)
            }
        }
        return nil
    }

    private static func matchBareEnglishPOSAtLineStart(
        in text: String,
        at index: String.Index,
        allowEnglishBody: Bool
    ) -> POSMatch? {
        for item in englishPhraseList {
            if let end = matchExactPhrase(item.phrase, in: text, from: index) {
                let tail = text[end...].trimmingCharacters(in: .whitespaces)
                guard !tail.isEmpty, allowEnglishBody || looksLikePOSBodyStart(tail) else { continue }
                return POSMatch(range: index..<end, descriptor: item.descriptor)
            }
        }
        return nil
    }

    private static func matchJapanesePOS(in text: String, at index: String.Index) -> POSMatch? {
        for item in japaneseMarkerMap where text[index...].hasPrefix(item.token) {
            let end = text.index(index, offsetBy: item.token.count)
            return POSMatch(range: index..<end, descriptor: item.descriptor)
        }
        return nil
    }

    private static func matchAbbrevPOS(in text: String, at index: String.Index, isStartOfLine: Bool) -> POSMatch? {
        if !isStartOfLine {
            let prev = text[text.index(before: index)]
            guard prev == " " || prev == ";" || prev == "；" || DictionaryCharClassifier.isCJK(prev) else {
                return nil
            }
        }
        for item in abbreviationMap where text[index...].hasPrefix(item.token) {
            let end = text.index(index, offsetBy: item.token.count)
            guard end < text.endIndex else { continue }
            let nextChar = text[end]
            guard nextChar == " " || nextChar == "\n"
                    || DictionaryCharClassifier.isCircledNumber(nextChar)
                    || DictionaryCharClassifier.isCJK(nextChar) else {
                continue
            }
            if item.token == "n." || item.token == "v.", !isStartOfLine {
                let tail = text[end...].trimmingCharacters(in: .whitespaces)
                guard let tailFirst = tail.first,
                      DictionaryCharClassifier.isCJK(tailFirst)
                        || DictionaryCharClassifier.isCircledNumber(tailFirst)
                        || tailFirst == "("
                        || tailFirst == "[" else {
                    continue
                }
            }
            return POSMatch(range: index..<end, descriptor: item.descriptor)
        }
        return nil
    }

    private static func matchExactPhrase(_ phrase: String, in text: String, from start: String.Index) -> String.Index? {
        let slice = text[start...]
        guard slice.lowercased().hasPrefix(phrase) else { return nil }
        let end = text.index(start, offsetBy: phrase.count)
        if end < text.endIndex {
            let next = text[end]
            guard next == " " || next == "\n" || DictionaryCharClassifier.isCircledNumber(next) else { return nil }
        }
        return end
    }

    private static func looksLikePOSBodyStart(_ tail: String) -> Bool {
        guard let first = tail.first else { return false }
        if DictionaryCharClassifier.isCircledNumber(first)
            || DictionaryCharClassifier.isCJK(first)
            || first == "(" || first == "[" || first.isNumber {
            return true
        }
        let lower = tail.lowercased()
        let oxfordTags = [
            "uncountable", "countable", "formal", "informal", "plural",
            "singular", "usually", "dated", "literary", "attributive", "postpositive"
        ]
        return oxfordTags.contains { lower.hasPrefix($0) }
    }

    private static func isASCIILetterOrDigit(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber)
    }
}
