import AppKit
import SwiftUI

/// 原生菜单保留键盘与辅助功能操作，按钮在悬停、按下和菜单展开时独立绘制反馈。
@MainActor
struct PlaybackMenu: NSViewRepresentable {
    @MainActor
    struct Item {
        let title: String
        var symbol: String?
        var isEnabled = true
        var isChecked = false
        var action: (() -> Void)?
        var isSeparator = false

        static let separator = Item(title: "", isSeparator: true)
    }

    let items: [Item]
    var symbol = "ellipsis.circle"
    var iconSize = PlaybackControlSizing.iconSize
    var width = PlaybackControlSizing.optionSide
    var height = PlaybackControlSizing.optionSide
    let accessibilityLabel: String
    let help: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton()
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.title = ""
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.setAccessibilityRole(.popUpButton)
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        button.symbolName = symbol
        button.iconSize = iconSize
        button.controlSizeHint = NSSize(width: width, height: height)
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = help
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuButton, context: Context) -> CGSize? {
        CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: PlaybackMenu
        private weak var button: MenuButton?
        private var actions: [Int: () -> Void] = [:]

        init(_ parent: PlaybackMenu) { self.parent = parent }

        @objc func openMenu(_ sender: MenuButton) {
            guard sender.isEnabled else { return }
            button = sender
            actions = [:]
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            for (index, item) in parent.items.enumerated() {
                if item.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let native = NSMenuItem(title: item.title, action: #selector(performAction(_:)), keyEquivalent: "")
                native.target = self
                native.tag = index
                native.isEnabled = item.isEnabled && item.action != nil
                native.state = item.isChecked ? .on : .off
                if let symbol = item.symbol {
                    native.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                actions[index] = item.action
                menu.addItem(native)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
            sender.isMenuOpen = false
        }

        @objc func performAction(_ sender: NSMenuItem) { actions[sender.tag]?() }
        func menuWillOpen(_ menu: NSMenu) { button?.isMenuOpen = true }
        func menuDidClose(_ menu: NSMenu) { button?.isMenuOpen = false }
    }

    final class MenuButton: NSButton {
        var symbolName = "ellipsis.circle"
        var iconSize: CGFloat = PlaybackControlSizing.iconSize
        var controlSizeHint = NSSize(width: PlaybackControlSizing.optionSide, height: PlaybackControlSizing.optionSide) {
            didSet { invalidateIntrinsicContentSize() }
        }
        var isMenuOpen = false {
            didSet {
                if !isMenuOpen, let window {
                    isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
                }
                needsDisplay = true
            }
        }
        private var isHovered = false
        private var hoverArea: NSTrackingArea?
        override var intrinsicContentSize: NSSize { controlSizeHint }

        override func updateTrackingAreas() {
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            hoverArea = area
            addTrackingArea(area)
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
        override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            let active = isMenuOpen || isHighlighted
            let accent = NSColor(Color.appleMusicPink)
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            if isEnabled && (active || isHovered) {
                let color = active ? accent.withAlphaComponent(0.20) : NSColor.labelColor.withAlphaComponent(0.09)
                color.setFill()
                shape.fill()
            }
            let foreground = !isEnabled ? NSColor.disabledControlTextColor : active ? accent : .secondaryLabelColor
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [foreground]))
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = image.size
                image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                     width: size.width, height: size.height))
            }
            if window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                shape.lineWidth = 2
                shape.stroke()
            }
        }
    }
}
