import AppKit

/// 歌词文本视图的右键学习菜单扩展：不调用系统默认菜单以避免右键自动选中单词，仅在已有拖选选区时提供划词与拷贝入口。
@MainActor
extension LyricsInteractiveTextView {

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu = menu(for: event), !contextMenu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let contextMenu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)

        let hasSelection = selectedRange().length > 0
        let wordSelection = hasSelection ? resolveContextMenuWord?() : nil
        let lineTarget = resolveContextMenuLine?(point)
            ?? wordSelection.map { ($0.lineId, $0.anchorRectInScrollViewport) }

        pendingMenuWordSelection = wordSelection
        pendingMenuLineTarget = lineTarget

        insertStudyItems(
            into: contextMenu,
            hasSelection: hasSelection,
            hasWordSelection: wordSelection != nil,
            hasLineTarget: lineTarget != nil
        )
        if let lineId = lineTarget?.lineId,
           let loopState = resolveLineLoopMenuState?(lineId) {
            insertLoopItems(into: contextMenu, state: loopState)
        }
        return contextMenu.items.isEmpty ? nil : contextMenu
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.copy(_:)) {
            return selectedRange().length > 0
        }
        if menuItem.action == #selector(handleContextMenuToggleSingleLoop(_:))
            || menuItem.action == #selector(handleContextMenuSetABLoopAnchor(_:))
            || menuItem.action == #selector(handleContextMenuCompleteABLoop(_:)) {
            return menuItem.tag == 1
        }
        return super.validateMenuItem(menuItem)
    }

    private func insertStudyItems(
        into menu: NSMenu,
        hasSelection: Bool,
        hasWordSelection: Bool,
        hasLineTarget: Bool
    ) {
        if hasWordSelection {
            menu.addItem(makeStudyMenuItem(
                title: "划词解析…",
                symbol: "magnifyingglass",
                action: #selector(handleContextMenuWordStudy(_:))
            ))
        }
        if hasSelection {
            menu.addItem(makeStudyMenuItem(
                title: "拷贝",
                symbol: "doc.on.doc",
                action: #selector(NSText.copy(_:))
            ))
        }
        if hasLineTarget {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(makeStudyMenuItem(
                title: "解析这句歌词（语法 / 唱法 / 笔记）",
                symbol: "text.book.closed",
                action: #selector(handleContextMenuLineStudy(_:))
            ))
            menu.addItem(makeStudyMenuItem(
                title: "编辑这句歌词 / 注音 / 译文…",
                symbol: "square.and.pencil",
                action: #selector(handleContextMenuLineEdit(_:))
            ))
        }
    }

    private func insertLoopItems(
        into menu: NSMenu,
        state: LyricsLineLoopMenuState
    ) {
        var loopItems: [NSMenuItem] = []
        if state.isCurrentSingleLineLoop || state.canSingleLineLoop {
            let singleItem = makeStudyMenuItem(
                title: state.isCurrentSingleLineLoop ? "退出单句循环" : "单句循环本句",
                symbol: state.isCurrentSingleLineLoop ? "stop.circle" : "repeat.1",
                action: #selector(handleContextMenuToggleSingleLoop(_:))
            )
            singleItem.tag = 1
            loopItems.append(singleItem)
        }
        if state.hasPendingAnchor {
            let endItem = makeStudyMenuItem(
                title: "设为终点 B 并开始复读",
                symbol: "repeat",
                action: #selector(handleContextMenuCompleteABLoop(_:))
            )
            endItem.tag = state.canCompleteABLoop ? 1 : 0
            endItem.isEnabled = state.canCompleteABLoop
            loopItems.append(endItem)
        } else if state.canSetAnchor {
            let anchorItem = makeStudyMenuItem(
                title: "设为 AB 复读起点 A",
                symbol: "pin",
                action: #selector(handleContextMenuSetABLoopAnchor(_:))
            )
            anchorItem.tag = 1
            loopItems.append(anchorItem)
        }
        guard !loopItems.isEmpty else { return }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for item in loopItems {
            menu.addItem(item)
        }
    }

    private func makeStudyMenuItem(
        title: String,
        symbol: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
        return item
    }

    @objc private func handleContextMenuWordStudy(_ sender: NSMenuItem) {
        _ = sender
        guard let selection = pendingMenuWordSelection else { return }
        pendingMenuWordSelection = nil
        onRequestWordStudy?(selection)
    }

    @objc private func handleContextMenuLineStudy(_ sender: NSMenuItem) {
        _ = sender
        guard let target = pendingMenuLineTarget else { return }
        pendingMenuLineTarget = nil
        onRequestLineStudy?(target.lineId, target.anchorRect)
    }

    @objc private func handleContextMenuLineEdit(_ sender: NSMenuItem) {
        _ = sender
        guard let target = pendingMenuLineTarget else { return }
        pendingMenuLineTarget = nil
        onRequestLineEdit?(target.lineId, target.anchorRect)
    }

    @objc private func handleContextMenuToggleSingleLoop(_ sender: NSMenuItem) {
        _ = sender
        guard let target = pendingMenuLineTarget else { return }
        pendingMenuLineTarget = nil
        onToggleSingleLineLoop?(target.lineId)
    }

    @objc private func handleContextMenuSetABLoopAnchor(_ sender: NSMenuItem) {
        _ = sender
        guard let target = pendingMenuLineTarget else { return }
        pendingMenuLineTarget = nil
        onSetABLoopAnchor?(target.lineId)
    }

    @objc private func handleContextMenuCompleteABLoop(_ sender: NSMenuItem) {
        _ = sender
        guard let target = pendingMenuLineTarget else { return }
        pendingMenuLineTarget = nil
        onCompleteABLoop?(target.lineId)
    }
}
