import Testing
import Foundation
import ShinAppleKit
@testable import ShinAppServices

// 切歌过渡决策单测：保留旧内容直到新内容就绪。
// 文档夹具全部原创虚构，不含任何真实歌词。
struct LyricsPanelTransitionTests {

    private func makeDocument(lines: Int) -> LyricDocument {
        let lyricLines = (0..<lines).map { index in
            LyricLine(startMs: Int64(index) * 1_000, text: "过渡测试第 \(index) 行")
        }
        return LyricDocument(
            sourceLanguage: "ja",
            originalFilename: "transition-test.txt",
            lines: lyricLines
        )
    }

    private func makeUntimedDocument() -> LyricDocument {
        LyricDocument(
            sourceLanguage: "ja",
            sourceFormat: .text,
            originalFilename: "transition-untimed-test.txt",
            lines: [LyricLine(startMs: nil, text: "未打轴过渡测试行")]
        )
    }

    @Test("换曲目且有已打轴内容 → 过渡态保留旧文档")
    func trackChangeRetainsTimedDocument() {
        let document = makeDocument(lines: 3)
        let decision = LyricsPanelTransition.decide(
            previousTrackKey: "music-script:persistent:AAA",
            displayedContent: .timed(document: document),
            newTrackKey: "music-script:persistent:BBB"
        )
        #expect(decision == .retainAndLoad(.timed(document: document)))
    }

    @Test("换曲目且旧内容全未打轴 → 同样进入过渡态保留")
    func trackChangeRetainsUntimedDocument() {
        let document = makeUntimedDocument()
        let decision = LyricsPanelTransition.decide(
            previousTrackKey: "music-script:persistent:AAA",
            displayedContent: .untimed(document: document),
            newTrackKey: "music-script:persistent:BBB"
        )
        #expect(decision == .retainAndLoad(.untimed(document: document)))
    }

    @Test("换曲目但无可展示内容 → 直接加载（无闪空白问题）")
    func trackChangeWithoutContentLoadsDirectly() {
        #expect(LyricsPanelTransition.decide(
            previousTrackKey: nil,
            displayedContent: nil,
            newTrackKey: "music-script:persistent:BBB"
        ) == .loadDirectly(keepCurrentWhileLoading: false))
        #expect(LyricsPanelTransition.decide(
            previousTrackKey: "music-script:persistent:AAA",
            displayedContent: nil,
            newTrackKey: "music-script:persistent:BBB"
        ) == .loadDirectly(keepCurrentWhileLoading: false))
    }

    @Test("无当前曲目（trackKey == nil）→ 普通加载路径（noTrack 空态）")
    func nilTrackKeyLoadsDirectly() {
        let document = makeDocument(lines: 2)
        #expect(LyricsPanelTransition.decide(
            previousTrackKey: "music-script:persistent:AAA",
            displayedContent: .timed(document: document),
            newTrackKey: nil
        ) == .loadDirectly(keepCurrentWhileLoading: false))
    }

    @Test("同曲目刷新（编辑保存等）→ 直接加载且保留当前内容（不闪加载态）")
    func sameTrackRefreshKeepsCurrent() {
        let document = makeDocument(lines: 2)
        #expect(LyricsPanelTransition.decide(
            previousTrackKey: "music-script:persistent:AAA",
            displayedContent: .timed(document: document),
            newTrackKey: "music-script:persistent:AAA"
        ) == .loadDirectly(keepCurrentWhileLoading: true))
        // 无内容时同曲目刷新也无需保留。
        #expect(LyricsPanelTransition.decide(
            previousTrackKey: "music-script:persistent:AAA",
            displayedContent: nil,
            newTrackKey: "music-script:persistent:AAA"
        ) == .loadDirectly(keepCurrentWhileLoading: false))
    }

    @Test("保留内容访问器：document 与 isUntimedOnly 语义正确")
    func retainedContentAccessors() {
        let timed = LyricsPanelTransition.RetainedContent.timed(document: makeDocument(lines: 1))
        let untimed = LyricsPanelTransition.RetainedContent.untimed(document: makeUntimedDocument())
        #expect(!timed.isUntimedOnly)
        #expect(untimed.isUntimedOnly)
        #expect(timed.document.lines.count == 1)
        #expect(untimed.document.lines.first?.startMs == nil)
    }
}
