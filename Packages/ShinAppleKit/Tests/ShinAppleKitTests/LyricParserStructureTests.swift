import Foundation
import Testing
@testable import ShinAppleKit

/// 解析结构与归一化测试（结构各行 + offset 语义）。
@Suite("LyricsParser 结构与归一化")
struct LyricParserStructureTests {

    @Test("两行相同时间戳 → 同一时间组、原输入顺序、不推断译文")
    func sameTimestampKeepsInputOrder() throws {
        let result = try LyricFixture.parse("[00:02.00]第一句测试文本\n[00:02.00]第二句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.lines.map(\.text) == ["第一句测试文本", "第二句测试文本"])
        #expect(result.document.lines.map(\.startMs) == [2_000, 2_000])
        #expect(result.document.lines.allSatisfy { $0.translations.isEmpty })
    }

    @Test("定时空白时间行保留（清屏/间奏边界）")
    func timedEmptyLineKept() throws {
        let text = "[00:01.00]第一句测试文本\n[00:04.00]\n[00:06.00]第二句测试文本\n"
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.lines.count == 3)
        #expect(result.document.lines[1].startMs == 4_000)
        #expect(result.document.lines[1].text.isEmpty)
    }

    @Test("部分无时间文本 → startMs=null、可保存、排在时间轴之后")
    func untimedLinesSavedAsNull() throws {
        let text = "[00:01.00]第一句测试文本\n第二句未打轴测试文本\n[00:02.00]第三句测试文本\n"
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.lines.count == 3)
        #expect(result.document.lines.map(\.startMs) == [1_000, 2_000, nil])
        #expect(result.document.lines.last?.text == "第二句未打轴测试文本")
    }

    @Test("乱序时间戳 → 稳定排序、逐行警告、不漏行")
    func outOfOrderStableSortedWithWarnings() throws {
        let text = "[00:03.00]第三句测试文本\n[00:01.00]第一句测试文本\n[00:02.00]第二句测试文本\n"
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.lines.map(\.text) == ["第一句测试文本", "第二句测试文本", "第三句测试文本"])
        #expect(result.document.lines.map(\.startMs) == [1_000, 2_000, 3_000])
        let warnings = result.diagnostics.filter { $0.code == .outOfOrderTimestamps }
        #expect(warnings.map(\.line) == [2, 3])
        #expect(warnings.allSatisfy { $0.severity == .warning })
    }

    @Test("同时间戳多行参与乱序排序时保持输入顺序")
    func stableSortKeepsEqualTimestampsInInputOrder() throws {
        let text = "[00:02.00]甲测试文本\n[00:01.00]乙测试文本\n[00:02.00]丙测试文本\n"
        let result = try LyricFixture.parse(text)
        #expect(result.document.lines.map(\.text) == ["乙测试文本", "甲测试文本", "丙测试文本"])
    }

    @Test("元信息保留、未知键保留、同键多值按顺序累积")
    func metadataPreserved() throws {
        let text = """
        [ti:测试曲目]
        [ar:测试艺人]
        [al:测试专辑]
        [by:测试工具]
        [custom-tag:自定义值]
        [custom-tag:第二个自定义值]
        [00:01.00]第一句测试文本
        """
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.metadata["ti"] == ["测试曲目"])
        #expect(result.document.metadata["ar"] == ["测试艺人"])
        #expect(result.document.metadata["al"] == ["测试专辑"])
        #expect(result.document.metadata["by"] == ["测试工具"])
        #expect(result.document.metadata["custom-tag"] == ["自定义值", "第二个自定义值"])
        #expect(result.document.metadata["offset"] == nil)
    }

    @Test("offset 原样存 sourceOffsetMs，绝不加到任何 line.startMs")
    func offsetStoredSeparatelyNotAppliedToLines() throws {
        let result = try LyricFixture.parse("[offset:200]\n[00:10.00]第一句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.sourceOffsetMs == 200)
        #expect(result.document.lines.map(\.startMs) == [10_000])
    }

    @Test("offset 带符号：+500 与 -200")
    func offsetSignsPreserved() throws {
        let positive = try LyricFixture.parse("[offset:+500]\n[00:01.00]第一句测试文本\n")
        #expect(positive.document.sourceOffsetMs == 500)
        let negative = try LyricFixture.parse("[offset:-200]\n[00:01.00]第一句测试文本\n")
        #expect(negative.document.sourceOffsetMs == -200)
    }

    @Test("多个 offset：最后一个有效值生效并产出警告；非法值忽略并警告")
    func lastOffsetWinsWithWarnings() throws {
        let text = """
        [offset:100]
        [00:01.00]第一句测试文本
        [offset:+300]
        [00:02.00]第二句测试文本
        [offset:abc]
        [00:03.00]第三句测试文本
        """
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.sourceOffsetMs == 300)
        #expect(result.diagnostics.map(\.code) == [.offsetSuperseded, .offsetInvalid])
        #expect(result.diagnostics[0].severity == .warning)
        #expect(result.diagnostics[0].line == 3)
        #expect(result.diagnostics[1].line == 5)
    }

    @Test("纯文本输入 → sourceFormat=.text、全部未打轴、内部空行保留")
    func plainTextFormatDetected() throws {
        let text = "\n第一句测试文本\n\n第二句测试文本\n\n"
        let result = try LyricFixture.parse(text, filename: "notes.txt")
        #expect(result.isImportable)
        #expect(result.document.sourceFormat == .text)
        #expect(result.document.lines.map(\.startMs) == [nil, nil, nil])
        #expect(result.document.lines.map(\.text) == ["第一句测试文本", "", "第二句测试文本"])
    }

    @Test("仅元信息无歌词行 → LRC、0 行、无错误")
    func metadataOnlyDocument() throws {
        let result = try LyricFixture.parse("[ti:测试曲目]\n[ar:测试艺人]\n")
        #expect(result.isImportable)
        #expect(result.document.sourceFormat == .lrc)
        #expect(result.document.lines.isEmpty)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("纯文本分段标记 [Chorus] 不当标签，按正文保留")
    func sectionMarkerTreatedAsText() throws {
        let result = try LyricFixture.parse("[Chorus]\n第一句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.sourceFormat == .text)
        #expect(result.document.lines.map(\.text) == ["[Chorus]", "第一句测试文本"])
    }

    @Test("LRC 中的空标签 [] → 警告并忽略")
    func emptyTagWarnedAndIgnored() throws {
        let result = try LyricFixture.parse("[ti:测试曲目]\n[]第一句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.sourceFormat == .lrc)
        #expect(result.diagnostics.map(\.code) == [.emptyTagIgnored])
        #expect(result.document.lines.map(\.text) == ["第一句测试文本"])
        #expect(result.document.lines.map(\.startMs) == [nil])
    }

    @Test("文档字段：schemaVersion/revision/originalText/originalFilename/时间戳")
    func documentFieldsPopulated() throws {
        let result = try LyricFixture.parse("[00:01.00]第一句测试文本\n", filename: "测试.lrc")
        let document = result.document
        #expect(document.schemaVersion == 1)
        #expect(document.revision == 1)
        #expect(document.sourceFormat == .lrc)
        #expect(document.sourceOffsetMs == 0)
        #expect(document.originalText == "[00:01.00]第一句测试文本\n")
        #expect(document.originalFilename == "测试.lrc")
        #expect(LyricTimestamp.date(from: document.createdAt) != nil)
        #expect(LyricTimestamp.date(from: document.updatedAt) != nil)
    }
}
