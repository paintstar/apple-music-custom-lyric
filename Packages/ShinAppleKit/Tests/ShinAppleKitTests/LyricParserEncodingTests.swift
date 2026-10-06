import Foundation
import Testing
@testable import ShinAppleKit

/// 编码、限制与规模测试（编码/空文件/超限各行 + 附加项）。
@Suite("LyricsParser 编码与限制")
struct LyricParserEncodingTests {

    @Test("UTF-8 BOM + CRLF + 元信息：文本正确、元信息保留")
    func bomAndCrlfWithMetadata() throws {
        let text = "\u{FEFF}[ti:测试曲目]\r\n[ar:测试艺人]\r\n[00:01.00]第一句测试文本\r\n[00:02.00]第二句测试文本\r\n"
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.metadata["ti"] == ["测试曲目"])
        #expect(result.document.metadata["ar"] == ["测试艺人"])
        #expect(result.document.lines.map(\.startMs) == [1_000, 2_000])
        #expect(result.document.lines.map(\.text) == ["第一句测试文本", "第二句测试文本"])
        #expect(result.document.originalText?.hasPrefix("[ti:") == true)
    }

    @Test("孤立 CR 与混合换行符按行切分")
    func loneCarriageReturnSplit() throws {
        let result = try LyricFixture.parse("[00:01.00]第一句测试文本\r[00:02.00]第二句测试文本\n")
        #expect(result.document.lines.map(\.startMs) == [1_000, 2_000])
    }

    @Test("中日韩、组合字符、emoji 正确保存")
    func cjkCombiningAndEmojiPreserved() throws {
        let text = "[00:01.00]測試-café\u{0301}-テキスト🎵\n[00:02.00]中文测试文本 한국어 텍스트 👩‍🚀\n"
        let result = try LyricFixture.parse(text)
        #expect(result.isImportable)
        #expect(result.document.lines[0].text == "測試-café\u{0301}-テキスト🎵")
        #expect(result.document.lines[1].text == "中文测试文本 한국어 텍스트 👩‍🚀")
    }

    @Test("UTF-16 LE BOM 可顺带支持")
    func utf16LittleEndianBOM() throws {
        let text = "[00:01.5]第一句测试文本"
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        let result = try LyricsParser.parse(data, filename: "utf16le.lrc")
        #expect(result.isImportable)
        #expect(result.document.lines.map(\.startMs) == [1_500])
        #expect(result.document.lines.map(\.text) == ["第一句测试文本"])
    }

    @Test("UTF-16 BE BOM 可顺带支持")
    func utf16BigEndianBOM() throws {
        let text = "[00:02.00]第二句测试文本"
        var data = Data([0xFE, 0xFF])
        for unit in text.utf16 {
            data.append(UInt8(unit >> 8))
            data.append(UInt8(unit & 0xFF))
        }
        let result = try LyricsParser.parse(data, filename: "utf16be.lrc")
        #expect(result.document.lines.map(\.startMs) == [2_000])
    }

    @Test("非法 UTF-8 字节 → 错误并指明字节位置，不保存乱码")
    func invalidUTF8ReportsByteOffset() {
        let data = Data([0x41, 0xC3, 0x28, 0x42])
        #expect(throws: LyricParseError.undecodableUTF8(byteOffset: 1)) {
            try LyricsParser.parse(data, filename: "bad.lrc")
        }
    }

    @Test("孤立续字节 → 错误并指明字节位置")
    func strayContinuationByteRejected() {
        let data = Data([0x41, 0x80, 0x42])
        #expect(throws: LyricParseError.undecodableUTF8(byteOffset: 1)) {
            try LyricsParser.parse(data)
        }
    }

    @Test("截断的多字节序列 → 错误")
    func truncatedMultibyteRejected() {
        let data = Data([0xE2, 0x82])
        #expect(throws: LyricParseError.undecodableUTF8(byteOffset: 0)) {
            try LyricsParser.parse(data)
        }
    }

    @Test("UTF-8 编码的代理项码点 → 错误")
    func utf8EncodedSurrogateRejected() {
        let data = Data([0xED, 0xA0, 0x80])
        #expect(throws: LyricParseError.undecodableUTF8(byteOffset: 0)) {
            try LyricsParser.parse(data)
        }
    }

    @Test("UTF-16 未配对代理项 → 错误并指明字节位置")
    func unpairedSurrogateRejected() {
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: [0x00, 0xD8])
        data.append(contentsOf: [0x41, 0x00])
        #expect(throws: LyricParseError.undecodableUTF16(byteOffset: 2)) {
            try LyricsParser.parse(data)
        }
    }

    @Test("UTF-16 奇数字节 → 错误")
    func oddByteCountUTF16Rejected() {
        let data = Data([0xFF, 0xFE, 0x41, 0x00, 0x42])
        #expect(throws: LyricParseError.undecodableUTF16(byteOffset: 4)) {
            try LyricsParser.parse(data)
        }
    }

    @Test("空文件 → 无可导入内容")
    func emptyFileRejected() {
        #expect(throws: LyricParseError.emptyInput) {
            try LyricsParser.parse(Data())
        }
    }

    @Test("全空白文件 → 无可导入内容")
    func whitespaceOnlyRejected() {
        #expect(throws: LyricParseError.emptyInput) {
            try LyricsParser.parse(Data("  \n\t \r\n  ".utf8))
        }
    }

    @Test("仅 BOM → 无可导入内容")
    func bomOnlyRejected() {
        #expect(throws: LyricParseError.emptyInput) {
            try LyricsParser.parse(Data([0xEF, 0xBB, 0xBF]))
        }
    }

    @Test("默认限制：2 MiB / 10,000 行")
    func defaultLimits() {
        let options = LyricParseOptions()
        #expect(options.maxBytes == 2 * 1024 * 1024)
        #expect(options.maxLines == 10_000)
    }

    @Test("超过字节上限 → 可恢复错误")
    func byteLimitRejected() {
        let data = Data("[00:01.00]第一句测试文本\n".utf8)
        #expect(throws: LyricParseError.inputTooLarge(limitBytes: 4, actualBytes: data.count)) {
            try LyricsParser.parse(data, options: LyricParseOptions(maxBytes: 4))
        }
    }

    @Test("超过行数上限 → 可恢复错误")
    func lineLimitRejected() {
        var lines: [String] = []
        for index in 0..<6 {
            lines.append("[00:0\(index + 1).00]第\(index)句测试文本")
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        #expect(throws: LyricParseError.tooManyLines(limit: 5, actual: 6)) {
            try LyricsParser.parse(data, options: LyricParseOptions(maxLines: 5))
        }
    }

    @Test("10,000 行冒烟：解析成功、行数正确、无诊断")
    func tenThousandLinesSmoke() throws {
        var lines: [String] = []
        lines.reserveCapacity(10_000)
        for index in 0..<10_000 {
            let minutes = index / 600
            let seconds = (index % 600) / 10
            let fraction = (index % 10) * 100
            lines.append(
                "[\(zeroPadded(minutes, width: 2)):\(zeroPadded(seconds, width: 2)).\(zeroPadded(fraction, width: 3))]第\(index)句测试文本"
            )
        }
        let result = try LyricFixture.parse(lines.joined(separator: "\n"))
        #expect(result.isImportable)
        #expect(result.document.lines.count == 10_000)
        #expect(result.diagnostics.isEmpty)
        #expect(result.document.lines.first?.startMs == 0)
        #expect(result.document.lines.last?.startMs == 999_900)
    }
}
