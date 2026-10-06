import AppKit

/// macOS 14 没有 SwiftUI 滚动阶段 API；本地事件只观察，不消费。
/// 同时观察滚轮、惯性、滚动条拖动与文字选择，按住鼠标时不启动回归计时。
@MainActor
final class ScrollWheelCatcher {
    var onInteraction: (() -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    private weak var view: NSView?
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
    private var isDragging = false

    func install(in view: NSView) {
        remove()
        self.view = view
        guard let window = view.window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishDrag() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        view = nil
        finishDrag()
    }

    private func finishDrag() {
        guard isDragging else { return }
        isDragging = false
        onDragStateChange?(false)
    }

    private func handle(_ event: NSEvent) {
        // 鼠标在窗口外松开、或窗口已失焦，也必须结束先前的拖动。
        if event.type == .leftMouseUp, isDragging {
            finishDrag()
            return
        }
        guard let view, let window = view.window, event.window === window, window.isKeyWindow else { return }
        let inside = NSMouseInRect(event.locationInWindow, view.convert(view.bounds, to: nil), false)
        switch event.type {
        case .leftMouseDown where inside:
            isDragging = true
            onDragStateChange?(true)
        case .leftMouseDragged where isDragging:
            onInteraction?()
        case .scrollWheel where inside:
            onInteraction?()
        case .keyDown:
            // 键盘只在歌词内容拥有焦点时暂停，输入框与其他面板不受影响。
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
                onInteraction?()
            }
        default:
            break
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
