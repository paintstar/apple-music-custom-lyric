import AppKit
import SwiftUI

/// 仅记录资料库原生滚动位置；系统滚动条/辅助功能移动不会可靠回写 SwiftUI 的行 ID。
struct LibraryScrollPositionRecorder: NSViewRepresentable {
    let browser: MusicLibraryBrowserModel

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.configure(browser) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    @MainActor
    final class Probe: NSView {
        private weak var browser: MusicLibraryBrowserModel?
        private weak var scroll: NSScrollView?
        private var resetSequence: Int?
        private var pendingOffset: CGFloat?
        private var isRestoring = false
        private var scheduled = false

        func configure(_ browser: MusicLibraryBrowserModel) {
            self.browser = browser
            if resetSequence != browser.scrollResetSequence {
                resetSequence = browser.scrollResetSequence
                pendingOffset = CGFloat(browser.scrollOffsetY)
            }
            attachIfNeeded()
            scheduleRestore()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attachIfNeeded(); scheduleRestore() }
        }

        override func layout() {
            super.layout()
            attachIfNeeded()
            scheduleRestore()
        }

        private func attachIfNeeded() {
            guard let found = enclosingScrollView, found !== scroll else { return }
            stopObserving()
            scroll = found
            pendingOffset = CGFloat(browser?.scrollOffsetY ?? 0)
            found.contentView.postsBoundsChangedNotifications = true
            found.documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                  name: NSView.boundsDidChangeNotification, object: found.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(documentChanged),
                                                  name: NSView.frameDidChangeNotification, object: found.documentView)
        }

        @objc private func boundsChanged() {
            guard !isRestoring, pendingOffset == nil, window != nil, let scroll else { return }
            browser?.scrollOffsetY = Double(max(0, scroll.contentView.bounds.minY))
        }

        @objc private func documentChanged() { scheduleRestore() }

        private func scheduleRestore() {
            guard pendingOffset != nil, !scheduled, scroll != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.restoreWhenLaidOut()
            }
        }

        private func restoreWhenLaidOut() {
            guard let target = pendingOffset, let scroll, let document = scroll.documentView,
                  scroll.contentView.bounds.height > 0, document.frame.height > 0 else { return }
            let maximum = max(0, document.frame.height - scroll.contentView.bounds.height)
            // 等待惰性列表的首次完整高度，避免以尚未布局的零高度覆盖保存值。
            guard target == 0 || maximum > 0 else { return }
            let restored = min(max(target, 0), maximum)
            isRestoring = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: restored))
            scroll.reflectScrolledClipView(scroll.contentView)
            isRestoring = false
            pendingOffset = nil
            browser?.scrollOffsetY = Double(restored)
        }

        private func stopObserving() {
            guard let scroll else { return }
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: scroll.documentView)
        }

        func detach() {
            stopObserving()
            scroll = nil
            pendingOffset = nil
            scheduled = false
        }
    }
}
