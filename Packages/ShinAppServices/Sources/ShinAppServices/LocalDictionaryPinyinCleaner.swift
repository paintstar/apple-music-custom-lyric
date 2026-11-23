import Foundation

private enum PinyinLexicon {
    static let toneCharMap: [Character: (base: Character, tone: Int)] = [
        "ā": ("a", 1), "á": ("a", 2), "ǎ": ("a", 3), "à": ("a", 4),
        "ē": ("e", 1), "é": ("e", 2), "ě": ("e", 3), "è": ("e", 4),
        "ī": ("i", 1), "í": ("i", 2), "ǐ": ("i", 3), "ì": ("i", 4),
        "ō": ("o", 1), "ó": ("o", 2), "ǒ": ("o", 3), "ò": ("o", 4),
        "ū": ("u", 1), "ú": ("u", 2), "ǔ": ("u", 3), "ù": ("u", 4),
        "ǖ": ("v", 1), "ǘ": ("v", 2), "ǚ": ("v", 3), "ǜ": ("v", 4),
        "ü": ("v", 0)
    ]

    static let validSyllables: Set<String> = Set(
        """
        a ai an ang ao e ei en eng er o ou
        ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        fa fan fang fei fen feng fo fou fu
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo
        cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo
        sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo
        ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
        za zai zan zang zao ze zei zen zeng zi zong zou zu zuan zui zun zuo
        ca cai can cang cao ce cen ceng ci cong cou cu cuan cui cun cuo
        sa sai san sang sao se sen seng si song sou su suan sui sun suo
        ya yao ye you yan yin yang ying yong yi
        wa wo wai wei wan wen wang weng wu
        yu yue yuan yun
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    )
}

enum PinyinNoiseCleaner {
    private struct SpanMatch {
        let end: String.Index
        let needsSpaceSeparator: Bool
    }

    private struct SpanTail {
        let end: String.Index
        let hasTone: Bool
        let needsSpace: Bool
        let addedWords: Int
    }

    private struct WordMatch {
        let end: String.Index
        let hasTone: Bool
        let splitMidWord: Bool
        let wordText: String
    }

    private struct ExtractedCharacters {
        let bases: [Character]
        let tones: [Int]
        let hasTone: Bool
    }

    static func clean(_ text: String) -> String {
        guard text.contains(where: isToneMarkedPinyinVowel) else {
            return collapseSpaces(text)
        }

        var output = ""
        var afterCJK = false
        var lastTrailingPunct: Character?
        var idx = text.startIndex

        while idx < text.endIndex {
            let char = text[idx]

            if afterCJK, let span = scanPinyinSpan(in: text, from: idx, prevPunct: lastTrailingPunct) {
                if span.needsSpaceSeparator, let last = output.last, !last.isWhitespace {
                    output.append(" ")
                }
                idx = span.end
                afterCJK = false
                lastTrailingPunct = nil
                continue
            }

            output.append(char)

            if DictionaryCharClassifier.isCJK(char) {
                afterCJK = true
                lastTrailingPunct = nil
            } else if isResetCharacter(char) {
                afterCJK = false
                lastTrailingPunct = nil
            } else if afterCJK, isTrailingCJKPunct(char) {
                lastTrailingPunct = char
            }

            idx = text.index(after: idx)
        }

        return tidyCleanedOutput(output)
    }

    private static func scanPinyinSpan(
        in text: String,
        from start: String.Index,
        prevPunct: Character?
    ) -> SpanMatch? {
        guard let cursor = resolveSpanStart(in: text, from: start),
              let firstWord = matchPinyinWord(in: text, from: cursor) else {
            return nil
        }

        var end = firstWord.end
        var hasTone = firstWord.hasTone
        var needsSpace = firstWord.splitMidWord
        var wordCount = 1

        if !firstWord.splitMidWord {
            let tail = extendPinyinSpan(in: text, from: end, initialTone: hasTone)
            end = tail.end
            hasTone = tail.hasTone
            needsSpace = tail.needsSpace
            wordCount += tail.addedWords
        }

        guard hasTone else { return nil }
        if isLikelyFrenchSingleCharPhrase(
            firstWord: firstWord.wordText,
            wordCount: wordCount,
            in: text,
            at: end
        ) {
            return nil
        }

        if let prevPunct, prevPunct == "？" || prevPunct == "！", end < text.endIndex, text[end] == prevPunct {
            end = text.index(after: end)
        }
        return SpanMatch(end: end, needsSpaceSeparator: needsSpace)
    }

    private static func resolveSpanStart(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex, text[cursor] == " " {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }

        // 支持 "…的管理 … de guǎnlǐ" 形式，仅当 … 前有空格时纳入拼音范围
        if text[cursor] == "…", cursor > start {
            var afterEllipsis = text.index(after: cursor)
            while afterEllipsis < text.endIndex, text[afterEllipsis] == " " {
                afterEllipsis = text.index(after: afterEllipsis)
            }
            if afterEllipsis < text.endIndex {
                cursor = afterEllipsis
            }
        }
        return cursor
    }

    private static func extendPinyinSpan(
        in text: String,
        from start: String.Index,
        initialTone: Bool
    ) -> SpanTail {
        var end = start
        var hasTone = initialTone
        var needsSpace = false
        var addedWords = 0

        while end < text.endIndex {
            if let bracket = matchBracketedPinyin(in: text, from: end) {
                end = bracket.end
                hasTone = hasTone || bracket.hasTone
                continue
            }
            guard let probe = advanceSpanSeparator(in: text, from: end),
                  let nextWord = matchPinyinWord(in: text, from: probe) else {
                break
            }
            end = nextWord.end
            hasTone = hasTone || nextWord.hasTone
            needsSpace = nextWord.splitMidWord
            addedWords += 1
            if nextWord.splitMidWord { break }
        }

        return SpanTail(end: end, hasTone: hasTone, needsSpace: needsSpace, addedWords: addedWords)
    }

    private static func advanceSpanSeparator(in text: String, from start: String.Index) -> String.Index? {
        var probe = start
        var sawCommaOrEllipsis = false
        while probe < text.endIndex {
            let char = text[probe]
            if char == " " || char == "…" {
                if char == "…" { sawCommaOrEllipsis = true }
                probe = text.index(after: probe)
            } else if char == ",", !sawCommaOrEllipsis {
                sawCommaOrEllipsis = true
                probe = text.index(after: probe)
            } else {
                break
            }
        }
        return probe < text.endIndex ? probe : nil
    }

    private static func isLikelyFrenchSingleCharPhrase(
        firstWord: String,
        wordCount: Int,
        in text: String,
        at end: String.Index
    ) -> Bool {
        guard wordCount <= 2, firstWord.count == 1, ["à", "á", "è", "é", "ò", "ó"].contains(firstWord) else {
            return false
        }
        var probe = end
        while probe < text.endIndex, text[probe] == " " {
            probe = text.index(after: probe)
        }
        guard probe < text.endIndex else { return false }
        return text[probe].isASCII && text[probe].isLetter
    }

    private static func matchBracketedPinyin(in text: String, from start: String.Index) -> (end: String.Index, hasTone: Bool)? {
        guard start < text.endIndex, text[start] == "[" else { return nil }
        let afterOpen = text.index(after: start)
        guard let close = text[afterOpen...].firstIndex(of: "]") else { return nil }
        let inner = String(text[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty,
              let wordMatch = matchPinyinWord(in: inner, from: inner.startIndex),
              wordMatch.end == inner.endIndex,
              !wordMatch.splitMidWord else {
            return nil
        }
        return (text.index(after: close), wordMatch.hasTone)
    }

    private static func matchPinyinWord(in text: String, from start: String.Index) -> WordMatch? {
        guard start < text.endIndex else { return nil }
        var idx = start
        while idx < text.endIndex {
            let c = text[idx]
            if isPinyinLetter(c) || c == "'" || c == "’" || c == "…" {
                idx = text.index(after: idx)
            } else {
                break
            }
        }
        while idx > start {
            let prev = text[text.index(before: idx)]
            if prev == "'" || prev == "’" {
                idx = text.index(before: idx)
            } else {
                break
            }
        }
        guard idx > start else { return nil }

        let token = String(text[start..<idx])
        if let validation = validateFullPinyinToken(token) {
            return WordMatch(end: idx, hasTone: validation.hasTone, splitMidWord: false, wordText: token)
        }

        if let prefixSplit = matchMixedPinyinPrefix(in: token) {
            let splitEnd = text.index(start, offsetBy: prefixSplit.charCount)
            let prefixText = String(text[start..<splitEnd])
            return WordMatch(end: splitEnd, hasTone: true, splitMidWord: true, wordText: prefixText)
        }
        return nil
    }

    private static func validateFullPinyinToken(_ token: String) -> (hasTone: Bool, syllableCount: Int)? {
        let strippedEllipsis = token.replacingOccurrences(of: "…", with: "'")
        let segments = strippedEllipsis.split(whereSeparator: { $0 == "'" || $0 == "’" })
        guard !segments.isEmpty else { return nil }

        var totalHasTone = false
        var totalSyllables = 0
        for segment in segments {
            guard let sub = segmentPinyinSubword(String(segment)) else { return nil }
            totalHasTone = totalHasTone || sub.hasTone
            totalSyllables += sub.syllableCount
        }
        return totalSyllables > 0 ? (totalHasTone, totalSyllables) : nil
    }

    private static func matchMixedPinyinPrefix(in token: String) -> (charCount: Int, syllableCount: Int)? {
        let chars = Array(token)
        guard chars.count >= 5 else { return nil }
        for cut in stride(from: chars.count - 3, through: 2, by: -1) {
            let prefix = String(chars[0..<cut])
            let suffix = String(chars[cut...])
            guard suffix.allSatisfy({ $0.isASCII && $0.isLowercase }) else { continue }
            if let valid = validateFullPinyinToken(prefix), valid.hasTone, valid.syllableCount >= 2 {
                return (cut, valid.syllableCount)
            }
        }
        return nil
    }

    private static func segmentPinyinSubword(_ subword: String) -> (hasTone: Bool, syllableCount: Int)? {
        guard let extracted = extractPinyinCharacters(from: subword) else { return nil }
        let bases = extracted.bases
        let tones = extracted.tones

        var dp = [Int?](repeating: nil, count: bases.count + 1)
        dp[0] = 0

        for i in 0..<bases.count {
            guard let prevCount = dp[i] else { continue }
            let maxLen = min(7, bases.count - i)
            for len in 1...maxLen {
                let end = i + len
                let sliceBases = String(bases[i..<end])
                let sliceTones = Array(tones[i..<end])
                guard isValidSyllable(
                    base: sliceBases,
                    tones: sliceTones,
                    isInitialSyllable: i == 0,
                    isFinalSyllable: end == bases.count
                ) else {
                    continue
                }
                let nextCount = prevCount + 1
                if dp[end] == nil || nextCount < dp[end]! {
                    dp[end] = nextCount
                }
            }
        }

        guard let count = dp[bases.count] else { return nil }
        return (extracted.hasTone, count)
    }

    private static func extractPinyinCharacters(from subword: String) -> ExtractedCharacters? {
        var bases: [Character] = []
        var tones: [Int] = []
        var hasTone = false

        for ch in subword.lowercased() {
            if let mapped = PinyinLexicon.toneCharMap[ch] {
                bases.append(mapped.base)
                tones.append(mapped.tone)
                if mapped.tone > 0 { hasTone = true }
            } else if ch.isASCII && ch.isLowercase {
                bases.append(ch)
                tones.append(0)
            } else {
                return nil
            }
        }
        return bases.isEmpty ? nil : ExtractedCharacters(bases: bases, tones: tones, hasTone: hasTone)
    }

    private static func isValidSyllable(
        base: String,
        tones: [Int],
        isInitialSyllable: Bool,
        isFinalSyllable: Bool
    ) -> Bool {
        if !isInitialSyllable, let first = base.first, first == "a" || first == "e" || first == "o" {
            return false
        }

        let toneCount = tones.filter { $0 > 0 }.count
        guard toneCount <= 1 else { return false }

        if base == "re", let tone = tones.first(where: { $0 > 0 }), tone == 1 || tone == 2 {
            return false
        }
        if base == "me", toneCount > 0 {
            return false
        }

        if PinyinLexicon.validSyllables.contains(base) {
            return true
        }
        if isFinalSyllable, toneCount == 1, base.count >= 2, base.hasSuffix("r") {
            let root = String(base.dropLast())
            return root != "er" && PinyinLexicon.validSyllables.contains(root)
        }
        return false
    }

    private static func isPinyinLetter(_ char: Character) -> Bool {
        if PinyinLexicon.toneCharMap[char] != nil { return true }
        if let lower = char.lowercased().first, PinyinLexicon.toneCharMap[lower] != nil { return true }
        return char.isASCII && char.isLetter
    }

    private static func isToneMarkedPinyinVowel(_ char: Character) -> Bool {
        if let mapped = PinyinLexicon.toneCharMap[char], mapped.tone > 0 { return true }
        if let lower = char.lowercased().first, let mapped = PinyinLexicon.toneCharMap[lower], mapped.tone > 0 { return true }
        return false
    }

    private static func isResetCharacter(_ char: Character) -> Bool {
        if char == ";" || char == "；" || char == "▸" || char == "‹" || char == "›" || char == "(" || char == ")" {
            return true
        }
        return char.isASCII && (char.isLetter || char.isNumber)
    }

    private static func isTrailingCJKPunct(_ char: Character) -> Bool {
        char == "？" || char == "！" || char == "。" || char == "）" || char == "]"
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tidyCleanedOutput(_ text: String) -> String {
        var cleaned = collapseSpaces(text)
        for punct in [";", "；", ",", "，", "。", "？", "！", "：", ":"] {
            cleaned = cleaned.replacingOccurrences(of: " \(punct)", with: punct)
        }
        return collapseSpaces(cleaned)
    }
}
