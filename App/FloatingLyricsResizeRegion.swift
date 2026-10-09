import AppKit
import SwiftUI

/// 透明宽边只负责缩放；中央返回 nil，歌词滚动、顶部拖动和按钮按原有层级命中。
struct FloatingLyricsResizeRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: ResizeView, context: Context) { view.isEnabled = isEnabled }

    final class ResizeView: NSView {
        var isEnabled = true {
            didSet {
                guard isEnabled != oldValue else { return }
                if !isEnabled { cancelResize() }
                window?.invalidateCursorRects(for: self)
            }
        }
        private var edge: FloatingLyricsResizeGeometry.Edge?
        private var initialFrame: NSRect?
        private var initialPoint: NSPoint?
        private var visibleFrame: NSRect?
        private weak var dragWindow: NSWindow?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard isEnabled, !isHiddenOrHasHiddenAncestor, window?.ignoresMouseEvents != true,
                  FloatingLyricsResizeGeometry.handle(at: convert(point, from: superview), in: bounds) != nil else { return nil }
            return self
        }

        override func resetCursorRects() {
            guard isEnabled, window?.ignoresMouseEvents != true else { return }
            for handle in FloatingLyricsResizeGeometry.Edge.allCases {
                let rect = FloatingLyricsResizeGeometry.region(for: handle, in: bounds)
                if !rect.isEmpty { addCursorRect(rect, cursor: cursor(for: handle)) }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { window?.invalidateCursorRects(for: self) }
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let window, !window.ignoresMouseEvents,
                  let handle = FloatingLyricsResizeGeometry.handle(at: convert(event.locationInWindow, from: nil),
                                                                  in: bounds) else { return }
            edge = handle
            initialFrame = window.frame
            initialPoint = window.convertPoint(toScreen: event.locationInWindow)
            visibleFrame = FloatingLyricsWindowGeometry.visibleFrame(for: window.frame,
                                                                     visibleFrames: NSScreen.screens.map(\.visibleFrame))
            dragWindow = window
            cursor(for: handle).set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard isEnabled, let window, dragWindow === window, !window.ignoresMouseEvents,
                  let edge, let initialFrame, let initialPoint else { cancelResize(); return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let frame = FloatingLyricsResizeGeometry.resizedFrame(
                initial: initialFrame, delta: NSSize(width: point.x - initialPoint.x, height: point.y - initialPoint.y),
                edge: edge, limits: .init(minimumSize: window.minSize, maximumSize: window.maxSize, visibleFrame: visibleFrame)
            )
            window.setFrame(frame, display: true, animate: false)
            cursor(for: edge).set()
        }

        override func mouseUp(with event: NSEvent) {
            guard edge != nil else { return }
            mouseDragged(with: event)
            cancelResize()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { cancelResize() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cancelOperation(_ sender: Any?) { cancelResize() }

        private func cancelResize() {
            edge = nil
            initialFrame = nil
            initialPoint = nil
            visibleFrame = nil
            dragWindow = nil
        }

        private func cursor(for edge: FloatingLyricsResizeGeometry.Edge) -> NSCursor {
            if #available(macOS 15, *) {
                return .frameResize(position: cursorPosition(for: edge), directions: .all)
            }
            switch edge {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
            }
        }

        @available(macOS 15, *)
        private func cursorPosition(for edge: FloatingLyricsResizeGeometry.Edge) -> NSCursor.FrameResizePosition {
            switch edge {
            case .left: return .left
            case .right: return .right
            case .top: return .top
            case .bottom: return .bottom
            case .topLeft: return .topLeft
            case .topRight: return .topRight
            case .bottomLeft: return .bottomLeft
            case .bottomRight: return .bottomRight
            }
        }
    }
}

enum FloatingLyricsResizeGeometry {
    /// 无边框窗的可见边缘很薄；12 点命中带更容易抓取且不占歌词中央。
    static let hitWidth: CGFloat = 12

    enum Edge: CaseIterable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        fileprivate var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        fileprivate var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        fileprivate var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        fileprivate var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    struct Limits {
        let minimumSize: NSSize
        let maximumSize: NSSize
        let visibleFrame: NSRect?
    }

    static func handle(at point: NSPoint, in bounds: NSRect, regionWidth: CGFloat = hitWidth) -> Edge? {
        guard bounds.contains(point) else { return nil }
        let width = min(regionWidth, bounds.width / 2, bounds.height / 2)
        let left = point.x < bounds.minX + width
        let right = point.x >= bounds.maxX - width
        let bottom = point.y < bounds.minY + width
        let top = point.y >= bounds.maxY - width
        if top && left { return .topLeft }
        if top && right { return .topRight }
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return nil
    }

    static func region(for edge: Edge, in bounds: NSRect, regionWidth: CGFloat = hitWidth) -> NSRect {
        let width = min(regionWidth, bounds.width / 2, bounds.height / 2)
        switch edge {
        case .left: return NSRect(x: bounds.minX, y: bounds.minY + width, width: width, height: bounds.height - 2 * width)
        case .right: return NSRect(x: bounds.maxX - width, y: bounds.minY + width, width: width, height: bounds.height - 2 * width)
        case .top: return NSRect(x: bounds.minX + width, y: bounds.maxY - width, width: bounds.width - 2 * width, height: width)
        case .bottom: return NSRect(x: bounds.minX + width, y: bounds.minY, width: bounds.width - 2 * width, height: width)
        case .topLeft: return NSRect(x: bounds.minX, y: bounds.maxY - width, width: width, height: width)
        case .topRight: return NSRect(x: bounds.maxX - width, y: bounds.maxY - width, width: width, height: width)
        case .bottomLeft: return NSRect(x: bounds.minX, y: bounds.minY, width: width, height: width)
        case .bottomRight: return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: width)
        }
    }

    /// delta 使用屏幕坐标（向上为正）；触碰哪一侧只移动该侧，对边在裁剪后仍固定。
    static func resizedFrame(initial: NSRect, delta: NSSize, edge: Edge, limits: Limits) -> NSRect {
        let horizontal = resizedAxis(initial: (initial.minX, initial.width), delta: delta.width,
                                     movingLower: edge.movesLeft, movingUpper: edge.movesRight,
                                     limits: axisLimits(minimum: limits.minimumSize.width, maximum: limits.maximumSize.width,
                                                        visibleRange: limits.visibleFrame.map { $0.minX...$0.maxX }))
        let vertical = resizedAxis(initial: (initial.minY, initial.height), delta: delta.height,
                                   movingLower: edge.movesBottom, movingUpper: edge.movesTop,
                                   limits: axisLimits(minimum: limits.minimumSize.height, maximum: limits.maximumSize.height,
                                                      visibleRange: limits.visibleFrame.map { $0.minY...$0.maxY }))
        return NSRect(x: horizontal.lower, y: vertical.lower, width: horizontal.size, height: vertical.size)
    }

    private static func axisLimits(minimum: CGFloat, maximum: CGFloat, visibleRange: ClosedRange<CGFloat>?)
        -> (sizeRange: ClosedRange<CGFloat>, visibleRange: ClosedRange<CGFloat>?) {
        let maximum = max(0, maximum)
        return (min(max(0, minimum), maximum)...maximum, visibleRange)
    }

    private static func resizedAxis(initial: (lower: CGFloat, size: CGFloat), delta: CGFloat,
                                    movingLower: Bool, movingUpper: Bool,
                                    limits: (sizeRange: ClosedRange<CGFloat>, visibleRange: ClosedRange<CGFloat>?))
        -> (lower: CGFloat, size: CGFloat) {
        guard movingLower || movingUpper else { return initial }
        let anchor = movingLower ? initial.lower + initial.size : initial.lower
        let available = limits.visibleRange.map { movingLower ? anchor - $0.lowerBound : $0.upperBound - anchor }
            ?? limits.sizeRange.upperBound
        let limit = max(0, min(limits.sizeRange.upperBound, available))
        let minimum = min(limits.sizeRange.lowerBound, limit)
        let resized = min(max(initial.size + (movingLower ? -delta : delta), minimum), limit)
        return (movingLower ? anchor - resized : anchor, resized)
    }
}
