import AppKit
import SwiftUI

/// 每个窗口保留自己的完整尺寸；尺寸都是布局参数，屏幕位置由当前显示器决定。
@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    /// SwiftUI 唯一主窗口组的固定路由标识，入口与浮窗共用。
    static let mainWindowGroupID = "main"
    static let minimumSize = NSSize(width: 300, height: 480)
    static let compactBreakpoint: CGFloat = 760
    /// 项目默认紧凑窗口内容尺寸，冷启动和手动切换共用。
    static let compactContentSize = NSSize(width: 320, height: 720)
    // 项目外观参数：让原生窗口按钮避开侧栏圆角内框，间距与尺寸仍由系统决定。
    private static let windowButtonInset = NSSize(width: 20, height: 12)
    private weak var window: NSWindow?
    private var expandedFrame: NSRect?
    private var buttonLayoutTask: Task<Void, Never>?
    private var initialLayoutTask: Task<Void, Never>?
    private var initiallyCompact = false
    private var needsExpandedWindow = false
    private(set) var hasRestoredInitialLayout = false
    var hasExpandedContent: Bool {
        (window?.contentLayoutRect.width ?? 0) >= Self.compactBreakpoint
    }

    func attach(_ window: NSWindow?, initiallyCompact: Bool = false, needsExpandedWindow: Bool = false) {
        self.initiallyCompact = initiallyCompact
        self.needsExpandedWindow = needsExpandedWindow
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
        hasRestoredInitialLayout = false
        initialLayoutTask?.cancel()
        initialLayoutTask = Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.window === window, !Task.isCancelled else { return }
            // 在主窗完成附着后读取最新呈现意图，预览始终优先于紧凑恢复。
            if self.needsExpandedWindow {
                self.showExpanded(reduceMotion: true)
            } else if self.initiallyCompact {
                self.showCompact(reduceMotion: true)
            }
            self.hasRestoredInitialLayout = true
            self.initialLayoutTask = nil
            self.refreshWindowButtons()
        }
        refreshWindowButtons()
    }

    deinit {
        buttonLayoutTask?.cancel()
        initialLayoutTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// 只恢复自己附着的主窗口，返回 false 时由 SwiftUI 重开已关闭的窗口组。
    func presentAttachedWindow() -> Bool {
        guard let window, window.isVisible || window.isMiniaturized else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        return true
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

    @discardableResult
    func showCompact(reduceMotion: Bool) -> Bool {
        guard let window else { return false }
        // 全屏窗口由系统管理尺寸；退出全屏后用户即可切换。
        guard !window.styleMask.contains(.fullScreen) else { return false }
        finishInitialRestoration()
        if window.frame.width >= Self.compactBreakpoint {
            expandedFrame = window.frame
        }
        let content = NSRect(origin: .zero, size: Self.compactContentSize)
        var frame = window.frameRect(forContentRect: content)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(constrained(frame, for: window), display: true, animate: !reduceMotion)
        return true
    }

    func showExpanded(reduceMotion: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        finishInitialRestoration()
        let fallback = NSRect(x: window.frame.minX, y: window.frame.maxY - 780,
                              width: 1180, height: 780)
        window.setFrame(constrained(expandedFrame ?? fallback, for: window),
                        display: true, animate: !reduceMotion)
    }

    private func finishInitialRestoration() {
        initialLayoutTask?.cancel()
        initialLayoutTask = nil
        hasRestoredInitialLayout = true
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
    var initiallyCompact = false
    var needsExpandedWindow = false

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(controller: controller, initiallyCompact: initiallyCompact, needsExpandedWindow: needsExpandedWindow)
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {
        nsView.initiallyCompact = initiallyCompact
        nsView.needsExpandedWindow = needsExpandedWindow
        controller.attach(nsView.window, initiallyCompact: initiallyCompact, needsExpandedWindow: needsExpandedWindow)
    }

    final class WindowProbe: NSView {
        let controller: PlayerWindowController
        var initiallyCompact: Bool
        var needsExpandedWindow: Bool

        init(controller: PlayerWindowController, initiallyCompact: Bool, needsExpandedWindow: Bool) {
            self.controller = controller
            self.initiallyCompact = initiallyCompact
            self.needsExpandedWindow = needsExpandedWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.attach(window, initiallyCompact: initiallyCompact, needsExpandedWindow: needsExpandedWindow)
        }

        override func layout() {
            super.layout()
            controller.refreshWindowButtons()
        }
    }
}
