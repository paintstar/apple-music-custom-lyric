import Foundation

/// 阅读空闲后回到当前歌词的等待；只控制滚动，不参与歌词播放时间计算。
enum LyricsReadingSettings {
    static let resumeDelayPreferenceKey = "lyrics.readingResumeDelaySeconds"
    static let defaultResumeDelay: TimeInterval = 10
    static let resumeDelayRange: ClosedRange<TimeInterval> = 2...60
    static let resumeDelayStep: TimeInterval = 1

    static func resumeDelay(in defaults: UserDefaults) -> TimeInterval {
        guard let number = defaults.object(forKey: resumeDelayPreferenceKey) as? NSNumber else { return defaultResumeDelay }
        return normalized(number.doubleValue)
    }

    static func normalized(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return defaultResumeDelay }
        return min(max(delay, resumeDelayRange.lowerBound), resumeDelayRange.upperBound)
    }
}
