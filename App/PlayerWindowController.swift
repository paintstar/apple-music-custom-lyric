import AppKit
import SwiftUI

/// 每个窗口保留自己的完整尺寸；尺寸都是布局参数，屏幕位置由当前显示器决定。
@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    static let minimumSize = NSSize(width: 300, height: 480)
    static let compactBreakpoint: CGFloat = 760
    // 项目外观参数：让原生窗口按钮避开侧栏圆角内框，间距与尺寸仍由系统决定。
    private static let windowButtonInset = NSSize(width: 20, height: 12)
    private weak var window: NSWindow?
    private var expandedFrame: NSRect?
    private var buttonLayoutTask: Task<Void, Never>?

    func attach(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: self.window)
        }
        self.window = window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = Self.minimumSize
        for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged),
                                                   name: name, object: window)
        }
        refreshWindowButtons()
    }

    deinit {
        buttonLayoutTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        refreshWindowButtons()
    }

    fileprivate func refreshWindowButtons() {
        layoutWindowButtons()
        buttonLayoutTask?.cancel()
        // 等本轮 AppKit/SwiftUI 标题栏布局完成后再校正，覆盖初次显示与模式切换。
        buttonLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.layoutWindowButtons()
        }
    }

    private func layoutWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let controls = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { type -> (button: NSButton, frame: NSRect)? in
                guard let button = window.standardWindowButton(type), button.superview != nil else { return nil }
                return (button, button.convert(button.bounds, to: nil))
            }
        guard let first = controls.first else { return }
        let group = controls.reduce(first.frame) { $0.union($1.frame) }
        let dx = Self.windowButtonInset.width - group.minX
        var dy = window.frame.height - Self.windowButtonInset.height - group.maxY
        // 标题栏高度由系统决定；限制向下移动，不能把原生按钮移出父容器而裁切。
        let lowestShift = controls.map { control in
            guard let parent = control.button.superview else { return CGFloat.zero }
            return parent.convert(parent.bounds, to: nil).minY - control.frame.minY
        }.max() ?? 0
        dy = max(dy, lowestShift)
        guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
        for control in controls {
            guard let parent = control.button.superview else { continue }
            let frame = parent.convert(control.frame.offsetBy(dx: dx, dy: dy), from: nil)
            control.button.setFrameOrigin(frame.origin)
        }
    }

    func showCompact(reduceMotion: Bool) {
        guard let window else { return }
        // 全屏窗口由系统管理尺寸；退出全屏后用户即可切换。
        guard !window.styleMask.contains(.fullScreen) else { return }
        if window.frame.width >= Self.compactBreakpoint {
            expandedFrame = window.frame
        }
        let content = NSRect(origin: .zero, size: NSSize(width: 320, height: 720))
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(constrained(frame, for: window), display: true, animate: !reduceMotion)
    }

    func showExpanded(reduceMotion: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let fallback = NSRect(x: window.frame.minX, y: window.frame.maxY - 780,
                              width: 1180, height: 780)
        window.setFrame(constrained(expandedFrame ?? fallback, for: window),
                        display: true, animate: !reduceMotion)
    }

    private func constrained(_ proposed: NSRect, for window: NSWindow) -> NSRect {
        guard let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return proposed
        }
        var frame = proposed
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }
}

struct PlayerWindowAccessor: NSViewRepresentable {
    let controller: PlayerWindowController

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(controller: controller)
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {
        controller.attach(nsView.window)
    }

    final class WindowProbe: NSView {
        let controller: PlayerWindowController

        init(controller: PlayerWindowController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.attach(window)
        }

        override func layout() {
            super.layout()
            controller.refreshWindowButtons()
        }
    }
}
