import AppKit
import SwiftUI

/// 正文优先拖窗，滚轮转交原来的歌词滚动视图；光标由窗口统一管理。
struct FloatingLyricsDragRegion: NSViewRepresentable {
    let isEnabled: Bool
    let excludedRect: NSRect
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.onHover = onHover
        view.isEnabled = isEnabled
        view.excludedRect = excludedRect
    }

    final class DragView: NSView {
        var isEnabled = true {
            didSet {
                guard isEnabled != oldValue else { return }
                if !isEnabled { lastReportedHover = false; cancelDrag() }
                updateTrackingAreas()
                scheduleCursorRefresh()
            }
        }
        var excludedRect = NSRect.zero {
            didSet { if excludedRect != oldValue { scheduleCursorRefresh() } }
        }
        var onHover: (Bool) -> Void = { _ in }
        private var lastReportedHover = false
        private var hoverTrackingArea: NSTrackingArea?
        private var cursorTrackingArea: NSTrackingArea?
        private(set) var isDragging = false
        private var initialFrame: NSRect?
        private var initialPoint: NSPoint?
        private weak var dragWindow: NSWindow?

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard canInteract, containsDragPoint(convert(point, from: superview)) else { return nil }
            return self
        }

        func reportHover(_ value: Bool) {
            guard value != lastReportedHover else { return }
            lastReportedHover = value
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.hoverValueChanged", view: self, hoverValue: value)
            #endif
            onHover(value)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard canInteract else { removeInteractionTrackingAreas(); return }
            // inVisibleRect 自动跟随布局，保留 identity，避免替换 tracking 产生无关的退出/进入。
            if hoverTrackingArea == nil {
                let area = NSTrackingArea(rect: .zero,
                                          options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                          owner: self, userInfo: nil)
                addTrackingArea(area)
                hoverTrackingArea = area
            }
            // 当前 AppKit 不支持 activeAlways + cursorUpdate，光标仲裁另用合法的 activeInActiveApp。
            if cursorTrackingArea == nil {
                let area = NSTrackingArea(rect: .zero, options: [.activeInActiveApp, .cursorUpdate, .inVisibleRect],
                                          owner: self, userInfo: nil)
                addTrackingArea(area)
                cursorTrackingArea = area
            }
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.trackingRegistered", view: self)
            #endif
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard canInteract else { return }
            for rect in FloatingLyricsDragGeometry.regions(in: bounds, excluding: excludedRect) {
                addCursorRect(rect, cursor: isDragging ? .closedHand : .openHand)
            }
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.cursorRectsRegistered", view: self)
            #endif
        }

        // Tracking 只转交同一窗口协调器，真实移出会清理悬浮状态，不自行设置光标。
        override func mouseEntered(with event: NSEvent) {
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.mouseEntered", event: event, view: self)
            #endif
            (window as? FloatingLyricsPanel)?.receiveTrackingEvent(event)
        }
        override func mouseMoved(with event: NSEvent) {
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.mouseMoved", event: event, view: self)
            #endif
            (window as? FloatingLyricsPanel)?.receiveTrackingEvent(event)
        }
        // 只让整窗 tracking 的退出清理状态；SwiftUI 按钮/子区域退出不代表指针离开本窗。
        override func mouseExited(with event: NSEvent) {
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.mouseExited", event: event, view: self)
            #endif
            (window as? FloatingLyricsPanel)?.receiveWindowExit()
        }
        override func cursorUpdate(with event: NSEvent) {
            #if DEBUG
            (window as? FloatingLyricsPanel)?.traceFloatingCursor("drag.cursorUpdate", event: event, view: self)
            #endif
            (window as? FloatingLyricsPanel)?.receiveTrackingEvent(event)
        }
        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { scheduleCursorRefresh() }
        }

        override func mouseDown(with event: NSEvent) {
            guard canInteract, let window, window.isMovable,
                  containsDragPoint(convert(event.locationInWindow, from: nil)) else { return }
            initialFrame = window.frame
            initialPoint = window.convertPoint(toScreen: event.locationInWindow)
            dragWindow = window
            isDragging = true
            scheduleCursorRefresh()
        }

        override func mouseDragged(with event: NSEvent) {
            guard canInteract, let window, window.isMovable, dragWindow === window,
                  let initialFrame, let initialPoint else { cancelDrag(); return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: initialFrame.minX + point.x - initialPoint.x,
                                          y: initialFrame.minY + point.y - initialPoint.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard isDragging else { return }
            mouseDragged(with: event)
            cancelDrag()
        }

        override func scrollWheel(with event: NSEvent) {
            guard canInteract else { return }
            scrollView(in: window?.contentView)?.scrollWheel(with: event)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                lastReportedHover = false
                cancelDrag()
                removeInteractionTrackingAreas()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cancelOperation(_ sender: Any?) { cancelDrag() }

        private func removeInteractionTrackingAreas() {
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea); self.hoverTrackingArea = nil }
            if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea); self.cursorTrackingArea = nil }
        }

        private var canInteract: Bool { isEnabled && !isHiddenOrHasHiddenAncestor && window?.ignoresMouseEvents != true }

        private func containsDragPoint(_ point: NSPoint) -> Bool {
            FloatingLyricsDragGeometry.regions(in: bounds, excluding: excludedRect).contains { $0.contains(point) }
        }

        private func cancelDrag() {
            initialFrame = nil
            initialPoint = nil
            dragWindow = nil
            isDragging = false
            scheduleCursorRefresh()
        }

        private func scheduleCursorRefresh() {
            (window as? FloatingLyricsPanel)?.refreshFloatingCursor()
        }

        private func scrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollView).first
        }
    }
}

enum FloatingLyricsDragGeometry {
    /// 四周宽边先交给缩放，工具条的真实布局位置由 SwiftUI 传入。
    static func regions(in bounds: NSRect, excluding excludedRect: NSRect) -> [NSRect] {
        let inset = FloatingLyricsResizeGeometry.hitWidth
        let content = bounds.insetBy(dx: inset, dy: inset)
        guard content.width > 0, content.height > 0 else { return [] }
        return subtracting(excludedRect, from: content)
    }

    /// 工具条覆盖边缘时也要裁掉，原生缩放光标与按钮不能登记在同一块区域。
    static func subtracting(_ excludedRect: NSRect, from content: NSRect) -> [NSRect] {
        let cutout = content.intersection(excludedRect)
        guard !cutout.isEmpty, !cutout.isNull else { return [content] }
        return [
            NSRect(x: content.minX, y: content.minY, width: content.width, height: cutout.minY - content.minY),
            NSRect(x: content.minX, y: cutout.maxY, width: content.width, height: content.maxY - cutout.maxY),
            NSRect(x: content.minX, y: cutout.minY, width: cutout.minX - content.minX, height: cutout.height),
            NSRect(x: cutout.maxX, y: cutout.minY, width: content.maxX - cutout.maxX, height: cutout.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
