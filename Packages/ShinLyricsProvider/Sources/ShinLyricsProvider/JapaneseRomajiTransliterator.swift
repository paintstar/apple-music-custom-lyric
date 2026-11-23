import Foundation

// 离线日语罗马音识别与假名转换（纯函数，无网络、无 ICU 误判）。
// 采用严格的 Hepburn / 训令式音节表驱动贪心最大匹配：
// 只要任一词段无法 100% 无残留切分为合法日语音节，即判定非日语罗马音并返回 nil，
// 避免普通英文歌名被误转为假名。

/// 离线日语罗马音与假名转换工具。
public enum JapaneseRomajiTransliterator {

    // MARK: - 公开 API

    /// 若输入大概率是纯日语罗马音，则转换为平假名；否则返回 nil。
    public static func toHiraganaIfLikelyRomaji(_ text: String) -> String? {
        guard containsASCIILetter(text), !containsCJKOrKanaOrHangul(text) else {
            return nil
        }

        let tokens = splitTokens(text)
        guard !tokens.isEmpty else { return nil }

        let loweredTokens = tokens.map { $0.lowercased() }
        if loweredTokens.allSatisfy({ commonEnglishWords.contains($0) }) {
            return nil
        }

        var converted: [String] = []
        converted.reserveCapacity(loweredTokens.count)
        for token in loweredTokens {
            guard let kana = transliterateToken(token) else { return nil }
            converted.append(kana)
        }
        return converted.joined(separator: " ")
    }

    /// 将平假名转为片假名。
    public static func toKatakana(fromHiragana hiragana: String) -> String {
        hiragana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? hiragana
    }

    /// 将片假名转为平假名（其他字符保持不变）。
    public static func katakanaToHiragana(_ text: String) -> String {
        text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text
    }

    /// 若标题可识别为日语罗马音，返回去重后的 `[平假名, 片假名]` 搜索建议；否则返回空数组。
    public static func suggestedKanaQueries(for title: String) -> [String] {
        guard let hiragana = toHiraganaIfLikelyRomaji(title) else { return [] }
        let katakana = toKatakana(fromHiragana: hiragana)
        return katakana == hiragana ? [hiragana] : [hiragana, katakana]
    }

    // MARK: - 词段切分与字符判定

    private static func containsASCIILetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
    }

    /// 检测平假名、片假名（含半角与扩展）、中日韩汉字及韩文。
    private static func containsCJKOrKanaOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F,       // 平假名
                 0x30A0...0x30FF,       // 片假名
                 0x31F0...0x31FF,       // 片假名语音扩展
                 0xFF65...0xFF9F,       // 半角片假名
                 0x3400...0x4DBF,       // CJK 扩展 A
                 0x4E00...0x9FFF,       // CJK 基本汉字
                 0xF900...0xFAFF,       // CJK 兼容汉字
                 0x20000...0x2EBEF,     // CJK 扩展 B-F
                 0x1100...0x11FF,       // 韩文字母
                 0x3130...0x318F,       // 韩文兼容字母
                 0xAC00...0xD7AF:       // 韩文音节
                return true
            default:
                return false
            }
        }
    }

    private static func isApostrophe(_ char: Character) -> Bool {
        char == "'" || char == "’"
    }

    private static func isSeparator(_ char: Character) -> Bool {
        if isApostrophe(char) { return false }
        return char.isWhitespace || char.isPunctuation || char == "-"
    }

    /// 按空白、连字符及撇号之外的标点切分词段；撇号保留在词段内部用于 `n'` 拨音。
    private static func splitTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for char in text {
            if isSeparator(char) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: - 单词段罗马音转平假名

    private static func transliterateToken(_ token: String) -> String? {
        let chars = Array(token)
        let count = chars.count
        var index = 0
        var output = ""
        output.reserveCapacity(count)

        while index < count {
            // 1. 拨音 n 特殊处理（n'、词尾 n、n 后接非元音/非 y）
            if let consumed = consumeNasalN(chars, at: index, output: &output) {
                index += consumed
                continue
            }

            // 2. 促音（双辅音或 tch）
            if isSokuon(chars, at: index) {
                output.append("っ")
                index += 1
                continue
            }

            // 3. 贪心最大匹配：4 -> 3 -> 2 -> 1 字母音节表
            if let (kana, length) = matchSyllable(chars, at: index) {
                output.append(kana)
                index += length
                continue
            }

            return nil
        }
        return output.isEmpty ? nil : output
    }

    /// 处理拨音 `n`：
    /// - `n'` / `n’`：输出 `ん` 并跳过撇号；
    /// - `nn`：若后面是元音或 `y`（如 `minna`、`konnichiwa`），只消费第一个 `n` 输出 `ん`，
    ///   留第二个 `n` 组成 `na/ni/...`；否则（词尾或后接辅音/撇号）消费 `nn`（及紧随撇号）输出 `ん`；
    /// - 词尾 `n` 或后接非元音/非 `y` 的辅音：消费单个 `n` 输出 `ん`。
    private static func consumeNasalN(_ chars: [Character], at index: Int, output: inout String) -> Int? {
        guard chars[index] == "n" else { return nil }
        let count = chars.count
        let nextIndex = index + 1
        if nextIndex == count {
            output.append("ん")
            return 1
        }
        let next = chars[nextIndex]
        if isApostrophe(next) {
            output.append("ん")
            return 2
        }
        if next == "n" {
            let afterSecond = index + 2
            if afterSecond == count {
                output.append("ん")
                return 2
            }
            let third = chars[afterSecond]
            if isApostrophe(third) {
                output.append("ん")
                return 3
            }
            if vowels.contains(third) || third == "y" {
                output.append("ん")
                return 1
            }
            output.append("ん")
            return 2
        }
        if !vowels.contains(next) && next != "y" {
            output.append("ん")
            return 1
        }
        return nil
    }

    /// 判断当前位置是否为促音（如 `kk/ss/tt/pp/cc/bb/dd/gg/zz` 或 `tch`）。
    private static func isSokuon(_ chars: [Character], at index: Int) -> Bool {
        let count = chars.count
        guard index + 2 < count else { return false }
        let first = chars[index]
        let second = chars[index + 1]
        if first == "t" && second == "c" && chars[index + 2] == "h" {
            return true
        }
        return sokuonConsonants.contains(first) && first == second && chars[index + 2] != first
    }

    private static func matchSyllable(_ chars: [Character], at index: Int) -> (String, Int)? {
        let remaining = chars.count - index
        if remaining >= 4 {
            let key = String(chars[index..<(index + 4)])
            if let kana = fourLetterMap[key] { return (kana, 4) }
        }
        if remaining >= 3 {
            let key = String(chars[index..<(index + 3)])
            if let kana = threeLetterMap[key] { return (kana, 3) }
        }
        if remaining >= 2 {
            let key = String(chars[index..<(index + 2)])
            if let kana = twoLetterMap[key] { return (kana, 2) }
        }
        let single = chars[index]
        if let kana = vowelMap[single] { return (kana, 1) }
        return nil
    }

    // MARK: - 音节映射表与防误伤英文词表

    private static let vowels: Set<Character> = ["a", "i", "u", "e", "o"]
    private static let sokuonConsonants: Set<Character> = ["k", "s", "t", "p", "c", "b", "d", "g", "z"]

    private static let vowelMap: [Character: String] = [
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お"
    ]

    private static let fourLetterMap: [String: String] = [
        "ltsu": "っ", "xtsu": "っ"
    ]

    private static let threeLetterMap: [String: String] = [
        "shi": "し", "chi": "ち", "tsu": "つ",
        "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
        "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        "sya": "しゃ", "syu": "しゅ", "sye": "しぇ", "syo": "しょ",
        "zya": "じゃ", "zyu": "じゅ", "zye": "じぇ", "zyo": "じょ",
        "jya": "じゃ", "jyu": "じゅ", "jye": "じぇ", "jyo": "じょ",
        "tya": "ちゃ", "tyu": "ちゅ", "tye": "ちぇ", "tyo": "ちょ",
        "cya": "ちゃ", "cyu": "ちゅ", "cye": "ちぇ", "cyo": "ちょ",
        "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
        "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "fya": "ふゃ", "fyu": "ふゅ", "fyo": "ふょ",
        "vya": "ゔゃ", "vyu": "ゔゅ", "vyo": "ゔょ",
        "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ",
        "thi": "てぃ", "dhi": "でぃ", "thu": "てゅ", "dhu": "でゅ",
        "kwa": "くぁ", "gwa": "ぐぁ",
        "ltu": "っ", "xtu": "っ"
    ]

    private static let twoLetterMap: [String: String] = [
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "sa": "さ", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "ta": "た", "ti": "ち", "tu": "つ", "te": "て", "to": "と",
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "ya": "や", "yu": "ゆ", "ye": "いぇ", "yo": "よ",
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "wa": "わ", "wi": "うぃ", "we": "うぇ", "wo": "を",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "za": "ざ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "ja": "じゃ", "ji": "じ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
        "nn": "ん"
    ]

    /// 碰巧符合日语音节切分的常见英文短词；当所有词段均落入此集合时视为英文而非日语罗马音。
    private static let commonEnglishWords: Set<String> = [
        "no", "so", "go", "me", "be", "he", "we", "do", "to", "hi", "in", "on", "an", "ok",
        "one", "home", "time", "name", "hero", "zero", "make", "take", "wake", "cake", "fake", "lake",
        "mono", "mama", "papa", "rain", "pain", "main", "gain", "mine", "fine", "line", "nine",
        "bone", "tone", "zone", "done", "gone", "here", "more", "core", "bare", "care", "dare",
        "fare", "rare", "pure", "sure", "cute", "mute", "note", "vote", "hope", "rope", "same",
        "game", "fame", "came", "date", "fate", "gate", "hate", "late", "mate", "rate", "save",
        "wave", "shape", "mode", "side", "ride", "wide", "hide", "tide", "bite", "kite", "site",
        "rose", "nose", "pose", "base", "pace", "race", "page", "rage", "sage", "wage", "fade",
        "made", "jade", "safe", "bake", "joke", "poke", "woke", "duke", "tube", "rude", "dude",
        "tune", "june", "menu", "neon", "demo", "memo", "data", "beta", "mega", "meta", "mini",
        "midi", "radio", "piano", "banana", "man", "fan", "pan", "ran", "tan", "ban", "sun",
        "run", "fun", "gun", "bun", "men", "pen", "bin", "pin", "sin", "tin", "win", "fin",
        "son", "won", "moon", "soon", "noon", "teen", "seen", "been", "keen", "human", "woman",
        "demon", "again", "hidden", "sudden", "button", "kitten", "pizza"
    ]
}

// MARK: - 日语人名跨文字拉丁读音匹配

extension JapaneseRomajiTransliterator {

    /// 提取日文文本的归一化拉丁读音集合（用于跨文字歌手名匹配）。
    /// 不含日文字符时直接返回空集合；2 段姓名同时生成「姓+名」与「名+姓」形式。
    public static func japaneseLatinReadings(for text: String) -> Set<String> {
        guard containsJapaneseScript(text) else { return [] }

        let cfText = text as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfText))
        let locale = Locale(identifier: "ja") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            range,
            kCFStringTokenizerUnitWord,
            locale
        ) else {
            return []
        }

        var parts: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            ) as? String else {
                continue
            }
            let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
            let asciiLower = String(
                stripped.lowercased().unicodeScalars.filter { (0x61...0x7A).contains($0.value) }
            )
            if !asciiLower.isEmpty {
                parts.append(asciiLower)
            }
        }

        guard !parts.isEmpty else { return [] }
        var readings: Set<String> = []
        let forward = parts.joined()
        if forward.count >= 2 {
            readings.insert(forward)
        }
        if parts.count == 2 {
            let reversed = parts[1] + parts[0]
            if reversed.count >= 2 {
                readings.insert(reversed)
            }
        }
        return readings
    }

    /// 判断两个歌手名是否通过日语读音跨文字匹配（一侧纯 ASCII 拉丁，另一侧含日文）。
    public static func artistsMatchByJapaneseReading(_ lhs: String, _ rhs: String) -> Bool {
        let lhsHasJapanese = containsJapaneseScript(lhs)
        let rhsHasJapanese = containsJapaneseScript(rhs)
        guard lhsHasJapanese != rhsHasJapanese else { return false }

        let japaneseSide = lhsHasJapanese ? lhs : rhs
        let latinSide = lhsHasJapanese ? rhs : lhs
        guard let normalizedLatin = normalizedPureASCIILatin(latinSide) else { return false }
        return japaneseLatinReadings(for: japaneseSide).contains(normalizedLatin)
    }

    /// 检测是否包含日文平假名、片假名或基本 CJK 汉字。
    private static func containsJapaneseScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F,   // 平假名
                 0x30A0...0x30FF,   // 片假名
                 0x4E00...0x9FFF:   // CJK 基本汉字
                return true
            default:
                return false
            }
        }
    }

    /// 仅当文本完全由 ASCII 字母、空白与标点构成且至少含 2 个 ASCII 字母时，返回小写字母串。
    private static func normalizedPureASCIILatin(_ text: String) -> String? {
        var letters = ""
        letters.reserveCapacity(text.count)
        for char in text {
            if char.unicodeScalars.count == 1,
               let scalar = char.unicodeScalars.first,
               (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                letters.append(contentsOf: char.lowercased())
            } else if char.isWhitespace || char.isPunctuation {
                continue
            } else {
                return nil
            }
        }
        return letters.count >= 2 ? letters : nil
    }
}
