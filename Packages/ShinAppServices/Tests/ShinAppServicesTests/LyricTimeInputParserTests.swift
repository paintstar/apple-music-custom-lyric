import Foundation
import Testing
import ShinAppleKit
@testable import ShinAppServices

// 时间输入解析测试：规则全部明确定义（见 LyricTimeInputParser 头注释），
// 非法输入一律类型化失败，绝不静默归零。全部为原创虚构数值夹具。

@Suite("编辑器时间输入解析")
struct LyricTimeInputParserTests {

    private func parsed(_ raw: String) throws -> Int64? {
        switch LyricTimeInputParser.parse(raw) {
        case let .success(ms):
            return ms
        case let .failure(failure):
            Issue.record("「\(raw)」应当解析成功，实际失败：\(failure)")
            return nil
        }
    }

    private func expectFailure(
        _ expected: LyricTimeInputParser.Failure,
        _ raw: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch LyricTimeInputParser.parse(raw) {
        case let .success(ms):
            Issue.record("「\(raw)」应当失败 \(expected)，实际成功：\(String(describing: ms))", sourceLocation: sourceLocation)
        case let .failure(failure):
            #expect(failure == expected, "「\(raw)」", sourceLocation: sourceLocation)
        }
    }

    @Test("方括号分秒形式（含小数毫秒）")
    func bracketedTimestamps() throws {
        #expect(try parsed("[00:01.000]") == 1_000)
        #expect(try parsed("[01:02.5]") == 62_500)
        #expect(try parsed("01:02.050") == 62_050)
        #expect(try parsed("[00:00.005]") == 5)
        // 超过 3 位小数按十进制截断到毫秒。
        #expect(try parsed("[00:01.12345]") == 1_123)
    }

    @Test("分钟可超过 59；秒必须在 0..<60")
    func minuteAndSecondRanges() throws {
        #expect(try parsed("[90:00]") == 5_400_000)
        #expect(try parsed("5:07") == 307_000)
        expectFailure(.secondsOutOfRange(60), "1:60")
        expectFailure(.secondsOutOfRange(200), "[00:200]")
    }

    @Test("纯秒与十进制秒")
    func decimalSeconds() throws {
        #expect(try parsed("90") == 90_000)
        #expect(try parsed("12.5") == 12_500)
        #expect(try parsed("0.005") == 5)
        #expect(try parsed(".5") == 500)
        #expect(try parsed("+8") == 8_000)
    }

    @Test("整数毫秒后缀（ms/毫秒）")
    func millisecondSuffix() throws {
        #expect(try parsed("1250ms") == 1_250)
        #expect(try parsed("1250 毫秒") == 1_250)
        #expect(try parsed("[1250ms]") == 1_250)
        expectFailure(.fractionalMilliseconds, "12.5ms")
        expectFailure(.fractionalMilliseconds, "12.5毫秒")
        expectFailure(.malformed, "ms")
    }

    @Test("空白与空括号 = 未打轴（nil）")
    func untimedInputs() throws {
        #expect(try parsed("") == nil)
        #expect(try parsed("   ") == nil)
        #expect(try parsed("[]") == nil)
        #expect(try parsed("[  ]") == nil)
    }

    @Test("非法输入类型化失败，绝不归零")
    func invalidInputs() {
        expectFailure(.malformed, "abc")
        expectFailure(.malformed, "[01:02")
        expectFailure(.malformed, "01:02]")
        expectFailure(.malformed, "1:2:3")
        expectFailure(.malformed, "1.2.3")
        expectFailure(.malformed, "12,5")
        expectFailure(.negativeNotAllowed, "-5")
        expectFailure(.negativeNotAllowed, "[-0:01]")
        expectFailure(.malformed, "1 分 30 秒")
        expectFailure(.outOfRange, "99999999999999999999999")
    }

    @Test("显示文本：nil → 空串；毫秒 → m:ss.mmm")
    func displayStrings() {
        #expect(LyricTimeInputParser.displayString(from: nil) == "")
        #expect(LyricTimeInputParser.displayString(from: 0) == "0:00.000")
        #expect(LyricTimeInputParser.displayString(from: 62_500) == "1:02.500")
        #expect(LyricTimeInputParser.displayString(from: 5) == "0:00.005")
        #expect(LyricTimeInputParser.displayString(from: 3_720_000) == "62:00.000")
    }
}
