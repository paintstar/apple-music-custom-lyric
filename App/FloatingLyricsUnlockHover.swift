import Foundation

/// 集中保存悬浮解锁的默认等待与可调整范围，设置页和窗口共用同一偏好。
enum FloatingLyricsUnlockSettings {
    static let delayPreferenceKey = "floatingLyrics.unlockHoverDelaySeconds"
    static let defaultDelay: TimeInterval = 3
    static let delayRange: ClosedRange<TimeInterval> = 0.5...10
    static let delayStep: TimeInterval = 0.5

    static func delay(in defaults: UserDefaults) -> TimeInterval {
        guard let number = defaults.object(forKey: delayPreferenceKey) as? NSNumber else { return defaultDelay }
        return normalized(number.doubleValue)
    }

    static func normalized(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return defaultDelay }
        return min(max(delay, delayRange.lowerBound), delayRange.upperBound)
    }
}

/// 只记连续悬浮的单调时钟起点；移出即清空，不累计分段悬浮。
struct FloatingLyricsUnlockHover {
    private var enteredAt: TimeInterval?

    mutating func shouldShow(isInside: Bool, time: TimeInterval, delay: TimeInterval) -> Bool {
        guard isInside, time.isFinite else { reset(); return false }
        if enteredAt.map({ time < $0 }) ?? true { enteredAt = time }
        return time - (enteredAt ?? time) >= FloatingLyricsUnlockSettings.normalized(delay)
    }

    mutating func reset() { enteredAt = nil }
}
