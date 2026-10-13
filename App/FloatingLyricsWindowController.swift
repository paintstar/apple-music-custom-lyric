import AppKit
import SwiftUI

/// App 只持有一个悬浮窗；歌词来源仍是共享 AppModel，不创建播放或同步任务。
@MainActor
final class FloatingLyricsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let framePreferenceKey = "floatingLyrics.windowFrame"
    @Published private(set) var isPresented = false
    @Published private(set) var isLocked = false
    private(set) var window: NSPanel?
    private(set) var unlockWindow: NSPanel?
    var presentMainWindow: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let visibleFrames: @MainActor () -> [NSRect]
    private let mouseLocation: @MainActor () -> NSPoint
    private let monotonicTime: @MainActor () -> TimeInterval
    private var isAdjustingGeometry = false
    private weak var hostedModel: AppModel?
    private var hoverTimer: Timer?
    private var unlockHover = FloatingLyricsUnlockHover()
    // 锁态无鼠标事件；读取公开鼠标位置只为检测悬浮，无需辅助功能授权。
    private static let hoverSampleInterval: TimeInterval = 0.1
    private static let unlockButtonSide: CGFloat = 32
    private static let unlockButtonInset: CGFloat = 8
    // 完全透明像素会被 WindowServer 的 mouseDown 命中跳过；1% 黑色保持外观并让整窗可交互。
    private static let interactiveBackgroundOpacity: CGFloat = 0.01

    init(defaults: UserDefaults = .standard,
         visibleFrames: @escaping @MainActor () -> [NSRect] = { FloatingLyricsWindowController.currentVisibleFrames() },
         mouseLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
         monotonicTime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.visibleFrames = visibleFrames
        self.mouseLocation = mouseLocation
        self.monotonicTime = monotonicTime
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        hoverTimer?.invalidate()
        if let unlockWindow { window?.removeChildWindow(unlockWindow) }
        unlockWindow?.orderOut(nil)
        unlockWindow?.contentView = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
    }

    func toggle(model: AppModel) {
        if isPresented { close() } else { show(model: model) }
    }

    func show(model: AppModel) {
        let panel = window ?? makeWindow()
        (panel as? FloatingLyricsPanel)?.resetFloatingCursorTracking()
        hostedModel = model
        updateHostedView()
        updateWindowGeometry()
        updateInteractionBackground(panel)
        isPresented = true
        // 保持其它 App 的键盘焦点；悬浮窗只调整可见顺序。
        panel.orderFrontRegardless()
        #if DEBUG
        (panel as? FloatingLyricsPanel)?.traceFloatingCursor("window.shown")
        #endif
    }

    func close() {
        (window as? FloatingLyricsPanel)?.resetFloatingCursorTracking()
        stopLockedHover()
        isLocked = false
        hostedModel = nil
        guard let window else { isPresented = false; return }
        window.ignoresMouseEvents = false
        window.isMovable = true
        window.isMovableByWindowBackground = true
        updateInteractionBackground(window)
        saveFrame(window.frame)
        window.orderOut(nil)
        window.contentView = nil
        isPresented = false
    }

    func toggleLock() { setLocked(!isLocked) }

    func setLocked(_ locked: Bool) {
        guard isPresented, let window, isLocked != locked else { return }
        isLocked = locked
        if locked { (window as? FloatingLyricsPanel)?.resetFloatingCursorTracking() }
        window.ignoresMouseEvents = locked
        window.isMovable = !locked
        window.isMovableByWindowBackground = !locked
        updateInteractionBackground(window)
        updateHostedView()
        if locked { startLockedHover() } else { stopLockedHover() }
    }

    private func updateInteractionBackground(_ window: NSWindow) {
        window.backgroundColor = isLocked ? .clear : .black.withAlphaComponent(Self.interactiveBackgroundOpacity)
    }

    private func startLockedHover() {
        stopLockedHover()
        sampleLockedHover()
        let timer = Timer(timeInterval: Self.hoverSampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLockedHover() }
        }
        timer.tolerance = Self.hoverSampleInterval / 4
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLockedHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        unlockHover.reset()
        if let unlockWindow { window?.removeChildWindow(unlockWindow) }
        unlockWindow?.orderOut(nil)
        unlockWindow?.contentView = nil
        unlockWindow = nil
    }

    private func sampleLockedHover() {
        guard isPresented, isLocked, let window, window.isVisible else { stopLockedHover(); return }
        let shouldShow = unlockHover.shouldShow(isInside: window.frame.contains(mouseLocation()),
                                                time: monotonicTime(),
                                                delay: FloatingLyricsUnlockSettings.delay(in: defaults))
        if shouldShow {
            let button = unlockWindow ?? makeUnlockWindow()
            positionUnlockWindow(button)
            if !button.isVisible { button.orderFrontRegardless() }
        } else {
            unlockWindow?.orderOut(nil)
        }
    }

    /// 只有小锁标志接收点击，整块歌词依然穿透鼠标，窗口也不能移动或缩放。
    private func makeUnlockWindow() -> NSPanel {
        let frame = NSRect(origin: .zero, size: NSSize(width: Self.unlockButtonSide, height: Self.unlockButtonSide))
        let panel = FloatingLyricsPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        configurePanel(panel)
        panel.title = "解锁悬浮歌词"
        panel.isMovable = false
        panel.contentView = FloatingLyricsHostingView(rootView: FloatingLyricsUnlockButton { [weak self] in
            self?.setLocked(false)
        })
        window?.addChildWindow(panel, ordered: .above)
        unlockWindow = panel
        return panel
    }

    private func positionUnlockWindow(_ panel: NSPanel) {
        guard let window else { return }
        let side = Self.unlockButtonSide
        let frame = NSRect(x: window.frame.maxX - side - Self.unlockButtonInset,
                           y: window.frame.maxY - side - Self.unlockButtonInset, width: side, height: side)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func updateHostedView() {
        guard let model = hostedModel, let window else { return }
        let root = AnyView(FloatingLyricsView(model: model, isLocked: isLocked,
                                             onLock: { [weak self] in self?.toggleLock() },
                                             onClose: { [weak self] in self?.close() },
                                             onPresentMainWindow: { [weak self] in self?.presentMainWindow?() })
            .defaultAppStorage(defaults))
        if let host = window.contentView as? FloatingLyricsHostingView<AnyView> {
            host.rootView = root
        } else {
            window.contentView = FloatingLyricsHostingView(rootView: root)
        }
    }

    func windowWillClose(_ notification: Notification) { close() }
    func windowDidMove(_ notification: Notification) { updateWindowGeometry() }
    func windowDidResize(_ notification: Notification) { updateWindowGeometry() }

    private func makeWindow() -> NSPanel {
        let frames = visibleFrames()
        let restored = defaults.string(forKey: Self.framePreferenceKey).map(NSRectFromString)
        let frame = restored.map { FloatingLyricsWindowGeometry.constrained($0, visibleFrames: frames) }
            ?? FloatingLyricsWindowGeometry.initialFrame(visibleFrames: frames)
        let panel = FloatingLyricsPanel(contentRect: frame,
                                       styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                       backing: .buffered, defer: false)
        configurePanel(panel)
        panel.title = "悬浮歌词"
        panel.delegate = self
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        window = panel
        return panel
    }

    private func configurePanel(_ panel: NSPanel) {
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenNone, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
    }

    private func updateWindowGeometry() {
        guard let window, !isAdjustingGeometry else { return }
        isAdjustingGeometry = true
        defer { isAdjustingGeometry = false }
        let frames = visibleFrames()
        let frame = FloatingLyricsWindowGeometry.constrained(window.frame, visibleFrames: frames)
        if let screen = FloatingLyricsWindowGeometry.visibleFrame(for: frame, visibleFrames: frames) {
            window.contentMinSize = NSSize(width: min(FloatingLyricsWindowGeometry.minimumSize.width, screen.width),
                                          height: min(FloatingLyricsWindowGeometry.minimumSize.height, screen.height))
            window.contentMaxSize = screen.size
        } else {
            window.contentMinSize = FloatingLyricsWindowGeometry.minimumSize
        }
        if window.frame != frame { window.setFrame(frame, display: isPresented) }
        if let unlockWindow { positionUnlockWindow(unlockWindow) }
        saveFrame(frame)
    }

    private func saveFrame(_ frame: NSRect) {
        let stored = NSStringFromRect(frame)
        if defaults.string(forKey: Self.framePreferenceKey) != stored {
            defaults.set(stored, forKey: Self.framePreferenceKey)
        }
    }

    @objc private func screensChanged(_ notification: Notification) { updateWindowGeometry() }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        close()
        window?.delegate = nil
        window = nil
    }

    private static func currentVisibleFrames() -> [NSRect] {
        let main = NSScreen.main?.visibleFrame
        let remaining = NSScreen.screens.map(\.visibleFrame).filter { $0 != main }
        return main.map { [$0] + remaining } ?? remaining
    }
}

/// 字幕窗不成为主窗或键盘目标，按钮与拖动仍接收首次点击。
final class FloatingLyricsPanel: NSPanel {
    private lazy var cursorCoordinator = FloatingLyricsCursorCoordinator(window: self)
    private var eventDispatchDepth = 0
    private var isResettingCursorRects = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func toggleFullScreen(_ sender: Any?) {}

    override func sendEvent(_ event: NSEvent) {
        eventDispatchDepth += 1
        defer { eventDispatchDepth -= 1 }
        #if DEBUG
        traceFloatingCursor("panel.before", event: event)
        #endif
        super.sendEvent(event)
        #if DEBUG
        traceFloatingCursor("panel.afterAppKit", event: event)
        #endif
        if !isResettingCursorRects { cursorCoordinator.finish(event) }
    }

    override func resetCursorRects() {
        guard !isResettingCursorRects else { return }
        isResettingCursorRects = true
        defer { isResettingCursorRects = false }
        super.resetCursorRects()
    }

    func refreshFloatingCursor() { cursorCoordinator.invalidateRegions() }
    func resetFloatingCursorTracking() { cursorCoordinator.reset() }
    func receiveWindowExit() {
        guard !isResettingCursorRects else { return }
        cursorCoordinator.pointerExited()
    }
    func floatingToolbarExclusion(in view: NSView) -> NSRect { cursorCoordinator.toolbarExclusion(in: view) }

    func receiveTrackingEvent(_ event: NSEvent) {
        // sendEvent 内的 owner 回调由分发完成后统一处理；直接送达 owner 的 tracking 仍可处理。
        guard eventDispatchDepth == 0, !isResettingCursorRects else { return }
        cursorCoordinator.finish(event)
    }

    #if DEBUG
    func traceFloatingCursor(_ source: String, event: NSEvent? = nil, view: NSView? = nil, hoverValue: Bool? = nil) {
        cursorCoordinator.debugTrace(source, event: event, view: view, hoverValue: hoverValue)
    }
    #endif
}

private struct FloatingLyricsUnlockButton: View {
    let onUnlock: () -> Void

    var body: some View {
        Button(action: onUnlock) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.25), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("解锁悬浮歌词")
        .help("解锁悬浮歌词")
    }
}

private final class FloatingLyricsHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 集中的外观尺寸：600 点容纳双语长句，顶部留给拖动与关闭；小屏幕按可见区缩小。
enum FloatingLyricsWindowGeometry {
    static let defaultSize = NSSize(width: 600, height: 180)
    static let minimumSize = NSSize(width: 300, height: 120)
    private static let bottomMargin: CGFloat = 48

    static func initialFrame(visibleFrames: [NSRect]) -> NSRect {
        guard let screen = visibleFrames.first(where: isUsable) else { return NSRect(origin: .zero, size: defaultSize) }
        let frame = NSRect(x: screen.midX - defaultSize.width / 2, y: screen.minY + bottomMargin,
                           width: defaultSize.width, height: defaultSize.height)
        return constrained(frame, visibleFrames: [screen])
    }

    static func constrained(_ proposed: NSRect, visibleFrames: [NSRect]) -> NSRect {
        let frame = isUsable(proposed) ? proposed : NSRect(origin: .zero, size: defaultSize)
        guard let screen = visibleFrame(for: frame, visibleFrames: visibleFrames) else { return frame }
        let width = min(max(frame.width, minimumSize.width), screen.width)
        let height = min(max(frame.height, minimumSize.height), screen.height)
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }

    static func visibleFrame(for proposed: NSRect, visibleFrames: [NSRect]) -> NSRect? {
        let screens = visibleFrames.filter(isUsable)
        let intersecting = screens.filter {
            let overlap = $0.intersection(proposed)
            return !overlap.isEmpty
        }
        if !intersecting.isEmpty {
            return intersecting.max {
                let lhs = $0.intersection(proposed)
                let rhs = $1.intersection(proposed)
                return lhs.width * lhs.height < rhs.width * rhs.height
            }
        }
        // 记忆位置所在显示器已拔除时，选择最近的当前屏幕，再把完整窗口放回可见区。
        return screens.min {
            hypot($0.midX - proposed.midX, $0.midY - proposed.midY)
                < hypot($1.midX - proposed.midX, $1.midY - proposed.midY)
        }
    }

    private static func isUsable(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
