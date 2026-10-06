import Foundation
import NaturalLanguage
import ShinAppleKit

/// 仅决定是否提示缺少中文译文；不修改歌词的语言、正文或人工译文。
enum LyricsTranslationPolicy {
    private static let kana = try? NSRegularExpression(pattern: #"[\p{script=Hiragana}\p{script=Katakana}]"#)
    private static let han = try? NSRegularExpression(pattern: #"\p{script=Han}"#)

    /// 保存的文档以 id + revision 标识内容；语言另列，便于语言标记单独更新。
    struct DocumentKey: Equatable {
        let id: UUID
        let revision: Int
        let sourceLanguage: String?

        init(_ document: LyricDocument) {
            id = document.id
            revision = document.revision
            sourceLanguage = document.sourceLanguage
        }
    }

    static func shouldShowMissingTranslation(_ document: LyricDocument) -> Bool {
        guard !document.lines.contains(where: { !$0.translations.isEmpty }) else { return false }
        return !hasChineseOriginal(document)
    }

    private static func hasChineseOriginal(_ document: LyricDocument) -> Bool {
        if let language = document.sourceLanguage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased(), let primaryLanguage = language.split(separator: "-").first, primaryLanguage != "und" {
            // 明确语言优先；日语的纯汉字也不能仅凭字形当成中文。
            return primaryLanguage == "zh"
        }
        guard let kana, let han else { return false }

        let lines = document.lines.map(\.text).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !lines.isEmpty else { return false }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            // 假名是混合日语的明确证据；不被长篇中文的总概率盖掉。
            if kana.firstMatch(in: line, range: range) != nil {
                return false
            }
            // 少量 Oh / Yeah 等不改变中文主体；完整外文句子仍需要译文。
            let letterCount = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let hanCount = han.numberOfMatches(in: line, range: range)
            if letterCount >= 12, letterCount - hanCount > hanCount { return false }
        }

        // 最多分析 4096 个正文字符，均匀取整份歌词的片段，避免大文档卡住界面。
        // 系统识别只在文档变更时运行；不足 12 个文字的短片段保留缺译文提示。
        let sampleLineCount = min(lines.count, 64)
        let charactersPerLine = 4_096 / sampleLineCount
        let sampledText = (0..<sampleLineCount).map { sampleIndex in
            let lineIndex = sampleIndex * lines.count / sampleLineCount
            return String(lines[lineIndex].prefix(charactersPerLine))
        }.joined(separator: "\n")
        guard sampledText.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 12 else {
            return false
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sampledText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let chineseProbability = (hypotheses[.simplifiedChinese] ?? 0) + (hypotheses[.traditionalChinese] ?? 0)
        // 只有高把握的中文原文才隐藏提示，未知、短文本和其它外文保留原有入口。
        return chineseProbability >= 0.9
    }
}
