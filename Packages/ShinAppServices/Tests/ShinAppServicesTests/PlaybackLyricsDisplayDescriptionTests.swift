import Testing
@testable import ShinAppServices

// 同步显示描述测试：用户延迟的中文语义描述。
// - 0 = 无偏移；正 = 延后；负 = 提前（UI 约定）；
// - 一位小数格式与 0.1 秒步进对齐；方向与符号绝不颠倒。

@Suite("同步显示描述")
struct PlaybackLyricsDisplayDescriptionTests {

    @Test("延迟为零显示「无偏移」")
    func zeroDelay() {
        let display = PlaybackLyricsDisplay(content: .idle, userDelayMs: 0)
        #expect(display.delayDescription == "无偏移")
    }

    @Test("正延迟按「延后」描述")
    func positiveDelay() {
        let display = PlaybackLyricsDisplay(content: .idle, userDelayMs: 500)
        #expect(display.delayDescription == "延后 0.5 秒")
    }

    @Test("负延迟按「提前」描述")
    func negativeDelay() {
        let display = PlaybackLyricsDisplay(content: .idle, userDelayMs: -100)
        #expect(display.delayDescription == "提前 0.1 秒")
    }

    @Test("整秒延迟保留一位小数")
    func wholeSecondDelay() {
        let display = PlaybackLyricsDisplay(content: .idle, userDelayMs: 2_000)
        #expect(display.delayDescription == "延后 2.0 秒")
    }

    @Test("亚毫秒精度截断为一位小数")
    func subStepDelay() {
        let display = PlaybackLyricsDisplay(content: .idle, userDelayMs: -1_250)
        #expect(display.delayDescription == "提前 1.2 秒")
    }
}
