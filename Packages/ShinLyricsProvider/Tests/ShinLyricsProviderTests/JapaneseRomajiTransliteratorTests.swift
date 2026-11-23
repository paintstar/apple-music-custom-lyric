import Foundation
import Testing
@testable import ShinLyricsProvider

@Suite("JapaneseRomajiTransliterator")
struct JapaneseRomajiTransliteratorTests {

    @Test("基础罗马音转平假名与片假名，含驼峰与多词分隔")
    func basicRomajiConversion() {
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kawakiwoameku") == "かわきをあめく")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("KawakiwoAmeku") == "かわきをあめく")
        #expect(JapaneseRomajiTransliterator.toKatakana(fromHiragana: "かわきをあめく") == "カワキヲアメク")
        #expect(
            JapaneseRomajiTransliterator.suggestedKanaQueries(for: "kawakiwoameku")
                == ["かわきをあめく", "カワキヲアメク"]
        )

        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("yoru ni kakeru") == "よる に かける")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("gurenge") == "ぐれんげ")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("homura") == "ほむら")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("zenzenzense") == "ぜんぜんぜんせ")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kaikai kitan") == "かいかい きたん")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("yoidore shirazu") == "よいどれ しらず")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("shinunoga e-wa") == "しぬのが え わ")
    }

    @Test("促音双辅音与 tch 正确转为小っ")
    func sokuonConversion() {
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kitte") == "きって")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("gakkou") == "がっこう")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("matcha") == "まっちゃ")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("zasshi") == "ざっし")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kippu") == "きっぷ")
    }

    @Test("拨音 n'、nn 与词尾 n 正确区分")
    func nasalNConversion() {
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("shin'ai") == "しんあい")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kan’i") == "かんい")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kon'ya") == "こんや")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("minna") == "みんな")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("sennen") == "せんねん")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("konnichiwa") == "こんにちわ")
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji("kann") == "かん")
    }

    @Test("常见英文歌名与非法辅音簇严格返回 nil", arguments: [
        "Shape of You",
        "Blinding Lights",
        "LOSER",
        "Lemon",
        "Home",
        "One More Time",
        "No More",
        "Hero",
        "don't stop"
    ])
    func englishTitlesRejected(title: String) {
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji(title) == nil)
        #expect(JapaneseRomajiTransliterator.suggestedKanaQueries(for: title).isEmpty)
    }

    @Test("已含假名、汉字、韩文或无拉丁字母时返回 nil", arguments: [
        "カワキヲアメク",
        "かわきをあめく",
        "星河纸船",
        "kawaki 星河",
        "사랑해요",
        "",
        "   ",
        "12345"
    ])
    func nonRomajiScriptsRejected(input: String) {
        #expect(JapaneseRomajiTransliterator.toHiraganaIfLikelyRomaji(input) == nil)
    }

    @Test("片假名与平假名互转保持非假名字符不变")
    func katakanaHiraganaRoundTrip() {
        #expect(JapaneseRomajiTransliterator.katakanaToHiragana("カワキヲアメク") == "かわきをあめく")
        #expect(JapaneseRomajiTransliterator.katakanaToHiragana("テスト 123") == "てすと 123")
        #expect(JapaneseRomajiTransliterator.toKatakana(fromHiragana: "てすと 123") == "テスト 123")
    }

    @Test("日语歌手名拉丁读音提取支持姓+名与名+姓两种顺序")
    func japaneseLatinReadingsExtraction() {
        #expect(JapaneseRomajiTransliterator.japaneseLatinReadings(for: "美波").contains("minami"))
        let utada = JapaneseRomajiTransliterator.japaneseLatinReadings(for: "宇多田ヒカル")
        #expect(utada.contains("utadahikaru"))
        #expect(utada.contains("hikaruutada"))
        let hoshino = JapaneseRomajiTransliterator.japaneseLatinReadings(for: "星野源")
        #expect(hoshino.contains("hoshinogen"))
        #expect(hoshino.contains("genhoshino"))
        #expect(JapaneseRomajiTransliterator.japaneseLatinReadings(for: "Minami").isEmpty)
        #expect(JapaneseRomajiTransliterator.japaneseLatinReadings(for: "").isEmpty)
    }

    @Test("日语歌手名跨文字音译匹配与无关/同文字排除")
    func artistsMatchByJapaneseReading() {
        #expect(JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Minami", "美波"))
        #expect(JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("美波", "Minami"))
        #expect(JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Hikaru Utada", "宇多田ヒカル"))
        #expect(JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Utada Hikaru", "宇多田ヒカル"))
        #expect(JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Gen Hoshino", "星野源"))
        #expect(JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Hoshino Gen", "星野源"))

        #expect(!JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Sati Akura", "美波"))
        #expect(!JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("Minami", "Minami"))
        #expect(!JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("美波", "美波"))
        #expect(!JapaneseRomajiTransliterator.artistsMatchByJapaneseReading("M", "美波"))
    }
}
