import Testing
import Foundation
import ShinAppleKit
@testable import ShinAppServices

// 插值时钟规则单测：全部使用注入的单调时刻，不依赖真实时钟。
struct InterpolatedPlaybackClockTests {

    // MARK: - 基础：仅基于最近有效样本

    @Test("无样本时不插值：估计为 null，不从启动时间累加")
    func noSampleNoInterpolation() {
        var clock = InterpolatedPlaybackClock()
        #expect(clock.estimate(nowMonotonicMs: 999_999) == .none)
        #expect(clock.estimate(nowMonotonicMs: 0) == .none)
    }

    @Test("playing 样本：估计 = 样本位置 + 单调差")
    func playingInterpolation() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 1_000, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 1_000) == PlaybackEstimate(
            positionMs: 10_000, isExtrapolated: false, isStale: false
        ))
        #expect(clock.estimate(nowMonotonicMs: 1_400) == PlaybackEstimate(
            positionMs: 10_400, isExtrapolated: true, isStale: false
        ))
        #expect(clock.estimate(nowMonotonicMs: 1_999) == PlaybackEstimate(
            positionMs: 10_999, isExtrapolated: true, isStale: false
        ))
    }

    @Test("位置未知的样本（nil）不冒充 0：估计为 null")
    func nilPositionStaysNull() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: nil, sampledAtMonotonicMs: 500, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 1_500) == .none)
    }

    // MARK: - 仅 playing 状态估计（暂停冻结）

    @Test("暂停样本冻结：不推进、不外推、无陈旧标记")
    func pausedFreezes() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 30_000, sampledAtMonotonicMs: 2_000, isPlaying: false, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 2_500) == PlaybackEstimate(
            positionMs: 30_000, isExtrapolated: false, isStale: false
        ))
        #expect(clock.estimate(nowMonotonicMs: 99_999) == PlaybackEstimate(
            positionMs: 30_000, isExtrapolated: false, isStale: false
        ))
    }

    @Test("播放→暂停→恢复：恢复样本后重新按新锚点外推")
    func pauseResumeReanchors() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 1_000, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_800, sampledAtMonotonicMs: 1_800, isPlaying: false, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 5_000).positionMs == 10_800)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_800, sampledAtMonotonicMs: 6_000, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 6_600) == PlaybackEstimate(
            positionMs: 11_400, isExtrapolated: true, isStale: false
        ))
    }

    // MARK: - 外推上限

    @Test("外推上限 1 秒：超限钉在样本值并标记陈旧")
    func extrapolationCap() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 5_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        // 恰好 1000ms：仍在限内（位置 +1000）。
        #expect(clock.estimate(nowMonotonicMs: 1_000) == PlaybackEstimate(
            positionMs: 6_000, isExtrapolated: true, isStale: false
        ))
        // 超过上限：钉回样本值 + 陈旧标记。
        #expect(clock.estimate(nowMonotonicMs: 1_001) == PlaybackEstimate(
            positionMs: 5_000, isExtrapolated: false, isStale: true
        ))
        #expect(clock.estimate(nowMonotonicMs: 60_000) == PlaybackEstimate(
            positionMs: 5_000, isExtrapolated: false, isStale: true
        ))
    }

    @Test("可自定义外推上限")
    func customExtrapolationLimit() {
        var clock = InterpolatedPlaybackClock(extrapolationLimitMs: 500)
        clock.apply(sample: PlaybackSample(
            positionMs: 0, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 500).isExtrapolated)
        #expect(clock.estimate(nowMonotonicMs: 501).isStale)
    }

    // MARK: - 新样本到达即校正

    @Test("新样本到达即校正：估计从新样本重新出发，无累计漂移")
    func newSampleCorrects() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 900).positionMs == 10_900)
        // 新样本把外推的 900ms 校正回权威值。
        clock.apply(sample: PlaybackSample(
            positionMs: 10_750, sampledAtMonotonicMs: 1_000, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.estimate(nowMonotonicMs: 1_000) == PlaybackEstimate(
            positionMs: 10_750, isExtrapolated: false, isStale: false
        ))
        #expect(clock.estimate(nowMonotonicMs: 1_200).positionMs == 10_950)
    }

    // MARK: - 失效条件：切歌 / seek / 时钟域倒退

    @Test("切歌（trackEpoch 变化）重置：估计从新曲目样本出发且连击清零")
    func trackChangeResets() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        // 三个无进展样本（未达阈值，但连击计数已累计）。
        for tick in 1...3 {
            clock.apply(sample: PlaybackSample(
                positionMs: 10_000, sampledAtMonotonicMs: Int64(tick) * 400, isPlaying: true, trackEpoch: 1
            ))
        }
        #expect(clock.consecutiveNoProgressSamples == 3)
        // 切歌：新 epoch。
        clock.apply(sample: PlaybackSample(
            positionMs: 0, sampledAtMonotonicMs: 2_000, isPlaying: true, trackEpoch: 2
        ))
        #expect(clock.consecutiveNoProgressSamples == 0)
        #expect(!clock.isStalled)
        #expect(clock.estimate(nowMonotonicMs: 2_300) == PlaybackEstimate(
            positionMs: 300, isExtrapolated: true, isStale: false
        ))
    }

    @Test("seek 后样本（位置前进）解除停滞冻结并重新外推")
    func seekResetsStall() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        for tick in 1...4 {
            clock.apply(sample: PlaybackSample(
                positionMs: 10_000, sampledAtMonotonicMs: Int64(tick) * 400, isPlaying: true, trackEpoch: 1
            ))
        }
        #expect(clock.isStalled)
        #expect(clock.estimate(nowMonotonicMs: 2_000) == PlaybackEstimate(
            positionMs: 10_000, isExtrapolated: false, isStale: true
        ))
        // 用户 seek 到 60 秒：位置前进 → 冻结解除。
        clock.apply(sample: PlaybackSample(
            positionMs: 60_000, sampledAtMonotonicMs: 2_400, isPlaying: true, trackEpoch: 1
        ))
        #expect(!clock.isStalled)
        #expect(clock.consecutiveNoProgressSamples == 0)
        #expect(clock.estimate(nowMonotonicMs: 2_700) == PlaybackEstimate(
            positionMs: 60_300, isExtrapolated: true, isStale: false
        ))
    }

    @Test("单调时钟倒退（休眠唤醒/时钟域重映射）：重置连击并从新样本出发")
    func monotonicRegressionResets() {
        var clock = InterpolatedPlaybackClock()
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 10_000, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 10_400, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.consecutiveNoProgressSamples == 1)
        // 时钟域倒退：新样本时刻小于旧样本时刻。
        clock.apply(sample: PlaybackSample(
            positionMs: 20_000, sampledAtMonotonicMs: 5_000, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.consecutiveNoProgressSamples == 0)
        #expect(clock.estimate(nowMonotonicMs: 5_200) == PlaybackEstimate(
            positionMs: 20_200, isExtrapolated: true, isStale: false
        ))
    }

    // MARK: - 连续无进展样本 → 冻结

    @Test("连续无进展达到阈值冻结估计：钉在样本值 + 陈旧标记")
    func stallFreezesAfterThreshold() {
        var clock = InterpolatedPlaybackClock(stallSampleLimit: 3)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 400, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 800, isPlaying: true, trackEpoch: 1
        ))
        #expect(!clock.isStalled)
        #expect(clock.estimate(nowMonotonicMs: 900).isExtrapolated)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 1_200, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.isStalled)
        #expect(clock.estimate(nowMonotonicMs: 1_300) == PlaybackEstimate(
            positionMs: 10_000, isExtrapolated: false, isStale: true
        ))
    }

    @Test("位置读取失败的样本不替换锚点但计入无进展：超限后陈旧")
    func invalidSampleKeepsAnchorAndCountsStall() {
        var clock = InterpolatedPlaybackClock(stallSampleLimit: 3)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        // 三个读取失败样本（positionMs == nil）：锚点保持 10_000。
        clock.apply(sample: PlaybackSample(
            positionMs: nil, sampledAtMonotonicMs: 400, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: nil, sampledAtMonotonicMs: 800, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: nil, sampledAtMonotonicMs: 1_200, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.sample?.positionMs == 10_000)
        #expect(clock.isStalled)
        #expect(clock.estimate(nowMonotonicMs: 1_300) == PlaybackEstimate(
            positionMs: 10_000, isExtrapolated: false, isStale: true
        ))
    }

    @Test("位置前进的样本解除停滞冻结（音乐恢复前进）")
    func progressUnfreezes() {
        var clock = InterpolatedPlaybackClock(stallSampleLimit: 2)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 400, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 800, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.isStalled)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_500, sampledAtMonotonicMs: 1_200, isPlaying: true, trackEpoch: 1
        ))
        #expect(!clock.isStalled)
        #expect(clock.estimate(nowMonotonicMs: 1_500) == PlaybackEstimate(
            positionMs: 10_800, isExtrapolated: true, isStale: false
        ))
    }

    // MARK: - 暂停样本重置连击

    @Test("暂停样本清零连击与停滞：随后恢复播放正常外推")
    func pausedSampleResetsStallCounters() {
        var clock = InterpolatedPlaybackClock(stallSampleLimit: 2)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 0, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 400, isPlaying: true, trackEpoch: 1
        ))
        clock.apply(sample: PlaybackSample(
            positionMs: 10_000, sampledAtMonotonicMs: 800, isPlaying: true, trackEpoch: 1
        ))
        #expect(clock.isStalled)
        clock.apply(sample: PlaybackSample(
            positionMs: 10_400, sampledAtMonotonicMs: 1_200, isPlaying: false, trackEpoch: 1
        ))
        #expect(!clock.isStalled)
        #expect(clock.consecutiveNoProgressSamples == 0)
        #expect(clock.estimate(nowMonotonicMs: 9_999) == PlaybackEstimate(
            positionMs: 10_400, isExtrapolated: false, isStale: false
        ))
    }

    // MARK: - 阈值下限防御

    @Test("停滞阈值至少为 1（非法配置被收敛）")
    func stallThresholdFloor() {
        let clock = InterpolatedPlaybackClock(stallSampleLimit: 0)
        #expect(clock.stallSampleLimit == 1)
    }
}
