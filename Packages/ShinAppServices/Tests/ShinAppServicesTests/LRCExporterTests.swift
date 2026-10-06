import Foundation
import Testing
import ShinAppleKit
import ShinLyricsEngine
@testable import ShinAppServices

// LRC 互操作导出测试：
// - 两种模式的时间正确性（含 61:02 超分钟行）；
// - .appliedOffset 与引擎 effectiveStartMs 唯一定义点一致，调整 userDelay 后导出随之变化；
// - offset 只应用一次：导出 → 重新导入解析 → 时间等于导出值（不二次偏移）；
// - 负有效起点裁剪为 0 且计数正确；
// - 损失说明非空且含关键条目（译文/元信息/offset/裁剪/截断）。

@Suite("LRC 导出")
struct LRCExporterTests {

    /// 标准夹具：offset 200ms；行含译文、未打轴行、超分钟行、非整十毫秒行。
    private static func document() -> LyricDocument {
        LyricDocument(
            sourceLanguage: "ja",
            sourceFormat: .lrc,
            sourceOffsetMs: 200,
            originalText: "[00:01]第一句测试文本\n[61:02.300]超分钟测试文本\n",
            originalFilename: "导出测试.lrc",
            metadata: ["ti": ["导出测试曲目"], "ar": ["测试歌手"]],
            lines: [
                LyricLine(
                    startMs: 1_000,
                    text: "第一句测试文本",
                    translations: ["zh-Hans": Translation(text: "第一句测试译文")]
                ),
                LyricLine(startMs: 3_662_300, text: "超分钟测试文本"),
                LyricLine(startMs: 1_239, text: "截断测试文本"),
                LyricLine(startMs: nil, text: "未打轴测试文本")
            ]
        )
    }

    /// 从导出文本提取全部时间标签（毫秒），按出现顺序。
    private static func parsedTimes(_ text: String) -> [Int64] {
        var result: [Int64] = []
        for line in text.split(separator: "\n") {
            guard let tag = line.first, tag == "[" else { continue }
            let parts = line.split(separator: "]", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let time = parts[0].dropFirst()
            // [mm:ss.ff] → 毫秒
            let pieces = time.split(separator: ":")
            guard pieces.count == 2,
                  let minutes = Int64(pieces[0]),
                  let secondsPart = Double(pieces[1]) else { continue }
            result.append(minutes * 60_000 + Int64(secondsPart * 1_000))
        }
        return result
    }

    @Test("originalTimes：原时间、无 [offset:] 标签、61:02 超分钟保持实际分钟数")
    func originalTimesFormat() {
        let result = LRCExporter.export(document: Self.document(), mode: .originalTimes)
        let lines = result.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3) // 未打轴行不写入
        #expect(lines[0] == "[00:01.00]第一句测试文本")
        #expect(lines[1] == "[61:02.30]超分钟测试文本")
        #expect(lines[2] == "[00:01.23]截断测试文本")
        #expect(!result.text.contains("[offset:"))
        #expect(result.clampedLineCount == 0)
    }

    @Test("appliedOffset：与引擎 effectiveStartMs 唯一定义点逐行一致")
    func appliedOffsetMatchesEngine() {
        let document = Self.document()
        let delay: Int64 = 500
        let result = LRCExporter.export(document: document, mode: .appliedOffset, userDelayMs: delay)
        let times = Self.parsedTimes(result.text)
        var expected: [Int64] = []
        for line in document.lines {
            guard let start = line.startMs else { continue }
            let effective = LyricsTimelineIndex.effectiveStartMs(
                lineStartMs: start,
                sourceOffsetMs: document.sourceOffsetMs,
                userDelayMs: delay
            )
            // 导出文本按 LRC 百分秒向下截断；比较时应用同样的截断。
            expected.append(max(effective, 0) / 10 * 10)
        }
        #expect(times == expected)
        // 手工核对一行：1_000 − 200 + 500 = 1_300。
        #expect(times.first == 1_300)
    }

    @Test("appliedOffset：调整 userDelay 后导出随之变化（每次按原值单次计算）")
    func changingDelayChangesExport() {
        let document = Self.document()
        let first = LRCExporter.export(document: document, mode: .appliedOffset, userDelayMs: 500)
        let second = LRCExporter.export(document: document, mode: .appliedOffset, userDelayMs: -800)
        let firstTimes = Self.parsedTimes(first.text)
        let secondTimes = Self.parsedTimes(second.text)
        // 1_000 − 200 + 500 = 1_300；1_000 − 200 − 800 = 0。
        #expect(firstTimes.first == 1_300)
        #expect(secondTimes.first == 0)
        #expect(firstTimes != secondTimes)
        // 延迟不是从上一次导出结果继续累加：第二份文件与「原值 − 800」一致。
        #expect(secondTimes[1] == max(3_662_300 - 200 - 800, 0))
    }

    @Test("offset 不二次应用：appliedOffset 导出 → 重新解析 → 时间等于导出值")
    func noDoubleOffsetApplication() throws {
        let document = Self.document()
        let result = LRCExporter.export(document: document, mode: .appliedOffset, userDelayMs: 500)
        // 重新导入（解析层）：文档无 offset 标签 → sourceOffsetMs = 0，
        // 行时间与导出值逐行相等（夹具时间均为整十毫秒，无截断损失）。
        let reparsed = try LyricsParser.parse(Data(result.text.utf8))
        #expect(reparsed.document.sourceOffsetMs == 0)
        let exportedTimes = Self.parsedTimes(result.text)
        // 解析层对乱序输入做稳定排序：按时间集合比较（无丢失、无二次偏移）。
        #expect(reparsed.document.lines.count == exportedTimes.count)
        #expect(reparsed.document.lines.compactMap(\.startMs).sorted() == exportedTimes.sorted())
        // 导出值（百分秒截断后）：1_300 / 3_662_600 / 1_530（内部 1_539 被截断）。
        #expect(reparsed.document.lines.compactMap(\.startMs).sorted()
            == [1_300, 1_530, 3_662_600].sorted())
    }

    @Test("负有效起点裁剪为 0，计数逐行正确")
    func clampingCountedPerLine() {
        var document = Self.document()
        document.lines = [
            LyricLine(startMs: 100, text: "负起点甲测试文本"),
            LyricLine(startMs: 2_500, text: "正常起点测试文本"),
            LyricLine(startMs: 150, text: "负起点乙测试文本"),
            LyricLine(startMs: nil, text: "未打轴测试文本")
        ]
        document.sourceOffsetMs = 200
        // delay −800：effective = 100 − 200 − 800 = −900；150 − 200 − 800 = −850。
        let result = LRCExporter.export(document: document, mode: .appliedOffset, userDelayMs: -800)
        #expect(result.clampedLineCount == 2)
        let times = Self.parsedTimes(result.text)
        #expect(times == [0, 1_500, 0])
        #expect(result.lossNotes.contains { $0.contains("2 行应用偏移后时间为负") })
    }

    @Test("损失说明非空且含关键条目（译文/元信息/id/offset/未打轴）")
    func lossNotesContainKeyEntries() {
        let original = LRCExporter.export(document: Self.document(), mode: .originalTimes)
        #expect(!original.lossNotes.isEmpty)
        #expect(original.lossNotes.contains { $0.contains("1 句译文") })
        #expect(original.lossNotes.contains { $0.contains("元信息") })
        #expect(original.lossNotes.contains { $0.contains("行稳定 id") })
        #expect(original.lossNotes.contains { $0.contains("sourceOffsetMs = 200 ms") })
        #expect(original.lossNotes.contains { $0.contains("未写") && $0.contains("未打轴") })
        #expect(original.lossNotes.contains { $0.contains("[offset:]") })

        let applied = LRCExporter.export(document: Self.document(), mode: .appliedOffset, userDelayMs: 500)
        #expect(!applied.lossNotes.isEmpty)
        #expect(applied.lossNotes.contains { $0.contains("一次性应用") })
        #expect(applied.lossNotes.contains { $0.contains("200") && $0.contains("500") })
        // 百分秒截断提示（1_239ms → 1.23）。
        #expect(applied.lossNotes.contains { $0.contains("百分之一秒") })
    }

    @Test("timeTag：边界值与超分钟格式")
    func timeTagFormatting() {
        #expect(LRCExporter.timeTag(0) == "00:00.00")
        #expect(LRCExporter.timeTag(1_000) == "00:01.00")
        #expect(LRCExporter.timeTag(1_500) == "00:01.50")
        #expect(LRCExporter.timeTag(1_050) == "00:01.05")
        #expect(LRCExporter.timeTag(3_662_300) == "61:02.30")
        #expect(LRCExporter.timeTag(999) == "00:00.99")
    }
}
