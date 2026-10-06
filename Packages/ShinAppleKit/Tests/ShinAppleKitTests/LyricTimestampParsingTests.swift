import Foundation
import Testing
@testable import ShinAppleKit

/// LRC 时间戳解析测试（时间戳各行）。
/// 十进制小数秒按十进制换算（.5=500ms、.05=50ms、.005=5ms），整数运算无浮点。
@Suite("LyricsParser 时间戳")
struct LyricTimestampParsingTests {

    @Test("[00:01] → 1000ms")
    func plainSeconds() throws {
        let result = try LyricFixture.parse("[00:01]第一句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.lines.map(\.startMs) == [1_000])
        #expect(result.document.lines.map(\.text) == ["第一句测试文本"])
    }

    @Test("[00:01.5] → 1500ms")
    func oneFractionDigit() throws {
        let result = try LyricFixture.parse("[00:01.5]第一句测试文本\n")
        #expect(result.document.lines.map(\.startMs) == [1_500])
    }

    @Test("[00:01.05] → 1050ms")
    func twoFractionDigits() throws {
        let result = try LyricFixture.parse("[00:01.05]第一句测试文本\n")
        #expect(result.document.lines.map(\.startMs) == [1_050])
    }

    @Test("[00:01.005] → 1005ms")
    func threeFractionDigits() throws {
        let result = try LyricFixture.parse("[00:01.005]第一句测试文本\n")
        #expect(result.document.lines.map(\.startMs) == [1_005])
    }

    @Test("[61:02.300] → 3662300ms（分钟可超 59）")
    func minutesBeyond59() throws {
        let result = try LyricFixture.parse("[61:02.300]第一句测试文本\n")
        #expect(result.document.lines.map(\.startMs) == [3_662_300])
    }

    @Test("同一行多个时间戳 → 每个时间点独立实例、不同稳定 ID")
    func multipleTimestampsPerLine() throws {
        let result = try LyricFixture.parse("[00:01.00][00:03.00]重复测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.lines.count == 2)
        #expect(result.document.lines.map(\.startMs) == [1_000, 3_000])
        let ids = result.document.lines.map(\.id)
        #expect(ids[0] != ids[1])
        #expect(result.document.lines.allSatisfy { $0.text == "重复测试文本" })
    }

    @Test("[00:99.00] 秒超范围 → 错误定位，不按 0ms 继续")
    func secondsOutOfRange() throws {
        let result = try LyricFixture.parse("[00:99.00]第一句测试文本\n")
        #expect(!result.isImportable)
        #expect(result.document.lines.isEmpty)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.code == .secondsOutOfRange)
        #expect(diagnostic.line == 1)
        #expect(diagnostic.column == 1)
        #expect(diagnostic.snippet?.contains("第一句测试文本") == true)
    }

    @Test("[00:60.00] 秒等于 60 → 错误")
    func secondsAt60Rejected() throws {
        let result = try LyricFixture.parse("[00:60.00]第一句测试文本\n")
        #expect(!result.isImportable)
        #expect(result.diagnostics.first?.code == .secondsOutOfRange)
        #expect(result.document.lines.isEmpty)
    }

    @Test("[00:59.999] 秒边界内合法 → 59999ms")
    func secondsInsideBoundaryAccepted() throws {
        let result = try LyricFixture.parse("[00:59.999]第一句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.lines.map(\.startMs) == [59_999])
    }

    @Test("非数字时间 [00:ab] → 错误定位，不按 0ms 继续")
    func nonNumericSeconds() throws {
        let result = try LyricFixture.parse("[00:ab]第一句测试文本\n")
        #expect(!result.isImportable)
        #expect(result.document.lines.isEmpty)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.code == .timestampFormatInvalid)
        #expect(diagnostic.line == 1)
        #expect(diagnostic.column == 1)
    }

    @Test("小数超 3 位 → 截断 + 警告（.1234 → 123ms）")
    func extraFractionDigitsTruncated() throws {
        let result = try LyricFixture.parse("[00:01.1234]第一句测试文本\n")
        #expect(result.isImportable)
        #expect(result.document.lines.map(\.startMs) == [1_123])
        #expect(result.diagnostics.map(\.code) == [.fractionDigitsTruncated])
        #expect(result.diagnostics.first?.severity == .warning)
    }

    @Test("分钟数值溢出 Int64 → 错误")
    func minuteOverflowRejected() throws {
        let result = try LyricFixture.parse("[99999999999999999999:00]第一句测试文本\n")
        #expect(!result.isImportable)
        #expect(result.diagnostics.first?.code == .timestampOutOfRange)
        #expect(result.document.lines.isEmpty)
    }

    @Test("出错的行丢弃，其余行保留且诊断带行号")
    func errorLineDroppedOthersKept() throws {
        let text = "[00:01.00]第一句测试文本\n[00:99.00]第二句测试文本\n[00:03.00]第三句测试文本\n"
        let result = try LyricFixture.parse(text)
        #expect(!result.isImportable)
        #expect(result.document.lines.map(\.startMs) == [1_000, 3_000])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics[0].line == 2)
    }

    @Test("同一行内多个时间戳之一非法 → 整行丢弃并报错")
    func partialInvalidTimestampDropsLine() throws {
        let result = try LyricFixture.parse("[00:01.00][00:99.00]重复测试文本\n")
        #expect(!result.isImportable)
        #expect(result.document.lines.isEmpty)
        #expect(result.diagnostics.first?.code == .secondsOutOfRange)
    }
}
