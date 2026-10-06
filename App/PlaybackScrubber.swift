import AppKit
import SwiftUI
import QuartzCore
import ShinAppleKit

/// 命中区固定24点；胶囊仅在内部3→5.5→6.5点变化，避免浮栏重排和夸大的圆点。
enum ThinPlaybackSliderSizing {
    static let hitHeight: CGFloat = 24
    static let restingTrackHeight: CGFloat = 3
    static let hoveringTrackHeight: CGFloat = 5.5
    static let pressedTrackHeight: CGFloat = 6.5
    static let markerWidth: CGFloat = 2
    static let markerHeight: CGFloat = 8
    static let enteringDuration: TimeInterval = 0.18
    static let leavingDuration: TimeInterval = 0.22
    static let pressingDuration: TimeInterval = 0.08
}

/// NSSlider 保留系统键盘/辅助功能。鼠标跟踪期间只预览，结束后发出一次 seek；
/// 键盘或辅助功能的一次调节直接提交。快照更新不会覆盖拖动位置。
struct PlaybackScrubber: NSViewRepresentable {
    let snapshot: PlaybackSnapshot
    let positionMs: Int64?
    let durationMs: Int64
    let enabled: Bool
    let thinStyle: Bool
    var reduceMotion = false
    let onPreview: (Int64?) -> Void
    let onSeek: (Int64, PlaybackSnapshot) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider()
        if thinStyle { slider.cell = ThinPlaybackSliderCell() }
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.coordinator = context.coordinator
        slider.setAccessibilityLabel("播放进度")
        slider.toolTip = "拖动后松开即跳转；方向键微调进度"
        return slider
    }

    func updateNSView(_ slider: TrackingSlider, context: Context) {
        context.coordinator.parent = self
        slider.updatePlaybackEnabled(enabled)
        if slider.isTrackingMouse, !enabled || !context.coordinator.isTrackingCurrent {
            slider.cancelMouseTracking()
        }
        if let cell = slider.cell as? ThinPlaybackSliderCell {
            let positionKnown = positionMs != nil && durationMs > 1
            if cell.positionKnown != positionKnown {
                cell.positionKnown = positionKnown
                slider.needsDisplay = true
            }
        }
        slider.refreshInteractionAppearance()
        if !slider.isTrackingMouse {
            // 时间线每帧进入这里；数值外的原生属性只在变化时更新。
            let description = positionMs.map { PlayerBarView.formatDuration($0) } ?? "播放位置未知"
            if slider.accessibilityValueDescription() != description { slider.setAccessibilityValueDescription(description) }
            let maximum = Double(max(durationMs, 1))
            let position = Double(min(max(positionMs ?? 0, 0), max(durationMs, 1)))
            if slider.minValue != 0 { slider.minValue = 0 }
            if slider.maxValue != maximum { slider.maxValue = maximum }
            if slider.doubleValue != position { slider.doubleValue = position }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PlaybackScrubber
        var startedSnapshot: PlaybackSnapshot?
        private var interactionGeneration: UInt64 = 0
        init(_ parent: PlaybackScrubber) { self.parent = parent }

        func begin() {
            interactionGeneration &+= 1
            startedSnapshot = parent.snapshot
        }
        var isTrackingCurrent: Bool { parent.enabled && startedSnapshot.map(isCurrent) == true }

        func cancel() {
            startedSnapshot = nil
            interactionGeneration &+= 1
            let generation = interactionGeneration
            // 取消可能来自 updateNSView，清理 SwiftUI 状态必须离开本次渲染；新手势会使旧清理失效。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.interactionGeneration == generation, self.startedSnapshot == nil else { return }
                self.parent.onPreview(nil)
            }
        }

        @objc func changed(_ slider: TrackingSlider) {
            slider.setAccessibilityValueDescription(PlayerBarView.formatDuration(Int64(slider.doubleValue)))
            if slider.isTrackingMouse {
                parent.onPreview(startedSnapshot.map(isCurrent) == true ? Int64(slider.doubleValue) : nil)
            } else {
                commit(slider, expected: parent.snapshot)
            }
        }

        func end(_ slider: TrackingSlider) {
            defer { startedSnapshot = nil; parent.onPreview(nil) }
            guard let startedSnapshot else { return }
            commit(slider, expected: startedSnapshot)
        }

        private func commit(_ slider: TrackingSlider, expected: PlaybackSnapshot) {
            guard parent.enabled, isCurrent(expected) else { return }
            let position = min(max(Int64(slider.doubleValue), 0), parent.durationMs)
            parent.onSeek(position, expected)
        }

        private func isCurrent(_ expected: PlaybackSnapshot) -> Bool {
            expected.sessionEpoch == parent.snapshot.sessionEpoch
                && expected.trackEpoch == parent.snapshot.trackEpoch
                && expected.trackKey == parent.snapshot.trackKey
        }
    }

    @MainActor
    final class TrackingSlider: NSSlider {
        weak var coordinator: Coordinator?
        var isTrackingMouse = false {
            didSet { refreshInteractionAppearance() }
        }
        private var grabOffset: CGFloat = 0
        private var isPointerInside = false
        private var hoverTrackingArea: NSTrackingArea?
        private var appearanceTarget: CGFloat = 0
        private var usesImmediateAppearance = false

        // AppKit公开animator属性；只重绘外观，进度值和原生knobRect始终即时更新。
        @objc dynamic var interactionAmount: CGFloat = 0 {
            didSet {
                (cell as? ThinPlaybackSliderCell)?.interactionAmount = interactionAmount
                needsDisplay = true
            }
        }

        override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
            if key == #keyPath(TrackingSlider.interactionAmount) { return CABasicAnimation() }
            return super.defaultAnimation(forKey: key)
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { showKeyboardFocus(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { showKeyboardFocus(false) }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            showKeyboardFocus(true)
            super.keyDown(with: event)
        }

        private func showKeyboardFocus(_ shown: Bool) {
            guard let cell = cell as? ThinPlaybackSliderCell else { return }
            focusRingType = .default
            cell.showsKeyboardMarker = shown
            needsDisplay = true
        }

        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            if cell is ThinPlaybackSliderCell { size.height = ThinPlaybackSliderSizing.hitHeight }
            return size
        }

        override var alignmentRectInsets: NSEdgeInsets {
            // 自绘轨道的24点槽位就是完整控件边界，避免原生阴影留白伸出SwiftUI命中区域。
            cell is ThinPlaybackSliderCell ? NSEdgeInsetsZero : super.alignmentRectInsets
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard window != nil, cell is ThinPlaybackSliderCell, hoverTrackingArea == nil else { return }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            guard cell is ThinPlaybackSliderCell else { super.mouseEntered(with: event); return }
            isPointerInside = true
            refreshInteractionAppearance()
        }

        override func mouseExited(with event: NSEvent) {
            guard cell is ThinPlaybackSliderCell else { super.mouseExited(with: event); return }
            isPointerInside = false
            refreshInteractionAppearance()
        }

        func refreshInteractionAppearance() {
            guard let cell = cell as? ThinPlaybackSliderCell else { return }
            let available = isEnabled && coordinator?.parent.enabled == true && cell.positionKnown
            let target: CGFloat = available ? (isTrackingMouse ? 2 : (isPointerInside ? 1 : 0)) : 0
            let immediate = !available || window == nil || coordinator?.parent.reduceMotion == true
            let needsStop = immediate && !usesImmediateAppearance
            usesImmediateAppearance = immediate
            guard target != appearanceTarget || needsStop else { return }
            let duration = immediate ? 0 : target == 2 ? ThinPlaybackSliderSizing.pressingDuration
                : target < appearanceTarget ? ThinPlaybackSliderSizing.leavingDuration : ThinPlaybackSliderSizing.enteringDuration
            setAppearance(target, duration: duration)
        }

        private func setAppearance(_ target: CGFloat, duration: TimeInterval) {
            appearanceTarget = target
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().interactionAmount = target
            }
            // 零时长代理负责停止旧动画；同步写入保证本帧就使用终点外观。
            if duration == 0 { interactionAmount = target }
        }

        func updatePlaybackEnabled(_ enabled: Bool) {
            guard isEnabled != enabled else { return }
            guard !enabled, window?.firstResponder === self else {
                isEnabled = enabled
                return
            }
            // 禁用持焦点的 NSControl 会更新 SwiftUI 焦点图，需离开 updateNSView 后执行。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.coordinator?.parent.enabled == false else { return }
                if self.window?.firstResponder === self { self.window?.makeFirstResponder(nil) }
                self.isEnabled = false
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, coordinator?.parent.enabled == true else { return }
            window?.makeFirstResponder(self)
            if let cell = cell as? ThinPlaybackSliderCell {
                focusRingType = .none
                cell.showsKeyboardMarker = false
            }
            isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
            isTrackingMouse = true
            coordinator?.begin()
            let point = convert(event.locationInWindow, from: nil)
            let knob = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped) ?? .zero
            grabOffset = knob.contains(point) ? point.x - knob.midX : 0
            preview(event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard isTrackingMouse else { return }
            preview(event)
        }

        override func mouseUp(with event: NSEvent) {
            guard isTrackingMouse else { return }
            preview(event)
            isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
            isTrackingMouse = false
            coordinator?.end(self)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                isPointerInside = false
                cancelMouseTracking()
                if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
                hoverTrackingArea = nil
                setAppearance(0, duration: 0)
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cancelOperation(_ sender: Any?) { cancelMouseTracking() }

        func cancelMouseTracking() {
            guard isTrackingMouse else { return }
            isTrackingMouse = false
            coordinator?.cancel()
            setAppearance(appearanceTarget, duration: 0)
        }

        private func preview(_ event: NSEvent) {
            guard isEnabled, coordinator?.isTrackingCurrent == true else {
                cancelMouseTracking()
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let knobWidth = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped).width ?? 0
            let travel = bounds.width - knobWidth
            guard travel > 0 else { return }
            let fraction = min(max((point.x - grabOffset - bounds.minX - knobWidth / 2) / travel, 0), 1)
            doubleValue = minValue + Double(fraction) * (maxValue - minValue)
            needsDisplay = true
            sendAction(action, to: target)
        }
    }
}

/// 浮栏轨道根据本地鼠标状态绘制；原生knobRect仍是唯一的进度几何，不随视觉大小改变。
@MainActor
private final class ThinPlaybackSliderCell: NSSliderCell {
    var positionKnown = false
    var interactionAmount: CGFloat = 0
    var showsKeyboardMarker = false

    private var hoverAmount: CGFloat { min(max(interactionAmount, 0), 1) }
    private var pressAmount: CGFloat { min(max(interactionAmount - 1, 0), 1) }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let height = ThinPlaybackSliderSizing.restingTrackHeight
            + hoverAmount * (ThinPlaybackSliderSizing.hoveringTrackHeight - ThinPlaybackSliderSizing.restingTrackHeight)
            + pressAmount * (ThinPlaybackSliderSizing.pressedTrackHeight - ThinPlaybackSliderSizing.hoveringTrackHeight)
        let track = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let radius = height / 2
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.17 + hoverAmount * 0.06 + pressAmount * 0.04 : 0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        guard positionKnown else { return }
        let width = min(max(knobRect(flipped: flipped).midX - track.minX, 0), track.width)
        let filled = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
        NSColor.labelColor.withAlphaComponent(isEnabled ? 0.52 + hoverAmount * 0.18 + pressAmount * 0.12 : 0.24).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let markerOpacity = showsKeyboardMarker ? 1 : pressAmount
        guard positionKnown, isEnabled, markerOpacity > 0 else { return }
        let marker = NSRect(x: knobRect.midX - ThinPlaybackSliderSizing.markerWidth / 2,
                            y: knobRect.midY - ThinPlaybackSliderSizing.markerHeight / 2,
                            width: ThinPlaybackSliderSizing.markerWidth, height: ThinPlaybackSliderSizing.markerHeight)
        NSColor.labelColor.withAlphaComponent(0.90 * markerOpacity).setFill()
        NSBezierPath(roundedRect: marker, xRadius: ThinPlaybackSliderSizing.markerWidth / 2,
                     yRadius: ThinPlaybackSliderSizing.markerWidth / 2).fill()
    }
}
