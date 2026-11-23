import Foundation
import ShinAppleKit
import Testing
@testable import ShinAppServices

@Suite("LocalDictionaryService")
struct LocalDictionaryServiceTests {
    private let service = LocalDictionaryService()

    @Test("空白输入安全返回空结果而不崩溃")
    func emptyInputReturnsBlankResult() {
        let empty = service.lookup("")
        #expect(empty == LocalDictionaryLookupResult(query: ""))

        let spaces = service.lookup("   \n\t  ")
        #expect(spaces == LocalDictionaryLookupResult(query: ""))
    }

    @Test("英文句子语境下可识别语种、词形原形与中文词性")
    func englishMorphologyAndLanguage() {
        let result = service.lookup(
            "running",
            contextLine: "She was running along the quiet river."
        )
        #expect(result.query == "running")
        #expect(result.detectedLanguage == "en")
        #expect(result.lemma == "run")
        #expect(result.partOfSpeech == "动词")
        if let definition = result.systemDefinition {
            #expect(!definition.isEmpty)
        }
    }

    @Test("日文句子语境下可识别日语并输出词性分析")
    func japaneseLanguageAndMorphology() {
        let result = service.lookup(
            "青い",
            contextLine: "青い紙飛行機が空を飛ぶ。"
        )
        #expect(result.query == "青い")
        #expect(result.detectedLanguage == "ja")
        #expect(result.partOfSpeech != nil)
        if let definition = result.systemDefinition {
            #expect(!definition.isEmpty)
        }
    }

    @Test("日语语境下可离线算出汉字词的平假名读音")
    func japaneseOfflineKanaReading() {
        let mockService = LocalDictionaryService { _ in nil }

        let otona = mockService.lookup("大人", contextLine: "大人になれないまま")
        #expect(otona.detectedLanguage == "ja")
        #expect(otona.reading == "おとな")

        let mirai = mockService.lookup("未来", contextLine: "未来を信じて")
        #expect(mirai.detectedLanguage == "ja")
        #expect(mirai.reading == "みらい")

        let sekai = mockService.lookup("世界", contextLine: "この世界で")
        #expect(sekai.detectedLanguage == "ja")
        #expect(sekai.reading == "せかい")
    }

    @Test("日语查词被中文词典截胡时自动用假名安全回查日中词典")
    func japaneseFallsBackFromChineseEntryToJapaneseDictionaryByReading() {
        let entries: [String: String] = [
            "大人": "大人 dàrén 名 对长辈的敬称。",
            "おとな": "おとな 【大人】 成人 chéngrén English an adult"
        ]
        let mockService = LocalDictionaryService { entries[$0] }

        let result = mockService.lookup("大人", contextLine: "大人になれないまま")
        #expect(result.detectedLanguage == "ja")
        #expect(result.reading == "おとな")
        #expect(result.systemDefinition == entries["おとな"])

        let formatted = LocalDictionaryFormatter.format(result)
        #expect(formatted?.headword == "大人")
        #expect(formatted?.phonetics == "おとな")
        #expect(formatted?.conciseMeaning == "成人")
    }

    @Test("按假名回查遇到词头不匹配条目时安全拒绝并保留离线读音")
    func japaneseReadingFallbackRejectsMismatchedHeadwordAndKeepsReading() {
        let entries: [String: String] = [
            "今日": "今日 jīnrì 名 今天。",
            "きょう": "きょう 【-きょう•強•-強】 English a little more than…"
        ]
        let mockService = LocalDictionaryService { entries[$0] }

        let result = mockService.lookup("今日", contextLine: "今日も空が青い")
        #expect(result.detectedLanguage == "ja")
        #expect(result.reading == "きょう")
        #expect(result.systemDefinition == entries["今日"])

        let formatted = LocalDictionaryFormatter.format(result)
        #expect(formatted?.phonetics == "きょう")

        #expect(LocalDictionaryService.japaneseEntry("ひとり 【一人•独り】 一个人", matchesTarget: "一人", lemma: nil))
        #expect(LocalDictionaryService.japaneseEntry("きれい 【綺麗な】 漂亮", matchesTarget: "綺麗", lemma: nil))
        #expect(LocalDictionaryService.japaneseEntry("きおく 【記憶する】 记忆", matchesTarget: "記憶", lemma: nil))
        #expect(!LocalDictionaryService.japaneseEntry(entries["きょう"] ?? "", matchesTarget: "今日", lemma: nil))
    }

    @Test("本机词典返回 nil 时仍保留离线假名读音且不崩溃")
    func nilSystemDefinitionPreservesOfflineReading() {
        let mockService = LocalDictionaryService { _ in nil }
        let result = mockService.lookup("大人", contextLine: "大人になれないまま")

        #expect(result.detectedLanguage == "ja")
        #expect(result.reading == "おとな")
        #expect(result.systemDefinition == nil)
        #expect(LocalDictionaryFormatter.format(result) == nil)
    }
}

@Suite("LocalDictionaryFormatter")
struct LocalDictionaryFormatterTests {
    @Test("牛津英汉多词性词条可提取音标、语境词性置顶、清洗拼音并生成精炼摘要")
    func oxfordMultiPOSFormatsAndPrioritizesContextPOS() {
        let rawOxford = [
            "coast | BrE kəʊst, AmE koʊst |",
            "A. noun ① (part of land beside sea) 海岸 hǎi'àn"
                + "▸ off the coast 在近海岸的海上▸ from coast to coast 在整个大陆▸ the coast is clear figurative 四下无人",
            "② (region) 沿海地区 yánhǎi dìqū",
            "B. intransitive verb ① (freewheel) 靠惯性滑行 kào guànxìng huáxíng▸ coast down the hill 顺坡滑行"
        ].joined(separator: " ")
        let lookup = LocalDictionaryLookupResult(
            query: "coasting",
            lemma: "coast",
            partOfSpeech: "动词",
            detectedLanguage: "en",
            systemDefinition: rawOxford
        )

        let formatted = LocalDictionaryFormatter.format(lookup)
        #expect(formatted != nil)
        guard let entry = formatted else { return }

        #expect(entry.headword == "coast")
        #expect(entry.phonetics?.contains("kəʊst") == true)
        #expect(entry.phonetics?.contains("koʊst") == true)
        #expect(entry.phonetics == "BrE /kəʊst/ · AmE /koʊst/")
        #expect(entry.fallbackRawText == nil)

        #expect(entry.sections.count == 2)
        let verbSection = entry.sections[0]
        let nounSection = entry.sections[1]
        #expect(verbSection.partOfSpeechLabel == "动词 (vi.)")
        #expect(verbSection.compactTag == "vi.")
        #expect(verbSection.isContextMatch == true)
        #expect(nounSection.partOfSpeechLabel == "名词 (n.)")
        #expect(nounSection.compactTag == "n.")
        #expect(nounSection.isContextMatch == false)

        #expect(verbSection.senses.count == 1)
        #expect(verbSection.senses[0].numberLabel == "①")
        #expect(verbSection.senses[0].qualifier == "(freewheel)")
        #expect(verbSection.senses[0].definition == "靠惯性滑行")
        #expect(verbSection.senses[0].examples.map(\.text) == ["coast down the hill 顺坡滑行"])

        #expect(nounSection.senses.count == 2)
        #expect(nounSection.senses[0].qualifier == "(part of land beside sea)")
        #expect(nounSection.senses[0].definition == "海岸")
        #expect(nounSection.senses[0].examples.map(\.text) == [
            "off the coast 在近海岸的海上",
            "from coast to coast 在整个大陆",
            "the coast is clear figurative 四下无人"
        ])
        #expect(nounSection.senses[1].definition == "沿海地区")

        let allText = ([entry.conciseMeaning]
            + entry.sections.flatMap { section in
                section.senses.flatMap { [$0.definition] + $0.examples.map(\.text) }
            })
            .joined(separator: "\n")
        #expect(!allText.contains("hǎi'àn"))
        #expect(!allText.contains("yánhǎi dìqū"))
        #expect(!allText.contains("kào guànxìng huáxíng"))

        #expect(entry.conciseMeaning.count <= 85)
        #expect(entry.conciseMeaning.contains("vi. 靠惯性滑行"))
        #expect(entry.conciseMeaning.contains("n. 海岸；沿海地区"))
        #expect(!entry.conciseMeaning.contains("kəʊst"))
        #expect(!entry.conciseMeaning.contains("off the coast"))
        #expect(!entry.conciseMeaning.contains("coast down the hill"))
    }

    @Test("无显式分段标记的简短词典文本也能安全格式化并生成精炼摘要")
    func unsegmentedShortDefinitionFormatsSafely() {
        let plainLookup = LocalDictionaryLookupResult(
            query: "glide",
            partOfSpeech: "动词",
            detectedLanguage: "en",
            systemDefinition: "靠惯性滑行；平稳前进"
        )
        let plainEntry = LocalDictionaryFormatter.format(plainLookup)
        #expect(plainEntry != nil)
        #expect(plainEntry?.sections.count == 1)
        #expect(plainEntry?.sections[0].partOfSpeechLabel == "释义")
        #expect(plainEntry?.sections[0].compactTag.isEmpty == true)
        #expect(plainEntry?.sections[0].isContextMatch == false)
        #expect(plainEntry?.sections[0].senses.first?.definition == "靠惯性滑行；平稳前进")
        #expect(plainEntry?.conciseMeaning == "靠惯性滑行")

        let slashLookup = LocalDictionaryLookupResult(
            query: "serene",
            partOfSpeech: "形容词",
            detectedLanguage: "en",
            systemDefinition: "serene /səˈriːn/ adj. 宁静的 níngjìng de▸ serene lake 宁静的湖泊 níngjìng de húpō"
        )
        let slashEntry = LocalDictionaryFormatter.format(slashLookup)
        #expect(slashEntry?.headword == "serene")
        #expect(slashEntry?.phonetics == "/səˈriːn/")
        #expect(slashEntry?.sections[0].partOfSpeechLabel == "形容词 (adj.)")
        #expect(slashEntry?.sections[0].isContextMatch == true)
        #expect(slashEntry?.sections[0].senses[0].definition == "宁静的")
        #expect(slashEntry?.sections[0].senses[0].examples.map(\.text) == ["serene lake 宁静的湖泊"])
        #expect(slashEntry?.conciseMeaning == "adj. 宁静的")
    }

    @Test("带重音英文词、法文外来词及正常英文句子不会被误删英文单词")
    func preservesAccentedLoanwordsAndEnglishSentences() {
        let englishLoanword = """
        A café near the quiet coast brings déjà vu, naïve charm, crème brûlée, fiancé, and a polished résumé.
        """
        let englishResult = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(query: "café", systemDefinition: englishLoanword)
        )
        let englishDef = englishResult?.sections.first?.senses.first?.definition
        #expect(englishDef == "A café near the quiet coast brings déjà vu, naïve charm, crème brûlée, fiancé, and a polished résumé.")

        let mixedChineseLoanword = "在 café 点 à la carte 与 crème brûlée，提供 résumé 即可。"
        let mixedResult = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(query: "café", systemDefinition: mixedChineseLoanword)
        )
        let mixedDef = mixedResult?.sections.first?.senses.first?.definition
        #expect(mixedDef == "在 café 点 à la carte 与 crème brûlée，提供 résumé 即可。")
    }

    @Test("空释义或全空白输入安全返回 nil")
    func nilOrWhitespaceReturnsNil() {
        #expect(LocalDictionaryFormatter.format(LocalDictionaryLookupResult(query: "empty", systemDefinition: nil)) == nil)
        #expect(LocalDictionaryFormatter.format(LocalDictionaryLookupResult(query: "empty", systemDefinition: "")) == nil)
        #expect(LocalDictionaryFormatter.format(LocalDictionaryLookupResult(query: "empty", systemDefinition: "  \n\t ")) == nil)
    }

    @Test("日语假名词头与多重义项可正确结构化且清洗夹杂拼音")
    func japaneseDictionaryHeaderAndSenses() {
        let rawJapanese = [
            "そらみ 【空見】 1[天気] 晴朗 qínglǎng 晴朗的天空 qínglǎng de tiānkōng English clear sky",
            "2[顔色] 苍白 cāngbái English pale",
            "▸ 顔が青くなる 脸色发青[苍白], 怎么了？ liǎnsè fāqīng[cāngbái], zěnme le？"
        ].joined(separator: " ")
        let entry = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(query: "空見", detectedLanguage: "ja", systemDefinition: rawJapanese)
        )
        #expect(entry != nil)
        #expect(entry?.headword == "空見")
        #expect(entry?.phonetics == "そらみ")
        #expect(entry?.sections.count == 1)
        let senses = entry?.sections[0].senses ?? []
        #expect(senses.count == 2)
        #expect(senses[0].numberLabel == "1")
        #expect(senses[0].qualifier == "[天気]")
        #expect(senses[0].definition == "晴朗 晴朗的天空 English clear sky")
        #expect(senses[1].numberLabel == "2")
        #expect(senses[1].qualifier == "[顔色]")
        #expect(senses[1].definition == "苍白 English pale")
        #expect(senses[1].examples.map(\.text) == ["顔が青くなる 脸色发青[苍白], 怎么了？"])
        #expect(entry?.conciseMeaning == "晴朗 晴朗的天空；苍白")
    }

    @Test("语境词性区分动词与形容动词，且粘连拼音、省略号拼音与超长摘要均可正确处理")
    func contextPOSPrecisionAndLengthLimit() {
        let raw = [
            "glint | BrE ɡlɪnt, AmE ɡlɪnt |",
            "A. noun uncountable ① (flash) 闪光 shǎnguāng; (spark) 微弱的闪光 wēiruò de shǎnguāng; …的管理 … de guǎnlǐ ‹crystal›",
            "② (manner) 带头 dàitóubefore noun 赛跑用 sàipǎo yòng de ‹gear›",
            "B. transitive verb ① (emit) 发出闪光 fāchū shǎnguāng",
            "② (reflect) 反射出长长的一段光芒以测试摘要上限并在接近八十五字处平稳截断 fǎnshè chū chángcháng de yíduàn guāngmáng"
        ].joined(separator: " ")
        let verbEntry = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(query: "glint", partOfSpeech: "动词", systemDefinition: raw)
        )
        #expect(verbEntry?.sections.count == 2)
        #expect(verbEntry?.sections[0].partOfSpeechLabel == "动词 (vt.)")
        #expect(verbEntry?.sections[0].isContextMatch == true)
        #expect(verbEntry?.sections[1].partOfSpeechLabel == "名词 (n.)")
        #expect(verbEntry?.sections[1].isContextMatch == false)
        #expect((verbEntry?.conciseMeaning.count ?? 999) <= 85)

        let nounSection = verbEntry?.sections[1]
        #expect(nounSection?.senses[0].definition == "闪光; (spark) 微弱的闪光; …的管理 ‹crystal›")
        #expect(nounSection?.senses[1].definition == "带头 before noun 赛跑用 ‹gear›")

        // 验证 "动词" 不会误匹配 "形容动词"，而 "形容词" 可以匹配 "形容动词"
        let jpRaw = "しずか 【静か】 ［形動］ 1. 安静 ānjìng 2. 寂静 jìjìng ［名］ 静谧 jìngmì"
        let verbLookup = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(query: "静か", partOfSpeech: "动词", systemDefinition: jpRaw)
        )
        #expect(verbLookup?.sections.allSatisfy { !$0.isContextMatch } == true)

        let adjLookup = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(query: "静か", partOfSpeech: "形容词", systemDefinition: jpRaw)
        )
        #expect(adjLookup?.sections.first?.partOfSpeechLabel == "形容动词 (adj-na)")
        #expect(adjLookup?.sections.first?.isContextMatch == true)
    }

    @Test("带连字符的日语词典头可正确提取并清洗读音")
    func hyphenatedJapaneseDictionaryHeaderExtractsCleanPhonetics() {
        let entry = LocalDictionaryFormatter.format(
            LocalDictionaryLookupResult(
                query: "大人",
                detectedLanguage: "ja",
                systemDefinition: "お‐とな 【大人】 成人 chéngrén"
            )
        )
        #expect(entry?.headword == "大人")
        #expect(entry?.phonetics == "おとな")
        #expect(entry?.conciseMeaning == "成人")
    }
}
