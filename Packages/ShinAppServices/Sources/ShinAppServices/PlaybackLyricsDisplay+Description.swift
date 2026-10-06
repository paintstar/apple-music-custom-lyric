import Foundation

// MARK: - 同步显示的展示描述（从歌词面板视图上收为可测纯逻辑）

extension PlaybackLyricsDisplay {

    /// 用户延迟的中文语义描述（UI 约定）：
    /// 0 = 「无偏移」；正数 = 「延后 N 秒」；负数 = 「提前 N 秒」。
    /// 数值保留一位小数（延迟调整步长 0.1 秒）。
    /// 歌词面板同步控制条使用；导出、跳转共用同一偏移语义，不在此转换。
    public var delayDescription: String {
        guard userDelayMs != 0 else { return "无偏移" }
        let magnitude = String(format: "%.1f", Double(abs(userDelayMs)) / 1_000)
        return userDelayMs > 0 ? "延后 \(magnitude) 秒" : "提前 \(magnitude) 秒"
    }
}
