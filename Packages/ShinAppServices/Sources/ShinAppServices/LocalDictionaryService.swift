import CoreServices
import Foundation
import NaturalLanguage
import ShinAppleKit

/// 本机离线词典与词形分析服务协议。
public protocol LocalDictionaryLookupProviding: Sendable {
    func lookup(_ query: String, contextLine: String?) -> LocalDictionaryLookupResult
}

public extension LocalDictionaryLookupProviding {
    func lookup(_ query: String) -> LocalDictionaryLookupResult {
        lookup(query, contextLine: nil)
    }
}

/// 基于系统 `CoreServices`（`DCSCopyTextDefinition`）与 `NaturalLanguage` 的离线查词服务。
/// 每次查询均在栈内创建局部识别器与标注器，无共享可变状态，满足 Swift 6 并发安全。
public struct LocalDictionaryService: LocalDictionaryLookupProviding, Sendable {
    private let definitionLookup: @Sendable (String) -> String?

    public init() {
        self.definitionLookup = Self.copySystemDefinition(for:)
    }

    internal init(definitionLookup: @escaping @Sendable (String) -> String?) {
        self.definitionLookup = definitionLookup
    }

    /// 查询词形原形（lemma）、中文词性、语种、假名读音与本机系统词典释义；空白输入直接返回空结果。
    public func lookup(_ query: String, contextLine: String? = nil) -> LocalDictionaryLookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LocalDictionaryLookupResult(query: "")
        }

        let cleanContext = contextLine?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveContext = (cleanContext?.isEmpty == false) ? cleanContext : nil

        let detectedLanguage = Self.detectLanguage(for: trimmed, contextLine: effectiveContext)
        let morphology = Self.analyzeMorphology(
            for: trimmed,
            contextLine: effectiveContext,
            language: detectedLanguage
        )
        let reading = detectedLanguage == .japanese
            ? Self.japaneseReading(for: trimmed, contextLine: effectiveContext)
            : nil
        let definition = lookupSystemDefinition(
            for: trimmed,
            lemma: morphology.lemma,
            language: detectedLanguage,
            japaneseReading: reading
        )

        return LocalDictionaryLookupResult(
            query: trimmed,
            lemma: morphology.lemma,
            partOfSpeech: morphology.partOfSpeech,
            detectedLanguage: detectedLanguage?.rawValue,
            systemDefinition: definition,
            reading: reading
        )
    }

    // MARK: - 语种与词形分析

    private static func detectLanguage(for query: String, contextLine: String?) -> NLLanguage? {
        let hasKana = containsJapaneseKana(query) || (contextLine.map(containsJapaneseKana) ?? false)
        let recognizer = NLLanguageRecognizer()
        if let contextLine {
            recognizer.processString(contextLine)
            if let contextLanguage = recognizer.dominantLanguage, contextLanguage != .undetermined {
                if hasKana && isChineseLanguage(contextLanguage) {
                    return .japanese
                }
                return contextLanguage
            }
            if hasKana {
                return .japanese
            }
            recognizer.reset()
        }
        recognizer.processString(query)
        if let dominant = recognizer.dominantLanguage, dominant != .undetermined {
            if hasKana && isChineseLanguage(dominant) {
                return .japanese
            }
            return dominant
        }
        if hasKana {
            return .japanese
        }
        let tagger = NLTagger(tagSchemes: [.language])
        tagger.string = contextLine ?? query
        if let dominant = tagger.dominantLanguage, dominant != .undetermined {
            if hasKana && isChineseLanguage(dominant) {
                return .japanese
            }
            return dominant
        }
        return nil
    }

    private static func isChineseLanguage(_ language: NLLanguage) -> Bool {
        language == .simplifiedChinese || language == .traditionalChinese
    }

    private struct MorphologyResult {
        let lemma: String?
        let partOfSpeech: String?
    }

    private static func analyzeMorphology(
        for word: String,
        contextLine: String?,
        language: NLLanguage?
    ) -> MorphologyResult {
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        let targetText: String
        let probeRange: Range<String.Index>

        if let contextLine, let rangeInContext = contextLine.range(of: word) {
            targetText = contextLine
            probeRange = rangeInContext
        } else {
            targetText = word
            probeRange = word.startIndex..<word.endIndex
        }

        tagger.string = targetText
        if let language {
            tagger.setLanguage(language, range: targetText.startIndex..<targetText.endIndex)
        }

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
        var detectedLemma: String?
        var detectedPOS: String?

        tagger.enumerateTags(in: probeRange, unit: .word, scheme: .lemma, options: options) { tag, _ in
            if let raw = tag?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                detectedLemma = raw
            }
            return false
        }

        tagger.enumerateTags(in: probeRange, unit: .word, scheme: .lexicalClass, options: options) { tag, _ in
            if let tag, let pos = chinesePartOfSpeech(for: tag) {
                detectedPOS = pos
            }
            return false
        }

        return MorphologyResult(lemma: detectedLemma, partOfSpeech: detectedPOS)
    }

    private static let posDisplayMap: [NLTag: String] = [
        .noun: "名词",
        .verb: "动词",
        .adjective: "形容词",
        .adverb: "副词",
        .pronoun: "代词",
        .determiner: "限定词",
        .particle: "助词",
        .preposition: "介词",
        .conjunction: "连词",
        .interjection: "感叹词",
        .number: "数词",
        .classifier: "量词",
        .idiom: "习语",
        .otherWord: "词"
    ]

    private static func chinesePartOfSpeech(for tag: NLTag) -> String? {
        posDisplayMap[tag]
    }

    // MARK: - macOS 系统词典

    private func lookupSystemDefinition(
        for word: String,
        lemma: String?,
        language: NLLanguage?,
        japaneseReading: String?
    ) -> String? {
        guard language == .japanese else {
            if let direct = definitionLookup(word) {
                return direct
            }
            if let lemma, lemma != word, let fallback = definitionLookup(lemma) {
                return fallback
            }
            return nil
        }

        return lookupJapaneseSystemDefinition(
            for: word,
            lemma: lemma,
            japaneseReading: japaneseReading
        )
    }

    private func lookupJapaneseSystemDefinition(
        for word: String,
        lemma: String?,
        japaneseReading: String?
    ) -> String? {
        let direct = definitionLookup(word)
        if let direct, Self.isJapaneseDictionaryEntry(direct) {
            return direct
        }

        if let japaneseReading, !japaneseReading.isEmpty,
           let viaReading = definitionLookup(japaneseReading),
           Self.japaneseEntry(viaReading, matchesTarget: word, lemma: lemma) {
            return viaReading
        }

        if let lemma, !lemma.isEmpty, lemma != word {
            let lemmaDirect = definitionLookup(lemma)
            if let lemmaDirect, Self.isJapaneseDictionaryEntry(lemmaDirect) {
                return lemmaDirect
            }
            if let lemmaReading = Self.japaneseReading(for: lemma, contextLine: nil),
               lemmaReading != japaneseReading,
               let lemmaViaReading = definitionLookup(lemmaReading),
               Self.japaneseEntry(lemmaViaReading, matchesTarget: lemma, lemma: word) {
                return lemmaViaReading
            }
            return direct ?? lemmaDirect
        }

        return direct
    }

    private static func copySystemDefinition(for word: String) -> String? {
        guard !word.isEmpty else { return nil }
        guard let cfDefinition = DCSCopyTextDefinition(
            nil,
            word as CFString,
            CFRangeMake(0, word.utf16.count)
        ) else {
            return nil
        }
        let text = (cfDefinition.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
