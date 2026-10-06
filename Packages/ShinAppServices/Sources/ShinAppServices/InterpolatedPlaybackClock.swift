import Foundation
import ShinAppleKit

// MARK: - 展示层插值时钟

/// 插值时钟的一条输入样本：权威快照的最小投影。
/// 时间域：`sampledAtMonotonicMs` 与 `estimate(nowMonotonicMs:)` 必须来自
/// 同一宿主进程单调时钟，跨时钟域不可直接比较；
/// 快照未提供采样时刻（合同默认 0）时由调用方用宿主单调钟补盖到达时刻。
public struct PlaybackSample: Equatable, Sendable {
    /// 权威播放位置（整数毫秒）；读取失败/未知为 nil（未知绝不冒充 0）。
    public var positionMs: Int64?
    /// 采样时刻的宿主单调时钟毫秒。
    public var sampledAtMonotonicMs: Int64
    /// 快照状态是否为 playing（仅此状态允许插值外推）。
    public var isPlaying: Bool
    /// 曲目生命周期编号（切歌时递增；变化即重置估计）。
    public var trackEpoch: Int

    public init(
        positionMs: Int64?,
        sampledAtMonotonicMs: Int64,
        isPlaying: Bool,
        trackEpoch: Int
    ) {
        self.positionMs = positionMs
        self.sampledAtMonotonicMs = sampledAtMonotonicMs
        self.isPlaying = isPlaying
        self.trackEpoch = trackEpoch
    }
}

/// 一次位置估计的产出。
public struct PlaybackEstimate: Equatable, Sendable {
    /// 估计位置（整数毫秒）；无有效样本为 nil（显示 null，不显示 0）。
    public var positionMs: Int64?
    /// 正在按「样本位置 + 单调差」外推。
    public var isExtrapolated: Bool
    /// 陈旧标记：外推超上限已钉回样本值，或连击无进展已冻结估计
    /// （UI 据此弱化显示，不冒充精确时间）。
    public var isStale: Bool

    public static let none = PlaybackEstimate(positionMs: nil, isExtrapolated: false, isStale: false)

    public init(positionMs: Int64?, isExtrapolated: Bool, isStale: Bool) {
        self.positionMs = positionMs
        self.isExtrapolated = isExtrapolated
        self.isStale = isStale
    }
}

/// 展示层插值时钟（纯逻辑值类型；时间由调用方注入，全规则可 Mock 时钟单测）。
///
/// 显示规则：
/// - **插值只基于最近有效样本**：无样本不插值，绝不从启动时间累加；
///   估计 = 样本位置 +（当前单调时刻 − 采样时刻），新样本到达即校正；
/// - **仅在 playing 状态估计**：暂停/其他状态冻结显示样本值，不推进；
/// - **外推上限 1 秒**：超限后钉在样本值并标记陈旧（`isStale`），
///   绝不长时间凭空推进；
/// - **失效即重置/冻结**：切歌（trackEpoch 变化）、暂停、seek 后的新样本、
///   单调时钟倒退（时钟域重映射/休眠唤醒）都使估计从新样本重新出发；
///   连续无进展样本（播放中位置不前进，含位置读取失败）达到阈值后冻结估计；
/// - **权威语义不变**：脚本采样返回的播放位置仍是唯一权威时间，本类型
///   是展示层新增，不改变协调器「快照整查」的同步语义。
public struct InterpolatedPlaybackClock: Sendable {

    /// 外推上限（毫秒），默认 1 秒，可按采样策略调整。
    public static let defaultExtrapolationLimitMs: Int64 = 1_000
    /// 连续无进展样本冻结阈值（个）。默认 4：400ms 采样 + 1 秒位置粒度的
    /// 组合下，真实前进时最多连续 2~3 个样本位置不变，4 个即视为停滞。
    public static let defaultStallSampleLimit: Int = 4

    /// 最近一次有效样本（锚点）。nil = 尚无任何样本。
    public private(set) var sample: PlaybackSample?
    /// 连续无进展的播放样本计数（达 `stallSampleLimit` 后冻结估计）。
    public private(set) var consecutiveNoProgressSamples = 0
    /// 停滞冻结中：估计钉在样本值，直到出现位置前进的播放样本。
    public private(set) var isStalled = false

    public let extrapolationLimitMs: Int64
    public let stallSampleLimit: Int

    public init(
        extrapolationLimitMs: Int64 = InterpolatedPlaybackClock.defaultExtrapolationLimitMs,
        stallSampleLimit: Int = InterpolatedPlaybackClock.defaultStallSampleLimit
    ) {
        self.extrapolationLimitMs = max(extrapolationLimitMs, 0)
        self.stallSampleLimit = max(stallSampleLimit, 1)
    }

    /// 输入一条新的权威样本（新样本到达即校正：估计永远从本样本重新出发）。
    public mutating func apply(sample newSample: PlaybackSample) {
        if let current = self.sample {
            // 切歌（trackEpoch 变化）→ 重置估计与连击计数（失效条件）。
            if newSample.trackEpoch != current.trackEpoch {
                consecutiveNoProgressSamples = 0
                isStalled = false
                self.sample = newSample
                return
            }
            // 单调时钟倒退 = 时钟域重映射/休眠唤醒：旧锚点的时刻不可再比较，
            // 重置连击计数并从新样本重新出发。
            if newSample.sampledAtMonotonicMs < current.sampledAtMonotonicMs {
                consecutiveNoProgressSamples = 0
                isStalled = false
                self.sample = newSample
                return
            }
            // 进展判定：仅统计播放中的样本；位置前进 → 解除冻结并清零连击；
            // 位置不变或未知（读取失败）→ 累计，达阈值后冻结估计。
            if newSample.isPlaying {
                let progressed = newSample.positionMs != nil
                    && newSample.positionMs != current.positionMs
                if progressed {
                    consecutiveNoProgressSamples = 0
                    isStalled = false
                } else {
                    consecutiveNoProgressSamples += 1
                    if consecutiveNoProgressSamples >= stallSampleLimit {
                        isStalled = true
                    }
                }
            } else {
                // 暂停等状态：冻结语义由 estimate 承担；连击计数重置。
                consecutiveNoProgressSamples = 0
                isStalled = false
            }
        }
        // 无效样本（positionMs == nil）不替换锚点：插值只基于最近「有效」样本；
        // 有效样本（含暂停冻结值）成为新锚点。
        if newSample.positionMs != nil {
            self.sample = newSample
        } else if self.sample == nil {
            // 从未有过有效样本：保留 nil 锚点本身（未知时间显示 null）。
            self.sample = newSample
        }
    }

    /// 估计当前展示位置（纯函数；`nowMonotonicMs` 与样本同一时钟域，调用方注入）。
    public func estimate(nowMonotonicMs: Int64) -> PlaybackEstimate {
        guard let anchor = sample, let positionMs = anchor.positionMs else {
            return .none
        }
        // 仅 playing 插值：暂停/其他状态冻结在样本值。
        guard anchor.isPlaying, !isStalled else {
            return PlaybackEstimate(
                positionMs: positionMs,
                isExtrapolated: false,
                isStale: isStalled
            )
        }
        let deltaMs = nowMonotonicMs - anchor.sampledAtMonotonicMs
        guard deltaMs > 0 else {
            // 时刻未越过采样点（含时钟域扰动）：原样显示样本值。
            return PlaybackEstimate(positionMs: positionMs, isExtrapolated: false, isStale: false)
        }
        if deltaMs > extrapolationLimitMs {
            // 超过外推上限：钉在样本值并标记陈旧。
            return PlaybackEstimate(positionMs: positionMs, isExtrapolated: false, isStale: true)
        }
        return PlaybackEstimate(
            positionMs: positionMs + deltaMs,
            isExtrapolated: true,
            isStale: false
        )
    }
}
