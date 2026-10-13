import AppKit
#if DEBUG
import OSLog
#endif

/// 光标统一在原生事件分发完成后选择；必要布局变化显式重建非 key 窗口的区域。
@MainActor
final class FloatingLyricsCursorCoordinator {
    private weak var window: NSWindow?
    private weak var drag: FloatingLyricsDragRegion.DragView?
    private weak var resize: FloatingLyricsResizeRegion.ResizeView?
    private struct CursorRequest {
        let cursor: NSCursor
        let eventType: NSEvent.EventType
        let active: Bool
        let ownsPointer: Bool
    }
    private var previousCursorRequest: CursorRequest?
    private var activationObservers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.previousCursorRequest = nil }
            })
        }
    }

    isolated deinit {
        for observer in activationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func finish(_ event: NSEvent) {
        #if DEBUG
        debugTrace("coordinator.finish", event: event)
        #endif
        guard handles(event) else { return }
        updatePointer(for: event)
        #if DEBUG
        debugTrace("coordinator.selected", event: event)
        #endif
    }

    func reset() {
        previousCursorRequest = nil
        #if DEBUG
        debugTrace("coordinator.reset")
        #endif
        resolveViews()
        drag?.reportHover(false)
    }

    func pointerExited() {
        guard let window, window.isVisible, !window.ignoresMouseEvents else { return }
        resolveViews()
        guard let drag, drag.isEnabled, !drag.isHiddenOrHasHiddenAncestor else { return }
        let point = NSEvent.mouseLocation
        // tracking 失效或重新登记也可能发退出；当前指针仍在本窗时不能清掉悬停。
        if ownsPointer(at: point, in: window),
           drag.bounds.contains(drag.convert(window.convertPoint(fromScreen: point), from: nil)) { return }
        reset()
    }

    func invalidateRegions() {
        previousCursorRequest = nil
        guard let window else { return }
        // invalidateCursorRects 在非 key 窗只标记失效；本窗不会成为 key，必须直接重建。
        window.resetCursorRects()
    }

    func toolbarExclusion(in view: NSView) -> NSRect {
        resolveViews()
        guard let drag, !drag.excludedRect.isEmpty else { return .zero }
        return view.convert(drag.excludedRect, from: drag)
    }

    private func handles(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.ignoresMouseEvents != true else { return false }
        switch event.type {
        case .mouseMoved, .mouseEntered, .cursorUpdate, .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return true
        default: return false
        }
    }

    private func updatePointer(for event: NSEvent) {
        guard let window, window.isVisible, !window.ignoresMouseEvents else { previousCursorRequest = nil; return }
        resolveViews()
        guard let drag, drag.isEnabled else { previousCursorRequest = nil; return }
        // hover 与光标共用一次当前物理采样；排队事件的位置只能用于拖动动作，不能恢复旧光标。
        let screenPoint = NSEvent.mouseLocation
        let point = drag.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let ownsCurrentPointer = ownsPointer(at: screenPoint, in: window)
        if !ownsCurrentPointer { previousCursorRequest = nil }
        drag.reportHover(ownsCurrentPointer && drag.bounds.contains(point))
        if let edge = resize?.activeEdge {
            setCursor(FloatingLyricsResizeCursor.cursor(for: edge), for: event, ownsPointer: ownsCurrentPointer)
            return
        }
        if drag.isDragging { setCursor(.closedHand, for: event, ownsPointer: ownsCurrentPointer); return }
        guard ownsCurrentPointer else { return }
        let inside = drag.bounds.contains(point)
        guard inside else { return }
        if drag.excludedRect.contains(point) { setCursor(.arrow, for: event, ownsPointer: true); return }
        if let resize, resize.isEnabled,
           let edge = FloatingLyricsResizeGeometry.handle(
               at: resize.convert(window.convertPoint(fromScreen: screenPoint), from: nil), in: resize.bounds
           ) {
            setCursor(FloatingLyricsResizeCursor.cursor(for: edge), for: event, ownsPointer: true)
        } else { setCursor(.openHand, for: event, ownsPointer: true) }
    }

    private func setCursor(_ cursor: NSCursor, for event: NSEvent, ownsPointer: Bool) {
        let request = CursorRequest(cursor: cursor, eventType: event.type,
                                    active: NSApplication.shared.isActive, ownsPointer: ownsPointer)
        defer { previousCursorRequest = request }
        // 只合并同一窗口连续移动中的相同请求；进入、cursorUpdate、激活状态变化后仍重新提交。
        // current 仅用于判断本 App 是否已选择该对象，不将它当作屏幕显示成功的证据。
        if event.type == .mouseMoved, let previous = previousCursorRequest,
           previous.eventType == .mouseMoved, previous.cursor === cursor, previous.active == request.active,
           previous.ownsPointer, ownsPointer, NSCursor.current === cursor { return }
        cursor.set()
    }

    private func ownsPointer(at point: NSPoint, in window: NSWindow) -> Bool {
        guard window.frame.contains(point) else { return false }
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        // 未锁定窗已有可命中的底色；必须实际命中本窗，不能凭窗口层级猜测透明区域归属。
        return hit == window.windowNumber
    }

    private func resolveViews() {
        guard let window else { return }
        if drag?.window !== window { drag = find(FloatingLyricsDragRegion.DragView.self, in: window.contentView) }
        if resize?.window !== window { resize = find(FloatingLyricsResizeRegion.ResizeView.self, in: window.contentView) }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    #if DEBUG
    /// 默认关闭，只写用户指定的诊断文件；字段不包含歌词、窗口标题、坐标或个人路径。
    func debugTrace(_ source: String, event: NSEvent? = nil, view: NSView? = nil, hoverValue: Bool? = nil) {
        guard FloatingLyricsCursorTrace.bootstrap(windowExists: window != nil), let window else { return }
        resolveViews()
        let screenPoint = event.map { window.convertPoint(toScreen: $0.locationInWindow) } ?? NSEvent.mouseLocation
        let actualPoint = NSEvent.mouseLocation
        let dragPoint = drag.map { $0.convert(window.convertPoint(fromScreen: screenPoint), from: nil) }
        let resizePoint = resize.map { $0.convert(window.convertPoint(fromScreen: screenPoint), from: nil) }
        let actualResizePoint = resize.map { $0.convert(window.convertPoint(fromScreen: actualPoint), from: nil) }
        let edge = resizePoint.flatMap { point in
            resize.flatMap { FloatingLyricsResizeGeometry.handle(at: point, in: $0.bounds) }
        }
        let actualEdge = actualResizePoint.flatMap { point in
            resize.flatMap { FloatingLyricsResizeGeometry.handle(at: point, in: $0.bounds) }
        }
        let owner = trackingOwner(for: event)
        var values: [String: Any] = [
            "source": source, "eventType": event?.type.rawValue ?? 0,
            "active": NSApplication.shared.isActive, "key": window.isKeyWindow,
            "cursorRectsEnabled": window.areCursorRectsEnabled, "visible": window.isVisible,
            "ignoresMouse": window.ignoresMouseEvents, "nonactivating": window.styleMask.contains(.nonactivatingPanel),
            "eventWindowMatches": event.map { $0.window === window } ?? false,
            "eventOwnsPointer": ownsPointer(at: screenPoint, in: window),
            "actualOwnsPointer": ownsPointer(at: actualPoint, in: window),
            "pointInWindow": window.frame.contains(screenPoint), "actualPointInWindow": window.frame.contains(actualPoint),
            "hasDragView": drag != nil, "hasResizeView": resize != nil,
            "dragEnabled": drag?.isEnabled ?? false, "resizeEnabled": resize?.isEnabled ?? false,
            "dragHidden": drag?.isHiddenOrHasHiddenAncestor ?? true,
            "resizeHidden": resize?.isHiddenOrHasHiddenAncestor ?? true,
            "dragHasAlwaysTracking": drag?.trackingAreas.contains { $0.options.contains(.activeAlways) } ?? false,
            "dragHasAppCursorTracking": drag?.trackingAreas.contains {
                $0.options.contains([.activeInActiveApp, .cursorUpdate])
            } ?? false,
            "resizeHasAppCursorTracking": resize?.trackingAreas.contains {
                $0.options.contains([.activeInActiveApp, .cursorUpdate])
            } ?? false,
            "dragVisibleRectEmpty": drag?.visibleRect.isEmpty ?? true,
            "resizeVisibleRectEmpty": resize?.visibleRect.isEmpty ?? true,
            "dragPointInBounds": dragPoint.map { drag?.bounds.contains($0) == true } ?? false,
            "dragPointInVisibleRect": dragPoint.map { drag?.visibleRect.contains($0) == true } ?? false,
            "resizePointInBounds": resizePoint.map { resize?.bounds.contains($0) == true } ?? false,
            "resizePointInVisibleRect": resizePoint.map { resize?.visibleRect.contains($0) == true } ?? false,
            "pointInToolbar": dragPoint.map { drag?.excludedRect.contains($0) == true } ?? false,
            "dragging": drag?.isDragging ?? false, "resizing": resize?.activeEdge != nil,
            "edge": edge.map { String(describing: $0) } ?? "none",
            "actualEdge": actualEdge.map { String(describing: $0) } ?? "none",
            "exitOwnerIsDrag": owner != nil && owner === drag, "exitOwnerIsResize": owner != nil && owner === resize,
            "cacheOpenHand": NSCursor.current === NSCursor.openHand,
            "cacheClosedHand": NSCursor.current === NSCursor.closedHand,
            "cacheArrow": NSCursor.current === NSCursor.arrow,
            "cacheMatchesEdge": edge.map { NSCursor.current === FloatingLyricsResizeCursor.cursor(for: $0) } ?? false,
            "cacheMatchesActualEdge": actualEdge.map { NSCursor.current === FloatingLyricsResizeCursor.cursor(for: $0) } ?? false
        ]
        if let view {
            values["callbackViewIsDrag"] = view === drag
            values["callbackViewIsResize"] = view === resize
            values["callbackViewHidden"] = view.isHiddenOrHasHiddenAncestor
            values["callbackViewVisibleRectEmpty"] = view.visibleRect.isEmpty
        }
        if let hoverValue { values["hoverValue"] = hoverValue }
        FloatingLyricsCursorTrace.write(values)
    }

    private func trackingOwner(for event: NSEvent?) -> NSView? {
        guard let event, event.type == .mouseEntered || event.type == .mouseExited else { return nil }
        return event.trackingArea?.owner as? NSView
    }
    #endif
}

#if DEBUG
@MainActor
private enum FloatingLyricsCursorTrace {
    private struct Configuration {
        let metadataEnabled: Bool?
        let metadataPath: String?
        let standardEnabled: Bool
        let suiteEnabled: Bool
        let standardPath: String?
        let suitePath: String?
        var isEnabled: Bool { metadataEnabled ?? (standardEnabled || suiteEnabled) }
        var path: String? {
            // 临时 Debug 构建产物的显式配置优先，不依赖 CLI 与 GUI 的偏好域是否一致。
            if metadataEnabled != nil { return metadataPath?.isEmpty == false ? metadataPath : nil }
            if standardEnabled, let standardPath, !standardPath.isEmpty { return standardPath }
            if suiteEnabled, let suitePath, !suitePath.isEmpty { return suitePath }
            return nil
        }
    }

    private static var configuration: Configuration {
        let standard = UserDefaults.standard
        let suite = Bundle.main.bundleIdentifier.flatMap { UserDefaults(suiteName: $0) }
        return Configuration(metadataEnabled: Bundle.main.object(forInfoDictionaryKey: "floatingLyricsCursorDebugEnabled") as? Bool,
                             metadataPath: Bundle.main.object(forInfoDictionaryKey: "floatingLyricsCursorDebugLogPath") as? String,
                             standardEnabled: standard.bool(forKey: "floatingLyrics.cursorDebugEnabled"),
                             suiteEnabled: suite?.bool(forKey: "floatingLyrics.cursorDebugEnabled") ?? false,
                             standardPath: standard.string(forKey: "floatingLyrics.cursorDebugLogPath"),
                             suitePath: suite?.string(forKey: "floatingLyrics.cursorDebugLogPath"))
    }

    private static var count = 0
    private static var previous: [String: String] = [:]
    private static var bootstrapped = false
    private static let logger = Logger(subsystem: "ShinApple.CursorDebug", category: "trace")
    // 鼠标事件很多，按回调来源合并连续同态记录，同时严格限制单次运行的文件体积。
    private static let recordLimit = 600

    static func bootstrap(windowExists: Bool) -> Bool {
        let config = configuration
        guard config.isEnabled else { return false }
        guard !bootstrapped else { return count < recordLimit }
        bootstrapped = true
        let exists = config.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let writable = config.path.map { FileManager.default.isWritableFile(atPath: $0) } ?? false
        let record = "{\"source\":\"bootstrap\",\"standardEnabled\":\(config.standardEnabled),"
            + "\"suiteEnabled\":\(config.suiteEnabled),\"standardPathPresent\":\(config.standardPath?.isEmpty == false),"
            + "\"metadataPresent\":\(config.metadataEnabled != nil),\"metadataEnabled\":\(config.metadataEnabled == true),"
            + "\"metadataPathPresent\":\(config.metadataPath?.isEmpty == false),"
            + "\"suitePathPresent\":\(config.suitePath?.isEmpty == false),\"pathExists\":\(exists),"
            + "\"pathWritable\":\(writable),\"weakWindowExists\":\(windowExists)}"
        // 文件入口失效时也留下固定、无用户内容的系统日志，以区分读取配置和文件写入故障。
        logger.notice("\(record, privacy: .public)")
        _ = append(Data(record.utf8) + Data([0x0A]), configuration: config)
        return count < recordLimit
    }

    static func write(_ values: [String: Any]) {
        let config = configuration
        guard config.isEnabled, count < recordLimit, let source = values["source"] as? String else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            guard let signature = String(data: data, encoding: .utf8), previous[source] != signature else { return }
            if append(data + Data([0x0A]), configuration: config) { previous[source] = signature }
        } catch { reportFailure(stage: "serialization", code: (error as NSError).code) }
    }

    private static func append(_ data: Data, configuration config: Configuration) -> Bool {
        guard let path = config.path else { reportFailure(stage: "pathMissing", code: 0); return false }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                reportFailure(stage: "create", code: 0)
                return false
            }
        }
        var stage = "open"
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            stage = "seek"
            try handle.seekToEnd()
            stage = "write"
            try handle.write(contentsOf: data)
            count += 1
            return true
        } catch {
            reportFailure(stage: stage, code: (error as NSError).code)
            return false
        }
    }

    private static func reportFailure(stage: String, code: Int) {
        logger.error("stage=\(stage, privacy: .public) code=\(code, privacy: .public)")
        count = recordLimit
    }
}
#endif
