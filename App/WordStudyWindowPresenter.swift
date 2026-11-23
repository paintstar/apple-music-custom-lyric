import AppKit
import SwiftUI

/// 在歌词选区附近呈现原生可缩放窗口，窗口和设置页共享同一份内容尺寸偏好。
struct WordStudyWindowPresenter: View {
    let studyModel: LyricsStudyModel
    let state: WordPopoverState?
    let anchorRect: CGRect
    @AppStorage(WordStudyWindowSettings.preferenceKey)
    private var storedSize = WordStudyWindowSettings.defaultPreferenceValue

    var body: some View {
        Anchor(studyModel: studyModel, state: state, anchorRect: anchorRect,
               preferredSize: WordStudyWindowSettings.size(from: storedSize), storedSize: $storedSize)
    }

    private struct Anchor: NSViewRepresentable {
        let studyModel: LyricsStudyModel
        let state: WordPopoverState?
        let anchorRect: CGRect
        let preferredSize: CGSize
        let storedSize: Binding<String>

        func makeNSView(context: Context) -> AnchorView { AnchorView() }

        func updateNSView(_ view: AnchorView, context: Context) {
            let presentation = state.map {
                Presentation(studyModel: studyModel, state: $0, anchorRect: anchorRect,
                             preferredSize: preferredSize, storedSize: storedSize)
            }
            view.update(presentation)
        }

        static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
            view.detach()
        }
    }

    private struct Presentation {
        let studyModel: LyricsStudyModel
        let state: WordPopoverState
        let anchorRect: CGRect
        var preferredSize: CGSize
        let storedSize: Binding<String>
    }

    private struct LiveResize {
        let actualSize: CGSize
        let preferredSize: CGSize
    }

    private final class AnchorView: NSView, NSWindowDelegate {
        private static let screenInset: CGFloat = 10
        private static let anchorGap: CGFloat = 8
        private var presentation: Presentation?
        private var updateTask: Task<Void, Never>?
        private weak var observedWindow: NSWindow?
        private var panel: WordStudyPanel?
        private var appliedSize: CGSize?
        private var appliedVisibleFrame: CGRect?
        private var liveResize: LiveResize?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe(window)
            scheduleUpdate()
        }

        override func layout() {
            super.layout()
            if presentation != nil, panel == nil { scheduleUpdate() }
        }

        func update(_ presentation: Presentation?) {
            self.presentation = presentation
            scheduleUpdate()
        }

        func detach() {
            updateTask?.cancel()
            updateTask = nil
            presentation = nil
            observe(nil)
            detachPanel()?.close()
        }

        private func observe(_ owner: NSWindow?) {
            guard observedWindow !== owner else { return }
            let center = NotificationCenter.default
            center.removeObserver(self)
            detachPanel()?.close()
            observedWindow = owner
            guard let owner else { return }
            center.addObserver(self, selector: #selector(ownerWillClose),
                               name: NSWindow.willCloseNotification, object: owner)
            center.addObserver(self, selector: #selector(screenParametersChanged),
                               name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        }

        private func scheduleUpdate() {
            guard updateTask == nil else { return }
            // 等 SwiftUI 布局结束再取得视口坐标和改变原生窗口焦点。
            updateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.updateTask = nil
                self.applyPresentation()
            }
        }

        private func applyPresentation() {
            guard let presentation, let owner = observedWindow,
                  presentation.studyModel.wordPopover?.id == presentation.state.id else {
                detachPanel()?.close()
                return
            }
            if let panel, panel.wordID == presentation.state.id {
                applySize(presentation.preferredSize, to: panel, on: panel.screen ?? owner.screen)
                return
            }

            // 同一模型可被多个主窗口观察，实际发起操作的窗口负责呈现。
            let ownsSelection = canPresent(in: owner)
            detachPanel()?.close()
            guard ownsSelection, !bounds.isEmpty, !hasOpenPanel(for: presentation) else { return }
            let anchorInWindow = convert(presentation.anchorRect.offsetBy(dx: bounds.minX, dy: bounds.minY), to: nil)
            let anchor = owner.convertToScreen(anchorInWindow)
            let anchorCenter = CGPoint(x: anchor.midX, y: anchor.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(anchorCenter) } ?? owner.screen
            showPanel(for: presentation, size: presentation.preferredSize, anchor: anchor, screen: screen, owner: owner)
        }

        private func canPresent(in owner: NSWindow) -> Bool {
            guard owner.isVisible, !owner.isMiniaturized else { return false }
            if owner.isKeyWindow || panel?.isKeyWindow == true { return true }
            if NSApp.keyWindow?.isVisible == true { return false }
            // 刚关掉辅助窗时，AppKit 可能尚未为可见宿主恢复键盘焦点。
            if let main = NSApp.mainWindow, main.isVisible { return main === owner }
            return true
        }

        private func showPanel(for presentation: Presentation, size: CGSize, anchor: CGRect, screen: NSScreen?, owner: NSWindow) {
            let panel = WordStudyPanel(size: size, modelID: ObjectIdentifier(presentation.studyModel),
                                       wordID: presentation.state.id)
            panel.title = "划词释义"
            panel.appearance = owner.appearance
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: WordStudyPopoverView(studyModel: presentation.studyModel,
                                                                   initialState: presentation.state))
            // 视图按窗口大小滚动，AppKit 统一管理窗口的最小和最大尺寸。
            host.sizingOptions = []
            panel.contentView = host
            panel.delegate = self
            self.panel = panel
            applySize(size, to: panel, on: screen, anchor: anchor)
            owner.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
        }

        private func hasOpenPanel(for presentation: Presentation) -> Bool {
            let modelID = ObjectIdentifier(presentation.studyModel)
            return NSApp.windows.contains { window in
                guard let panel = window as? WordStudyPanel else { return false }
                return panel.parent != nil && panel.modelID == modelID && panel.wordID == presentation.state.id
            }
        }

        private func applySize(_ size: CGSize, to panel: NSPanel, on screen: NSScreen?, anchor: CGRect? = nil) {
            guard liveResize == nil, !panel.inLiveResize else { return }
            let visibleFrame = screen.map { screen in
                let insetFrame = screen.visibleFrame.insetBy(dx: Self.screenInset, dy: Self.screenInset)
                return insetFrame.isEmpty ? screen.visibleFrame : insetFrame
            }
            guard anchor != nil || appliedSize != size || appliedVisibleFrame != visibleFrame else { return }
            appliedSize = size
            appliedVisibleFrame = visibleFrame

            let maximumSize = WordStudyWindowSettings.maximumSize
            let available = visibleFrame.map { panel.contentRect(forFrameRect: $0).size } ?? maximumSize
            let maximum = CGSize(width: max(1, min(maximumSize.width, available.width)),
                                 height: max(1, min(maximumSize.height, available.height)))
            let minimumSize = WordStudyWindowSettings.minimumSize
            panel.contentMinSize = CGSize(width: min(minimumSize.width, maximum.width),
                                          height: min(minimumSize.height, maximum.height))
            panel.contentMaxSize = maximum
            let targetSize = CGSize(width: min(size.width, maximum.width), height: min(size.height, maximum.height))
            var frame = panel.frameRect(forContentRect: CGRect(origin: .zero, size: targetSize))
            frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
            if let anchor {
                frame.origin = anchoredOrigin(for: frame.size, at: anchor, in: visibleFrame)
            }
            if let visibleFrame {
                frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
            }
            if frame != panel.frame { panel.setFrame(frame, display: true) }
        }

        private func anchoredOrigin(for size: CGSize, at anchor: CGRect, in visibleFrame: CGRect?) -> CGPoint {
            let below = anchor.minY - Self.anchorGap - size.height
            let above = anchor.maxY + Self.anchorGap
            let fitsAbove = visibleFrame.map { above + size.height <= $0.maxY } ?? false
            let fitsBelow = visibleFrame.map { below >= $0.minY } ?? true
            return CGPoint(x: anchor.midX - size.width / 2, y: fitsAbove && !fitsBelow ? above : below)
        }

        func windowWillStartLiveResize(_ notification: Notification) {
            guard let panel, notification.object as? NSWindow === panel, let presentation,
                  presentation.state.id == panel.wordID else { return }
            liveResize = LiveResize(actualSize: panel.contentRect(forFrameRect: panel.frame).size,
                                    preferredSize: WordStudyWindowSettings.size(from: presentation.storedSize.wrappedValue))
        }

        func windowDidEndLiveResize(_ notification: Notification) {
            guard let panel, notification.object as? NSWindow === panel, let liveResize else { return }
            self.liveResize = nil
            defer { scheduleUpdate() }
            guard let presentation, presentation.state.id == panel.wordID,
                  presentation.studyModel.wordPopover?.id == panel.wordID else { return }

            let previous = WordStudyWindowSettings.size(from: presentation.storedSize.wrappedValue)
            let actual = panel.contentRect(forFrameRect: panel.frame).size
            var preferred = previous
            // 单轴拖拽不把另一轴的屏幕临时限幅写回设置。拖拽期间有新设置时，该轴采用最新值。
            if previous.width == liveResize.preferredSize.width, actual.width != liveResize.actualSize.width {
                preferred.width = actual.width
            }
            if previous.height == liveResize.preferredSize.height, actual.height != liveResize.actualSize.height {
                preferred.height = actual.height
            }
            if preferred != previous {
                let value = WordStudyWindowSettings.preferenceValue(for: preferred)
                self.presentation?.preferredSize = WordStudyWindowSettings.size(from: value)
                presentation.storedSize.wrappedValue = value
            }
        }

        func windowDidChangeScreen(_ notification: Notification) { scheduleUpdate() }

        func windowWillClose(_ notification: Notification) {
            guard let panel, notification.object as? NSWindow === panel else { return }
            dismissCurrentWord()
            _ = detachPanel()
        }

        @objc private func ownerWillClose() {
            dismissCurrentWord()
            detach()
        }

        @objc private func screenParametersChanged() { scheduleUpdate() }

        private func dismissCurrentWord() {
            guard let panel, let model = presentation?.studyModel,
                  model.wordPopover?.id == panel.wordID else { return }
            model.dismissWordPopover()
        }

        private func detachPanel() -> NSWindow? {
            guard let panel else { return nil }
            self.panel = nil
            appliedSize = nil
            appliedVisibleFrame = nil
            liveResize = nil
            panel.delegate = nil
            panel.parent?.removeChildWindow(panel)
            return panel
        }
    }
}

private final class WordStudyPanel: NSPanel {
    let modelID: ObjectIdentifier
    let wordID: UUID

    init(size: CGSize, modelID: ObjectIdentifier, wordID: UUID) {
        self.modelID = modelID
        self.wordID = wordID
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
