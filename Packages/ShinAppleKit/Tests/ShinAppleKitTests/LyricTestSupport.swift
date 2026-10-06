import Foundation
@testable import ShinAppleKit

/// 解析测试共享工具。夹具全部为原创虚构文本，不含任何真实歌词。
enum LyricFixture {
    /// 把文本按 UTF-8 送入解析流水线。
    static func parse(
        _ text: String,
        filename: String? = "fixture.lrc",
        options: LyricParseOptions = LyricParseOptions()
    ) throws -> LyricParseResult {
        try LyricsParser.parse(Data(text.utf8), filename: filename, options: options)
    }
}

/// 数字左侧补零（生成时间轴夹具用）。
func zeroPadded(_ value: Int, width: Int) -> String {
    var text = String(value)
    while text.count < width {
        text = "0" + text
    }
    return text
}
