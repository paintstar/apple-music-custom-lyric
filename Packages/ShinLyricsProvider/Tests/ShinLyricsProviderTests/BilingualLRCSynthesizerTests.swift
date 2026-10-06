import Foundation
import Testing
@testable import ShinLyricsProvider

// 双语 LRC 合成单测：核心保证是「输出可被既有 pairedTimestamps 模式识别」，
// 即同一时间戳的原文/译文相邻成组；原文行永远原样保留。

@Suite("BilingualLRCSynthesizer")
struct BilingualLRCSynthesizerTests {

    @Test("同时间戳原文译文相邻输出（毫秒归一键：.00 与 .000 等价）")
    func pairsAdjacentLines() {
        let original = "[00:01.00]虚构原文一\n[00:05.500]虚构原文二"
        let translated = "[00:01.000]虚构译文一\n[00:05.500]虚构译文二"
        let result = BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: translated)
        let lines = result.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "[00:01.00]虚构原文一")      // 原文行原样保留
        #expect(lines[1] == "[00:01.000]虚构译文一")     // 译文统一三位小数
        #expect(lines[2] == "[00:05.500]虚构原文二")
        #expect(lines[3] == "[00:05.500]虚构译文二")
    }

    @Test("无译文的原文行保持单行")
    func keepsUntranslatedLines() {
        let original = "[00:01.000]有译文\n[00:09.000]没译文"
        let translated = "[00:01.000]译文"
        let result = BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: translated)
        let lines = result.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[2] == "[00:09.000]没译文")
    }

    @Test("译文有而原文没有的时间戳被丢弃，不凭空造原文")
    func dropsOrphanTranslations() {
        let original = "[00:01.000]原文"
        let translated = "[00:01.000]译文\n[00:77.000]孤儿译文"
        let result = BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: translated)
        #expect(!result.contains("孤儿译文"))
    }

    @Test("元信息行与无正文时间戳行不参与配对")
    func skipsMetadataLines() {
        let original = "[ti:虚构标题]\n[00:00.000]\n[00:01.000]正文"
        let translated = "[00:00.000]不应配到空行\n[00:01.000]译文"
        let result = BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: translated)
        #expect(!result.contains("不应配到空行"))
        #expect(result.contains("[ti:虚构标题]"))
        #expect(result.contains("[00:01.000]译文"))
    }

    @Test("翻译为 nil 或空白：原文原样返回")
    func nilTranslationReturnsOriginal() {
        let original = "[00:01.000]原文"
        #expect(BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: nil) == original)
        #expect(
            BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: "   ")
                == original
        )
    }

    @Test("翻译无时间戳（纯文本）：原文原样返回，不盲目追加")
    func untimedTranslationIgnored() {
        let original = "[00:01.000]原文"
        #expect(
            BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: "没有时间戳的翻译")
                == original
        )
    }

    @Test("同时间戳多条译文取第一条")
    func firstTranslationWins() {
        let original = "[00:01.000]原文"
        let translated = "[00:01.000]第一条\n[00:01.000]第二条"
        let result = BilingualLRCSynthesizer.synthesize(originalLRC: original, translatedLRC: translated)
        #expect(result.contains("第一条"))
        #expect(!result.contains("第二条"))
    }

    @Test("时间戳解析：两位/三位小数与分钟进位")
    func timestampParsing() {
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("01:23.45") == 83_450)
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("01:23.456") == 83_456)
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("00:00") == 0)
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("2:03") == 123_000)
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("61:00") == 3_660_000) // 长曲合法
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("1000:00") == nil)     // 分超界
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("01:60") == nil)   // 秒超界
        #expect(BilingualLRCSynthesizer.timestampToMilliseconds("ti:标题") == nil) // 非时间戳
    }
}
