import AppKit

/// 原生叠加条仍保留命中、拖动和辅助功能；跟随播放时不反复唤出旋钮。
/// 仅覆写 AppKit 公开的部件绘制入口，系统继续管理几何、跟踪及淡隐。
@MainActor
class LyricsOverlayScroller: NSScroller {
    var followsPlayback = true {
        didSet { if oldValue != followsPlayback { needsDisplay = true } }
    }
    private var pointerInside = false
    private var pointerTracking: NSTrackingArea?
    var onPointerEnter: (() -> Void)?
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnob() {
        guard !followsPlayback || pointerInside else { return }
        super.drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard !followsPlayback || pointerInside else { return }
        super.drawKnobSlot(in: slotRect, highlight: flag)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        needsDisplay = true
        onPointerEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        endPointerHover()
    }

    func endPointerHover() {
        pointerInside = false
        needsDisplay = true
    }
}

@MainActor
final class LyricsDocumentCanvas: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LyricsClipView: NSClipView {
    var onBoundsChange: (() -> Void)?
    private var observedOrigin: NSPoint = .zero

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: self
        )
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func boundsChanged() {
        // NSClipView.scroll(to:) 不保证调用 setBoundsOrigin，通知覆盖其内部的滚动路径。
        guard bounds.origin != observedOrigin else { return }
        observedOrigin = bounds.origin
        onBoundsChange?()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

@MainActor
final class LyricRowAccessibilityElement: NSAccessibilityElement {
    nonisolated let lineId: UUID
    nonisolated private let onReplay: @MainActor @Sendable (UUID) -> Bool

    init(lineId: UUID, onReplay: @escaping @MainActor @Sendable (UUID) -> Bool) {
        self.lineId = lineId
        self.onReplay = onReplay
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        // NSAccessibilityElement 的旧协议入口未标注 actor；AppKit 的动作回调在主线程执行。
        let action = onReplay
        let id = lineId
        return MainActor.assumeIsolated { action(id) }
    }
}
