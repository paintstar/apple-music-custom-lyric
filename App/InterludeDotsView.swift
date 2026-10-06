import AppKit
import ShinLyricsEngine

/// 在原生歌词的固定等待槽内绘制。时间完全来自播放样本的受限估计，
/// 暂停、未知或过期时保留当前画面；不拥有 Timer 或无限循环的墙钟动画。
@MainActor
final class InterludeDotsView: NSView {
    private(set) var interval: LyricsWaitingInterval?
    private(set) var playbackPositionMs: Int64?
    private(set) var progress: Double?
    private var reduceMotion = false
    private static let dotDiameter: CGFloat = 8
    private static let dotSpacing: CGFloat = 10
    /// 最后两秒逐个点亮，给下一句柔和的预备提示，交接前始终保留末态。
    private static let cueDurationMs: Double = 2_000
    private static let breathDurationMs: Double = 1_800
    /// 在提示段开头用短于一次圆点点亮的过渡融合呼吸，边界亮度与速度连续。
    private static let cueBlendDurationMs: Double = 280

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(interval: LyricsWaitingInterval?, positionMs: Int64?, reduceMotion: Bool) {
        let changedInterval = self.interval != interval
        let changedMotion = self.reduceMotion != reduceMotion
        if changedInterval {
            self.interval = interval
            playbackPositionMs = nil
            progress = nil
            setAccessibilityLabel(interval?.anchorLineId == nil ? "前奏中，等待下一句歌词" : "间奏中，等待下一句歌词")
        }
        self.reduceMotion = reduceMotion
        isHidden = interval == nil
        guard let interval else { return }
        var changedPosition = false
        if let positionMs {
            let bounded = min(max(positionMs, interval.startMs), interval.endMs)
            changedPosition = playbackPositionMs != bounded
            playbackPositionMs = bounded
            progress = min(1, max(0, Double(bounded - interval.startMs) / Double(max(1, interval.endMs - interval.startMs))))
        }
        if changedInterval || changedPosition || changedMotion { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let interval else { return }
        let diameter = Self.dotDiameter
        let elapsed = playbackPositionMs.map { Double($0 - interval.startMs) }
        let remaining = playbackPositionMs.map { Double(interval.endMs - $0) }
        for index in 0..<3 {
            let brightness: Double
            if !reduceMotion, let elapsed, let remaining {
                let phase = elapsed / Self.breathDurationMs - Double(index) * 0.16
                let breath = 0.4 + 0.36 * max(0, sin(phase * 2 * .pi))
                let cue = (1 - remaining / Self.cueDurationMs) * 3 - Double(index)
                let filled = min(1, max(0, cue))
                let cueBrightness = 0.38 + 0.55 * filled * filled * (3 - 2 * filled)
                let blend = min(1, max(0, (Self.cueDurationMs - remaining) / Self.cueBlendDurationMs))
                let easedBlend = blend * blend * (3 - 2 * blend)
                brightness = breath + (cueBrightness - breath) * easedBlend
            } else {
                brightness = 0.62
            }
            let rect = NSRect(x: CGFloat(index) * (diameter + Self.dotSpacing),
                              y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            NSColor.white.withAlphaComponent(brightness).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}
