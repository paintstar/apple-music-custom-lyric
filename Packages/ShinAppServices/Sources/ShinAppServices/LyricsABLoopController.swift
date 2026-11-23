import Foundation
import ShinAppleKit
import ShinLyricsEngine

/// 歌词单句 / AB 循环目标，携带曲目身份、生命周期编号与起止歌词行稳定 ID。
public struct LyricsABLoopTarget: Equatable, Sendable {
    public let documentId: UUID
    public let trackKey: String
    public let trackEpoch: Int
    public let startLineId: UUID
    public let endLineId: UUID
    public let startLineText: String
    public let endLineText: String

    public init(
        documentId: UUID,
        trackKey: String,
        trackEpoch: Int,
        startLineId: UUID,
        endLineId: UUID,
        startLineText: String,
        endLineText: String
    ) {
        self.documentId = documentId
        self.trackKey = trackKey
        self.trackEpoch = trackEpoch
        self.startLineId = startLineId
        self.endLineId = endLineId
        self.startLineText = startLineText
        self.endLineText = endLineText
    }
}

/// 歌词 AB 循环纯状态机（时间由调用方注入，便于单测确定性验证）。
///
/// 规则：
/// 1. 无 `activeTarget` → `.none`；
/// 2. 曲目键、`trackEpoch` 或当前文档任一变化 → 清除循环状态并返回 `.clear`；
/// 3. 非 `.playing` 状态或播放位置未知 → `.none`；
/// 4. 无法算出合法区间（`segmentProvider` 返回 nil 或 `endMs <= startMs`）→ `.none`；
/// 5. 当 `positionMs >= segment.endMs` 且距离上次自动回跳已达 `seekCooldownMs` 时，
///    记录本次触发时刻并返回 `.seekTo(ms: segment.startMs, expectedSnapshot: snapshot)`。
public struct LyricsABLoopEvaluator: Equatable, Sendable {

    /// 每次状态评估的结果动作。
    public enum Action: Equatable, Sendable {
        case none
        case clear
        case seekTo(ms: Int64, expectedSnapshot: PlaybackSnapshot)
    }

    /// 默认自动回跳防抖冷却时长（毫秒），避免播放器快照未及时反映 seek 前连续触发多次跳转。
    public static let defaultSeekCooldownMs: Int64 = 900

    public var activeTarget: LyricsABLoopTarget? {
        didSet {
            if activeTarget != oldValue {
                lastSeekTriggerMonotonicMs = nil
            }
        }
    }
    public var pendingAnchorLineId: UUID?
    public private(set) var lastSeekTriggerMonotonicMs: Int64?
    public let seekCooldownMs: Int64

    public init(
        activeTarget: LyricsABLoopTarget? = nil,
        pendingAnchorLineId: UUID? = nil,
        lastSeekTriggerMonotonicMs: Int64? = nil,
        seekCooldownMs: Int64 = LyricsABLoopEvaluator.defaultSeekCooldownMs
    ) {
        self.activeTarget = activeTarget
        self.pendingAnchorLineId = pendingAnchorLineId
        self.lastSeekTriggerMonotonicMs = lastSeekTriggerMonotonicMs
        self.seekCooldownMs = max(0, seekCooldownMs)
    }

    /// 记录待定 A 点行 ID（传 nil 取消待定锚点）。
    public mutating func setPendingAnchor(_ lineId: UUID?) {
        pendingAnchorLineId = lineId
    }

    /// 激活循环目标，并清除待定锚点与历史回跳冷却记录。
    public mutating func activate(_ target: LyricsABLoopTarget) {
        activeTarget = target
        pendingAnchorLineId = nil
        lastSeekTriggerMonotonicMs = nil
    }

    /// 清除当前循环目标、待定锚点与冷却记录。
    public mutating func clear() {
        activeTarget = nil
        pendingAnchorLineId = nil
        lastSeekTriggerMonotonicMs = nil
    }

    /// 按当前权威快照、文档 ID 与单调时钟评估下一步循环动作。
    public mutating func evaluate(
        snapshot: PlaybackSnapshot,
        currentDocumentId: UUID?,
        segmentProvider: (UUID, UUID) -> LyricsPlaybackSegment?,
        nowMonotonicMs: Int64
    ) -> Action {
        guard let target = activeTarget else {
            return .none
        }
        guard snapshot.trackKey == target.trackKey,
              snapshot.trackEpoch == target.trackEpoch,
              currentDocumentId == target.documentId
        else {
            clear()
            return .clear
        }
        guard snapshot.status == .playing,
              let positionMs = snapshot.positionMs
        else {
            return .none
        }
        guard let segment = segmentProvider(target.startLineId, target.endLineId),
              segment.endMs > segment.startMs
        else {
            return .none
        }
        guard positionMs >= segment.endMs else {
            return .none
        }
        if let lastTrigger = lastSeekTriggerMonotonicMs {
            let (elapsed, overflow) = nowMonotonicMs.subtractingReportingOverflow(lastTrigger)
            if !overflow, elapsed >= 0, elapsed < seekCooldownMs {
                return .none
            }
        }
        lastSeekTriggerMonotonicMs = nowMonotonicMs
        return .seekTo(ms: segment.startMs, expectedSnapshot: snapshot)
    }
}
