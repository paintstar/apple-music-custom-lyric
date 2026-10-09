import AppKit
import SwiftUI

/// App 只持有一个悬浮窗；歌词来源仍是共享 AppModel，不创建播放或同步任务。
@MainActor
final class FloatingLyricsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let framePreferenceKey = "floatingLyrics.windowFrame"
    @Published private(set) var isPresented = false
    @Published private(set) var isLocked = false
    private(set) var window: NSPanel?

    private let defaults: UserDefaults
    private let visibleFrames: @MainActor () -> [NSRect]
    private var isAdjustingGeometry = false
    private weak var hostedModel: AppModel?

    init(defaults: UserDefaults = .standard,
         visibleFrames: @escaping @MainActor () -> [NSRect] = { FloatingLyricsWindowController.currentVisibleFrames() }) {
        self.defaults = defaults
        self.visibleFrames = visibleFrames
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
    }

    func toggle(model: AppModel) {
        if isPresented { close() } else { show(model: model) }
    }

    func show(model: AppModel) {
        let panel = window ?? makeWindow()
        hostedModel = model
        updateHostedView()
        updateWindowGeometry()
        isPresented = true
        // 保持其它 App 的键盘焦点；悬浮窗只调整可见顺序。
        panel.orderFrontRegardless()
    }

    func close() {
        isLocked = false
        hostedModel = nil
        guard let window else { isPresented = false; return }
        window.ignoresMouseEvents = false
        window.isMovable = true
        window.isMovableByWindowBackground = true
        saveFrame(window.frame)
        window.orderOut(nil)
        window.contentView = nil
        isPresented = false
    }

    func toggleLock() { setLocked(!isLocked) }

    func setLocked(_ locked: Bool) {
        guard isPresented, let window, isLocked != locked else { return }
        isLocked = locked
        window.ignoresMouseEvents = locked
        window.isMovable = !locked
        window.isMovableByWindowBackground = !locked
        updateHostedView()
    }

    private func updateHostedView() {
        guard let model = hostedModel, let window else { return }
        let root = AnyView(FloatingLyricsView(model: model, isLocked: isLocked,
                                             onLock: { [weak self] in self?.toggleLock() },
                                             onClose: { [weak self] in self?.close() })
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
        panel.title = "悬浮歌词"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        window = panel
        return panel
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
private final class FloatingLyricsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
