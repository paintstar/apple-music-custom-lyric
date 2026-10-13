import AppKit
import ShinLyricsEngine

/// 在原生歌词的固定等待槽内绘制。时间完全来自播放样本的受限估计，
/// 暂停、未知或过期时保留当前画面；不拥有 Timer 或无限循环的墙钟动画。
@MainActor
final class InterludeDotsView: NSView {
    private(set) var interval: LyricsWaitingInterval?
    private(set) var playbackPositionMs: Int64?
    private(set) var progress: Double?
    /// 每点占等待区间的三分之一；未知时间为 nil，不虚构零进度。
    private(set) var fillAmounts: [Double]?
    private var reduceMotion = false
    private static let dotDiameter: CGFloat = 8
    private static let dotSpacing: CGFloat = 10

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
        let interval = interval.flatMap { $0.shouldShowIndicator ? $0 : nil }
        let changedInterval = self.interval != interval
        let changedMotion = self.reduceMotion != reduceMotion
        if changedInterval {
            self.interval = interval
            playbackPositionMs = nil
            progress = nil
            fillAmounts = nil
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
            fillAmounts = progress.map { value in (0..<3).map { min(1, max(0, value * 3 - Double($0))) } }
        }
        if changedInterval || changedPosition || changedMotion { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard interval != nil else { return }
        let diameter = Self.dotDiameter
        for index in 0..<3 {
            let rect = NSRect(x: CGFloat(index) * (diameter + Self.dotSpacing),
                              y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            let circle = NSBezierPath(ovalIn: rect)
            NSColor.white.withAlphaComponent(0.12).setFill()
            circle.fill()
            let fill = fillAmounts?[index] ?? 0
            if fill > 0 {
                NSGraphicsContext.saveGraphicsState()
                circle.addClip()
                NSColor.white.withAlphaComponent(reduceMotion ? 0.62 : 0.9).setFill()
                let height = diameter * fill
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - height, width: diameter, height: height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.white.withAlphaComponent(0.4).setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
    }
}
