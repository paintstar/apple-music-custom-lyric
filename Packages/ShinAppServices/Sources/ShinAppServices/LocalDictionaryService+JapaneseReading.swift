import CoreFoundation
import Foundation

extension LocalDictionaryService {
    // MARK: - 字符判定

    static func containsJapaneseKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value)
        }
    }

    static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0xF900...0xFAFF).contains(value)
        }
    }

    // MARK: - 离线日语假名读音计算

    /// 基于公开 `CFStringTokenizer` 与 `CFStringTransform` 计算含汉字日语词的平假名读音。
    /// 仅处理包含汉字的查询词；优先在上下文行内按 UTF-16 精确边界分词，未对齐时回退到单词分词。
    static func japaneseReading(for query: String, contextLine: String?) -> String? {
        guard !query.isEmpty, containsKanji(query) else { return nil }

        if let contextLine, !contextLine.isEmpty {
            let nsContext = contextLine as NSString
            var searchStart = 0
            while searchStart < nsContext.length {
                let searchRange = NSRange(location: searchStart, length: nsContext.length - searchStart)
                let matchRange = nsContext.range(of: query, options: [], range: searchRange)
                guard matchRange.location != NSNotFound else { break }
                if let reading = transcribeReading(
                    in: contextLine,
                    targetRange: matchRange,
                    originalQuery: query,
                    requireExactBounds: true
                ) {
                    return reading
                }
                searchStart = matchRange.location + max(matchRange.length, 1)
            }
        }

        let fullRange = NSRange(location: 0, length: (query as NSString).length)
        return transcribeReading(
            in: query,
            targetRange: fullRange,
            originalQuery: query,
            requireExactBounds: false
        )
    }

    private static func transcribeReading(
        in text: String,
        targetRange: NSRange,
        originalQuery: String,
        requireExactBounds: Bool
    ) -> String? {
        let nsText = text as NSString
        let targetEnd = targetRange.location + targetRange.length
        guard targetRange.length > 0, targetRange.location >= 0, targetEnd <= nsText.length else {
            return nil
        }

        let locale = Locale(identifier: "ja") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, nsText.length),
            kCFStringTokenizerUnitWord,
            locale
        ) else {
            return nil
        }

        guard let pieces = collectTokenReadings(
            tokenizer: tokenizer,
            nsText: nsText,
            targetStart: targetRange.location,
            targetEnd: targetEnd,
            requireExactBounds: requireExactBounds
        ) else {
            return nil
        }

        let hiragana = convertToHiragana(pieces.joined(separator: " "))
        guard !hiragana.isEmpty, containsJapaneseKana(hiragana), hiragana != originalQuery else {
            return nil
        }
        return hiragana
    }

    private static func collectTokenReadings(
        tokenizer: CFStringTokenizer,
        nsText: NSString,
        targetStart: Int,
        targetEnd: Int,
        requireExactBounds: Bool
    ) -> [String]? {
        var firstStart: Int?
        var lastEnd: Int?
        var pieces: [String] = []

        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let tokenStart = range.location
            let tokenEnd = range.location + range.length
            if tokenEnd <= targetStart { continue }
            if tokenStart >= targetEnd { break }

            if requireExactBounds && (tokenStart < targetStart || tokenEnd > targetEnd) {
                return nil
            }

            if firstStart == nil { firstStart = tokenStart }
            lastEnd = tokenEnd
            if let piece = extractTokenReading(tokenizer: tokenizer, nsText: nsText, range: range) {
                pieces.append(piece)
            }
        }

        if requireExactBounds && (firstStart != targetStart || lastEnd != targetEnd) {
            return nil
        }
        return pieces.isEmpty ? nil : pieces
    }

    private static func extractTokenReading(
        tokenizer: CFStringTokenizer,
        nsText: NSString,
        range: CFRange
    ) -> String? {
        if let rawLatin = CFStringTokenizerCopyCurrentTokenAttribute(
            tokenizer,
            kCFStringTokenizerAttributeLatinTranscription
        ) as? String {
            let latin = rawLatin.trimmingCharacters(in: .whitespacesAndNewlines)
            if !latin.isEmpty {
                return latin
            }
        }

        let surface = nsText.substring(with: NSRange(location: range.location, length: range.length))
        return containsJapaneseKana(surface) ? surface : nil
    }

    private static func convertToHiragana(_ input: String) -> String {
        let mutable = NSMutableString(string: input)
        CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)

        let removeSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'"))
        let filteredScalars = (mutable as String).unicodeScalars.filter { !removeSet.contains($0) }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    // MARK: - 日语词典条目识别与词头匹配校验

    static func isJapaneseDictionaryEntry(_ entry: String) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let head = String(trimmed.prefix(60))
        guard containsJapaneseKana(head) else { return false }

        if let bracketStart = head.range(of: "【")?.lowerBound {
            let beforeBracket = String(head[..<bracketStart])
            if containsJapaneseKana(beforeBracket) {
                return true
            }
        }

        let leadingSkip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐・･"))
        if let firstScalar = head.unicodeScalars.first(where: { !leadingSkip.contains($0) }) {
            let value = firstScalar.value
            if (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value) {
                return true
            }
        }

        let chinesePinyinPattern = #"^[\p{Han}]+\s+[a-zA-Zāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü]"#
        if head.range(of: chinesePinyinPattern, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    static func japaneseEntry(_ entry: String, matchesTarget word: String, lemma: String?) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isJapaneseDictionaryEntry(trimmed) else { return false }

        let headRegion = String(trimmed.prefix(80))
        guard let openRange = headRegion.range(of: "【"),
              let closeRange = headRegion.range(of: "】", range: openRange.upperBound..<headRegion.endIndex) else {
            return false
        }

        let headwordText = String(headRegion[openRange.upperBound..<closeRange.lowerBound])
        let separatorSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "•・･、/,"))
        let edgeTrimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‐"))

        var targets: Set<String> = []
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWord.isEmpty { targets.insert(trimmedWord) }
        if let trimmedLemma = lemma?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedLemma.isEmpty {
            targets.insert(trimmedLemma)
        }
        guard !targets.isEmpty else { return false }

        let suffixes = ["する", "な", "的"]
        for rawCandidate in headwordText.components(separatedBy: separatorSet) {
            let candidate = rawCandidate.trimmingCharacters(in: edgeTrimSet)
            guard !candidate.isEmpty else { continue }
            if targets.contains(candidate) {
                return true
            }
            for suffix in suffixes where candidate.hasSuffix(suffix) {
                let stem = String(candidate.dropLast(suffix.count))
                if !stem.isEmpty, targets.contains(stem) {
                    return true
                }
            }
        }

        return false
    }
}
