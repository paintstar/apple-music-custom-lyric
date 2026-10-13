import AppKit
import Foundation
import SwiftUI
import ShinAppleKit
import ShinAppleData
import ShinAppServices

// 原创数据 + 可控异步命令；不实例化真实 Music 适配器。
private final class CheckSubscription: PlaybackSubscriptionHandle, @unchecked Sendable {
    let cancellation: @Sendable () -> Void
    init(_ cancellation: @escaping @Sendable () -> Void) { self.cancellation = cancellation }
    func cancel() { cancellation() }
}

private final class CheckController: PlaybackController, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PlaybackSnapshot
    private var handlers: [UUID: @Sendable (PlaybackSnapshot) -> Void] = [:]
    private var pending: [Int64: CheckedContinuation<Void, Error>] = [:]
    private var receivedSeeks: [Int64] = []
    init(_ initial: PlaybackSnapshot) { current = initial }
    var subscriberCount: Int { lock.withLock { handlers.count } }
    var pendingTargets: Set<Int64> { lock.withLock { Set(pending.keys) } }
    var seekCount: Int { lock.withLock { receivedSeeks.count } }
    func snapshot() -> PlaybackSnapshot { lock.withLock { current } }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return CheckSubscription { [weak self] in
            _ = self?.lock.withLock { self?.handlers.removeValue(forKey: id) }
        }
    }
    func publish(_ snapshot: PlaybackSnapshot) {
        let callbacks = lock.withLock {
            current = snapshot
            return Array(handlers.values)
        }
        for callback in callbacks { callback(snapshot) }
    }
    func seek(positionMs: Int64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { receivedSeeks.append(positionMs); pending[positionMs] = continuation }
        }
    }
    func completeSeek(_ target: Int64, error: PlaybackError? = nil, publishesPosition: Bool = true) {
        guard let continuation = lock.withLock({ pending.removeValue(forKey: target) }) else {
            preconditionFailure("测试未找到待完成的 seek")
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            if publishesPosition {
                var next = snapshot()
                next.positionMs = target
                next.seq += 1
                publish(next)
            }
            continuation.resume()
        }
    }
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func dispose() {}
}

@main
private struct PlayerUICheck {
    @MainActor static func eventually(
        _ message: String, attempts: Int = 200, diagnostic: (() -> String)? = nil, _ predicate: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure(diagnostic.map { message + "\n" + $0() } ?? message)
    }

    @MainActor static func checkAutoReturn(
        store: GRDBLyricsStore, document: LyricDocument, snapshot: PlaybackSnapshot
    ) async throws {
        let panel = LyricsPanelModel(store: store, manualResumeDelay: .milliseconds(100))
        let coordinator = PlaybackLyricsCoordinator(onDisplayChange: { _ in })
        coordinator.update(snapshot: snapshot)
        panel.attach(coordinator: coordinator)
        await panel.refresh(trackKey: snapshot.trackKey, trackEpoch: snapshot.trackEpoch)
        panel.apply(display: coordinator.currentDisplay())
        let firstArea = UUID()
        let compactArea = UUID()
        panel.lyricsAreaAppeared(firstArea)
        panel.enterManualBrowsing()
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(25))
            panel.enterManualBrowsing()
            precondition(panel.browseMode == .manual, "持续阅读应延长手动模式")
        }
        try await eventually("空闲后应自动回到当前歌词") { panel.browseMode == .follow }
        precondition(panel.scrollRequest?.lineId == document.lines[0].id)

        let native = LyricsScrollView()
        native.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        native.tile()
        native.configure(NativeLyricsScrollView(
            document: document, typography: .resolved(line: 30, translation: 15, width: 300),
            showTranslations: true, currentLineIds: [document.lines[0].id], request: panel.scrollRequest,
            followsPlayback: true, reduceMotion: true,
            onInteraction: { panel.enterManualBrowsing() }, onDragStateChange: { _ in }, onTapLine: { _ in }
        ))
        native.layoutSubtreeIfNeeded()
        precondition(panel.browseMode == .follow, "程序定位和布局不能误触发手动模式")
        // 等待 SwiftUI/AppKit 的尺寸安定期；真实滚轮和拖动不受此等待影响。
        try await Task.sleep(for: .milliseconds(250))
        // 模拟辅助功能直接滚动 clip 的无 NSEvent 路径，实际 AX 动作另由 GUI 复验。
        native.contentView.scroll(to: NSPoint(x: 0, y: 100))
        precondition(panel.browseMode == .manual, "无 NSEvent 的用户滚动也必须暂停跟随")
        try await eventually("辅助滚动空闲后同样自动恢复") { panel.browseMode == .follow }

        panel.setManualInteractionActive(true, in: firstArea)
        try await Task.sleep(for: .milliseconds(160))
        precondition(panel.browseMode == .manual, "按住滚动条/选择文字时不得超时抢回")
        panel.setManualInteractionActive(false, in: firstArea)
        try await eventually("松手后开始计算空闲时间") { panel.browseMode == .follow }
        panel.enterManualBrowsing()
        panel.setAutoScrollSuspended(true)
        try await Task.sleep(for: .milliseconds(160))
        precondition(panel.browseMode == .manual && panel.scrollRequest == nil, "编辑/导入期间计时器不得抢焦点")
        panel.setAutoScrollSuspended(false)
        try await eventually("结束编辑后重新计算空闲回归") { panel.browseMode == .follow }

        panel.lyricsAreaAppeared(compactArea)
        panel.lyricsAreaDisappeared(firstArea)
        panel.enterManualBrowsing()
        try await eventually("紧凑视图交接不得取消新视图的自动回归") { panel.browseMode == .follow }
        panel.enterManualBrowsing()
        panel.lyricsAreaDisappeared(compactArea)
        try await Task.sleep(for: .milliseconds(160))
        precondition(panel.browseMode == .manual, "歌词视图全部隐藏后必须取消计时器")
        panel.lyricsAreaAppeared(compactArea)
        try await eventually("视图重新显示后可恢复计时") { panel.browseMode == .follow }
        panel.enterManualBrowsing()
        var next = snapshot
        next.trackEpoch += 1
        next.trackRef = "music-script:persistent:ABC00002"
        coordinator.update(snapshot: next)
        await panel.refresh(trackKey: next.trackKey, trackEpoch: next.trackEpoch)
        panel.apply(display: coordinator.currentDisplay())
        try await Task.sleep(for: .milliseconds(160))
        precondition(panel.scrollRequest == nil, "切歌后不得由旧计时器滚回旧歌词")
        panel.lyricsAreaDisappeared(compactArea)
        try await checkReadingSettings(store: store, document: document, snapshot: snapshot)
        print("PASS 阅读空闲自动回归、动态等待持久化、无事件辅助滚动、活动延期、编辑挂起、视图交接与隐藏清理")
    }

    @MainActor static func checkReadingSettings(
        store: GRDBLyricsStore, document: LyricDocument, snapshot: PlaybackSnapshot
    ) async throws {
        let domain = "ShinApple.reading-check.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = LyricsReadingSettings.resumeDelayPreferenceKey
        precondition(LyricsReadingSettings.resumeDelay(in: defaults) == LyricsReadingSettings.defaultResumeDelay)
        precondition(LyricsReadingSettings.normalized(.nan) == LyricsReadingSettings.defaultResumeDelay)
        precondition(LyricsReadingSettings.normalized(-1) == LyricsReadingSettings.resumeDelayRange.lowerBound)
        precondition(LyricsReadingSettings.normalized(100) == LyricsReadingSettings.resumeDelayRange.upperBound)
        defaults.set(3.0, forKey: key)
        precondition(LyricsReadingSettings.resumeDelay(in: UserDefaults(suiteName: domain)!) == 3,
                     "阅读等待设置应保存到选用的本机偏好域")
        @MainActor final class ReadingClock { var time: TimeInterval = 100 }
        let readingClock = ReadingClock()
        let panel = LyricsPanelModel(store: store, defaults: defaults, monotonicTime: { readingClock.time })
        let coordinator = PlaybackLyricsCoordinator(onDisplayChange: { _ in })
        coordinator.update(snapshot: snapshot)
        panel.attach(coordinator: coordinator)
        await panel.refresh(trackKey: snapshot.trackKey, trackEpoch: snapshot.trackEpoch)
        panel.apply(display: coordinator.currentDisplay())
        let area = UUID()
        panel.lyricsAreaAppeared(area)
        func setDelay(_ delay: TimeInterval) {
            defaults.set(delay, forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        panel.enterManualBrowsing()
        readingClock.time += 2.5
        setDelay(2)
        try await eventually("缩短设置时应从最后真实阅读活动起算，已到期即回归") { panel.browseMode == .follow }
        precondition(panel.scrollRequest?.lineId == document.lines[0].id)

        setDelay(3)
        readingClock.time += 10
        panel.enterManualBrowsing()
        readingClock.time += 1.8
        setDelay(2)
        try await Task.sleep(for: .milliseconds(20))
        setDelay(4)
        try await Task.sleep(for: .milliseconds(350))
        precondition(panel.browseMode == .manual, "延长设置后，旧的短等待任务不能提前抢回")
        readingClock.time += 2.5
        setDelay(2)
        try await eventually("再次缩短设置仍从同一次阅读活动起算") { panel.browseMode == .follow }
        panel.lyricsAreaDisappeared(area)
    }

    @MainActor static func checkNativeScroll() {
        let document = LyricDocument(lines: (0..<10_000).map { index in
            LyricLine(startMs: Int64(index) * 1_000, text: "原创测试第 \(index) 行，风经过纸船。",
                      translations: ["zh-Hans": Translation(text: "译文第 \(index) 行。")])
        })
        let view = LyricsScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        view.tile()
        var userScrollCount = 0
        func show(_ index: Int, translated: Bool = true) {
            view.configure(NativeLyricsScrollView(
                document: document,
                typography: LyricsTypography.resolved(line: 30, translation: 15, width: 300),
                showTranslations: translated, currentLineIds: [document.lines[index].id],
                request: LyricsPanelModel.ScrollAnchorRequest(requestId: UUID(), lineId: document.lines[index].id),
                followsPlayback: true, reduceMotion: true,
                onInteraction: { userScrollCount += 1 }, onDragStateChange: { _ in }, onTapLine: { _ in }
            ))
            view.layoutSubtreeIfNeeded()
            let expected = view.textLayout.rows[index].frame.minY
            precondition(abs(view.contentView.bounds.minY - expected) < 1,
                         "万行跨段 seek 与减少动态效果应立即准确定位")
        }
        let initialLayoutStarted = ProcessInfo.processInfo.systemUptime
        show(0)
        let initialLayoutMs = (ProcessInfo.processInfo.systemUptime - initialLayoutStarted) * 1_000
        print("万行首次文本构建与排版：\(Int(initialLayoutMs.rounded())) ms（不含编译）")
        let initialFrames = view.textLayout.rows.map(\.frame)
        show(9_999)
        show(5_000)
        show(0)
        precondition(initialFrames == view.textLayout.rows.map(\.frame), "高亮不能改变行高或字形布局")
        show(9_999, translated: false)
        show(0, translated: true)
        precondition(view.textLayout.rows.count == 10_000, "所有歌词行均有准确坐标")
        show(9_999)
        view.setFrameSize(NSSize(width: 340, height: 520))
        view.tile()
        view.layoutSubtreeIfNeeded()
        precondition(userScrollCount == 0, "程序跳转、双语重排和窗口缩放均不得误触发手动模式")
        // SwiftUI 切换布局时可能先缩小 clip/document，旧远端 offset 会先被约束，TextKit 稍后才重排。
        let compactSize = NSSize(width: 180, height: 180)
        view.contentView.setFrameSize(compactSize)
        view.documentView?.setFrameSize(NSSize(width: compactSize.width, height: compactSize.height * 2))
        view.contentView.scroll(to: NSPoint(x: 0, y: compactSize.height))
        precondition(userScrollCount == 0, "尚未完成重排的尺寸约束不得误触发手动模式")
        view.prepareForRemoval()
        view.contentView.scroll(to: .zero)
        precondition(userScrollCount == 0, "卸载旧视图后不能再影响共享浏览状态")
        print("PASS 万行原生排版、首尾与远距离 seek、双语重排、减少动态效果、高亮不改行高")
    }

    @MainActor static func checkLyricsMenuActions(
        store: GRDBLyricsStore, document: LyricDocument, snapshot: PlaybackSnapshot
    ) async throws {
        let panel = LyricsPanelModel(store: store)
        let coordinator = PlaybackLyricsCoordinator(onDisplayChange: { _ in })
        coordinator.update(snapshot: snapshot)
        panel.attach(coordinator: coordinator)
        await panel.refresh(trackKey: snapshot.trackKey, trackEpoch: snapshot.trackEpoch)
        panel.apply(display: coordinator.currentDisplay())
        var showsTranslations = true
        var edits = 0
        var unlinkRequests = 0
        func items(_ current: LyricsPanelModel?) -> [PlaybackMenu.Item] {
            LyricsMenuActions.items(
                panel: current, showTranslations: Binding(get: { showsTranslations }, set: { showsTranslations = $0 }),
                onUnlink: { unlinkRequests += 1 }, onEdit: { edits += 1 }
            )
        }
        func action(_ title: String) -> PlaybackMenu.Item {
            guard let item = items(panel).first(where: { $0.title == title }) else {
                preconditionFailure("保留菜单缺少 \(title)")
            }
            return item
        }
        precondition(items(nil).filter { $0.action != nil }.allSatisfy { !$0.isEnabled },
                     "歌词未载入时保留菜单的歌词动作应禁用")
        precondition(["延后 0.1 秒", "提前 0.1 秒", "显示译文", "编辑歌词", "解除关联"].allSatisfy { action($0).isEnabled },
                     "歌词就绪时迁移到保留菜单的动作应可用")
        action("延后 0.1 秒").action?()
        precondition(coordinator.currentDisplay().userDelayMs == LyricsPanelModel.delayStepMs,
                     "保留菜单的偏移动作必须仍实际生效")
        panel.apply(display: coordinator.currentDisplay())
        precondition(action("归零").isEnabled)
        action("归零").action?()
        precondition(coordinator.currentDisplay().userDelayMs == 0)
        panel.apply(display: coordinator.currentDisplay())
        action("显示译文").action?()
        precondition(!showsTranslations && !action("显示译文").isChecked)
        action("编辑歌词").action?()
        action("解除关联").action?()
        precondition(edits == 1 && unlinkRequests == 1, "保留菜单仍提供编辑和解除确认入口")
        let retainedDocument = try await store.document(id: document.id)
        precondition(retainedDocument != nil, "请求解除确认不能直接删除歌词文档")
        panel.setAutoScrollSuspended(true)
        precondition(items(panel).filter { $0.action != nil }.allSatisfy { !$0.isEnabled },
                     "导入或编辑期间歌词动作应禁用")
        panel.setAutoScrollSuspended(false)

        let model = AppModel(isMock: true, controller: MockPlaybackController(), searchService: nil)
        model.applySnapshot(snapshot)
        model.lyricsPanel = panel
        let request = LyricsUnlinkRequest(model: model)!
        precondition(request.matches(model), "解除确认在打开时固定当前曲目和文档")
        var next = snapshot
        next.trackEpoch += 1
        next.trackRef = "music-script:persistent:ABC00002"
        model.applySnapshot(next)
        precondition(!request.matches(model), "确认期间切歌不能解除新曲目的关联")
        print("PASS 合并歌词菜单：偏移、译文、编辑、解除确认、不可用状态与切歌保护")
    }

    @MainActor static func checkLyricsRowInteraction() async throws {
        let document = LyricDocument(lines: [
            LyricLine(startMs: 0, text: "Morning paper boats",
                      translations: ["zh-Hans": Translation(text: "晨光中的原创纸船")]),
            LyricLine(startMs: nil, text: "没有时间的原创说明"),
            LyricLine(startMs: 8_000, text: "原创第三句，晚风沿着长街缓缓而来")
        ])
        let view = LyricsScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        view.tile()
        var replays: [UUID] = []
        func configure(canSeek: Bool = true, identity: String = "original-track-1") {
            view.configure(NativeLyricsScrollView(
                document: document, typography: .resolved(line: 30, translation: 15, width: 340),
                showTranslations: true, currentLineIds: [], request: nil, followsPlayback: false, reduceMotion: true,
                onInteraction: {}, onDragStateChange: { _ in }, onTapLine: { replays.append($0) },
                canSeek: canSeek, interactionIdentity: identity
            ))
            view.layoutSubtreeIfNeeded()
        }
        configure()
        let text = view.textLayout.textView
        let row = view.textLayout.rows[0]
        let point = NSPoint(x: row.interactionFrame.midX, y: row.frame.midY)
        let translationPoint = NSPoint(x: point.x, y: row.interactionFrame.maxY - 2)
        let frames = view.textLayout.rows.map(\.frame)
        let height = text.frame.height
        text.updateHover(at: translationPoint)
        precondition(text.hoveredLineId == row.id, "译文区域也应命中同一歌词行")
        precondition(frames == view.textLayout.rows.map(\.frame) && text.frame.height == height, "悬停不得触发布局或行高变化")
        precondition(text.frame.width == view.contentSize.width, "移除重听图标后不应保留右侧按钮留白")
        precondition(view.documentView?.subviews.contains(where: { $0 is NSButton }) == false, "不能用覆盖文字的透明按钮替代图标")
        let clickDelay = Duration.milliseconds(Int64((NSEvent.doubleClickInterval + 0.08) * 1_000))
        func click(_ position: NSPoint, count: Int = 1, selected: Bool = false) {
            text.beginPointerInteraction(at: position, clickCount: count)
            text.endPointerInteraction(at: position, hasSelection: selected)
        }
        click(translationPoint)
        try await Task.sleep(for: clickDelay)
        precondition(replays == [row.id], "单击原文或译文只重听一次")

        click(point)
        click(point, count: 2, selected: true)
        try await Task.sleep(for: clickDelay)
        precondition(replays == [row.id, row.id], "完整双击只重听一次，原生选词不能阻止第二次点击重听")
        let blankPoint = NSPoint(x: row.interactionFrame.maxX - 2, y: row.frame.midY)
        click(blankPoint)
        click(blankPoint, count: 2)
        text.endPointerInteraction(at: blankPoint, hasSelection: false)
        try await Task.sleep(for: clickDelay)
        precondition(replays == [row.id, row.id, row.id], "同行空白双击映射同一稳定行ID，重复松手不重发")
        text.beginPointerInteraction(at: point, clickCount: 1)
        text.pointerDragged()
        text.endPointerInteraction(at: point, hasSelection: false)
        text.setSelectedRange(NSRange(location: row.originalRange.location, length: 7))
        let pasteboard = NSPasteboard.withUniqueName()
        let copyTypes = text.writablePasteboardTypes
        pasteboard.declareTypes(copyTypes, owner: nil)
        precondition(text.selectedRange().length == 7, "原生文本应保留选择范围")
        precondition(text.writeSelection(to: pasteboard, types: copyTypes), "应能使用原生支持的格式复制到专用测试剪贴板")
        precondition(pasteboard.string(forType: .string) == "Morning", "原生文本选择与复制必须保留")
        pasteboard.releaseGlobally()
        try await Task.sleep(for: clickDelay)
        text.beginPointerInteraction(at: point, clickCount: 2)
        text.pointerDragged()
        text.endPointerInteraction(at: point, hasSelection: true)
        for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            text.beginPointerInteraction(at: point, clickCount: 2, modifiers: modifiers)
            text.endPointerInteraction(at: point, hasSelection: true)
        }
        precondition(replays.count == 3, "单击或双击拖选、修饰键选取均不能误 seek")
        text.setSelectedRange(NSRange(location: 0, length: 0))

        text.updateHover(at: point)
        click(point)
        view.contentView.scroll(to: NSPoint(x: 0, y: view.contentView.bounds.minY + 20))
        precondition(text.hoveredLineId == nil, "滚动时应清理旧行悬停")
        try await Task.sleep(for: clickDelay)
        precondition(replays.count == 3, "滚动也应取消延迟单击")
        click(point)
        configure(identity: "original-track-2")
        try await Task.sleep(for: clickDelay)
        precondition(replays.count == 3 && text.hoveredLineId == nil, "切歌后不得执行上一首延迟单击")

        text.beginPointerInteraction(at: point, clickCount: 2)
        configure(identity: "original-track-3")
        text.endPointerInteraction(at: point, hasSelection: true)
        precondition(replays.count == 3, "双击按住时切歌，松手不得执行旧行跳转")
        let untimed = view.textLayout.rows[1].interactionFrame
        text.updateHover(at: NSPoint(x: untimed.midX, y: untimed.midY))
        precondition(text.hoveredLineId == nil, "无时间行不显示可点击高亮")
        click(NSPoint(x: untimed.midX, y: untimed.midY))
        click(NSPoint(x: untimed.midX, y: untimed.midY), count: 2, selected: true)
        text.beginPointerInteraction(at: point, clickCount: 2)
        configure(canSeek: false)
        text.endPointerInteraction(at: point, hasSelection: true)
        text.updateHover(at: point)
        click(point)
        click(point, count: 2, selected: true)
        try await Task.sleep(for: clickDelay)
        precondition(replays.count == 3 && text.hoveredLineId == nil, "无 seek 能力或手势中禁用时不伪造交互")
        configure()
        try await checkNativeLyricsClicks(view: view, points: [point, translationPoint, blankPoint], replayCount: { replays.count })
        let replaysBeforeAccessibility = replays.count
        let accessibleRows = view.documentView?.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        precondition(accessibleRows.allSatisfy { $0.isAccessibilityEnabled() }, "可重听歌词的 VoiceOver 动作必须处于启用状态")
        precondition(!accessibleRows.isEmpty && accessibleRows[0].accessibilityPerformPress(), "无图标也必须保留 VoiceOver 行级重听")
        precondition(replays.count == replaysBeforeAccessibility + 1)
        view.prepareForRemoval()
        precondition(!accessibleRows[0].accessibilityPerformPress(), "卸载后旧 VoiceOver 动作不可重听")
        print("PASS 歌词单击/双击各一次重听、原文译文与同行空白、原生鼠标选词/拖选与复制、未知禁用、切歌清理和 VoiceOver")
    }

    @MainActor private static func checkNativeLyricsClicks(
        view: LyricsScrollView, points: [NSPoint], replayCount: @escaping @MainActor () -> Int
    ) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 340, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        // 命中回归按「悬浮滚动条」设计；系统「显示滚动条=自动」在接入鼠标时
        // 切换为经典滚动条，占据右缘并截获行空白命中（2026-09-24 实测）。
        // 检查显式固定悬浮样式并隐藏滚动条，隔离系统偏好与输入设备差异。
        view.scrollerStyle = .overlay
        view.hasVerticalScroller = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await eventually("原生歌词测试窗口必须已接收键盘焦点") { window.isKeyWindow }
        view.contentView.scroll(to: .zero)
        view.layoutSubtreeIfNeeded()
        let text = view.textLayout.textView
        text.setSelectedRange(NSRange(location: 0, length: 0))
        for point in points {
            let windowPoint = text.convert(point, to: nil)
            let target = view.hitTest(view.superview?.convert(windowPoint, from: nil) ?? windowPoint)
            precondition(target === text, "原文、译文及同行空白必须真正命中原生歌词文本")
        }
        let hold = min(0.03, NSEvent.doubleClickInterval / 8)
        let clickDelay = Duration.milliseconds(Int64((NSEvent.doubleClickInterval + 0.08) * 1_000))
        let event: @MainActor @Sendable (NSEvent.EventType, NSPoint, Int) -> NSEvent = { type, point, count in
            let value = NSEvent.mouseEvent(
                with: type, location: text.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1
            )!
            precondition(value.window === window, "歌词鼠标事件必须属于测试自身窗口")
            return value
        }
        func click(_ point: NSPoint, count: Int, drag: Bool = false) async throws {
            let before = replayCount()
            let end = drag ? NSPoint(x: point.x + 60, y: point.y) : point
            let release = Timer(timeInterval: hold * 2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    precondition(replayCount() == before, "真正松手前不得从mouseDown返回提前seek")
                    NSApplication.shared.postEvent(event(.leftMouseUp, point, count), atStart: false)
                }
            }
            RunLoop.main.add(release, forMode: .common)
            RunLoop.main.add(release, forMode: .eventTracking)
            if drag {
                let dragging = Timer(timeInterval: hold, repeats: false) { _ in
                    MainActor.assumeIsolated { NSApplication.shared.postEvent(event(.leftMouseDragged, end, count), atStart: false) }
                }
                RunLoop.main.add(dragging, forMode: .common)
                RunLoop.main.add(dragging, forMode: .eventTracking)
                let returning = Timer(timeInterval: hold * 1.5, repeats: false) { _ in
                    MainActor.assumeIsolated { NSApplication.shared.postEvent(event(.leftMouseDragged, point, count), atStart: false) }
                }
                RunLoop.main.add(returning, forMode: .common)
                RunLoop.main.add(returning, forMode: .eventTracking)
            }
            NSApplication.shared.postEvent(event(.leftMouseDown, point, count), atStart: false)
            try await Task.sleep(for: .milliseconds(Int64(hold * 3_000) + 10))
        }
        let beforeSingle = replayCount()
        try await click(points[0], count: 1)
        try await Task.sleep(for: clickDelay)
        try await eventually("NSTextView真实单击应重听一次", diagnostic: {
            "expected=\(beforeSingle + 1) actual=\(replayCount()) visible=\(window.isVisible) key=\(window.isKeyWindow)"
        }) { replayCount() == beforeSingle + 1 }
        for point in points {
            let before = replayCount()
            try await click(point, count: 1)
            try await click(point, count: 2)
            try await Task.sleep(for: clickDelay)
            precondition(replayCount() == before + 1, "原文、译文或同行空白的真实双击各只能重听一次")
            precondition(text.selectedRange().length > 0, "真实双击应经过NSTextView原生选词")
        }
        for count in [1, 2] {
            let before = replayCount()
            try await click(NSPoint(x: 8, y: points[0].y), count: count, drag: true)
            try await Task.sleep(for: clickDelay)
            precondition(replayCount() == before, "原生单击或双击拖选即使回到起点也不得重听")
        }
    }

    /// 持续发布权威采样，覆盖真实滚动动画；播放时钟不靠 UI 自行累加。
    @MainActor static func checkContinuousPlayback(store: GRDBLyricsStore) async throws {
        let document = LyricDocument(lines: (0..<18).map { index in
            LyricLine(startMs: Int64(index) * 2_000, text: "连续播放原创第 \(index) 句，风把纸船送向远方。",
                      translations: ["zh-Hans": Translation(text: "原创译文第 \(index) 句。")])
        })
        let binding = SongBinding(persistentID: "ABC10001", lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        var sample = PlaybackSnapshot(
            trackEpoch: 1, title: "连续播放原创测试", positionMs: 0, durationMs: 36_000,
            status: .playing, seq: 1, sessionEpoch: 1, trackRef: binding.trackKey
        )
        let controller = CheckController(sample)
        let model = AppModel(isMock: true, controller: controller, searchService: nil,
                             makeLyricsDatabase: { LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: URL(fileURLWithPath: "/tmp")) })
        await model.start()
        try await eventually("连续播放文档载入") { model.lyricsPanel?.currentDocumentId == document.id }
        guard let panel = model.lyricsPanel else { preconditionFailure("连续播放面板未初始化") }
        var area = UUID()
        panel.lyricsAreaAppeared(area)
        var view = LyricsScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 284, height: 340)
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 284, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        // 真实显示刷新会正确暂停被遮挡的歌词；测试窗口需显式位于普通桌面窗口上方。
        window.level = .floating
        window.orderFrontRegardless()
        defer { view.prepareForRemoval(); window.orderOut(nil) }
        try await eventually("连续歌词动画夹具必须实际可见且未被遮挡") {
            window.isVisible && window.occlusionState.contains(.visible)
        }
        func render() {
            guard case let .ready(loaded) = panel.state else { return }
            view.configure(NativeLyricsScrollView(
                document: loaded, typography: .resolved(line: 30, translation: 15, width: view.frame.width),
                showTranslations: true, currentLineIds: Set(panel.syncDisplay.currentLineIds ?? []),
                request: panel.scrollRequest, followsPlayback: panel.browseMode == .follow,
                reduceMotion: false, onInteraction: { panel.enterManualBrowsing() },
                onDragStateChange: { panel.setManualInteractionActive($0, in: area) }, onTapLine: { _ in }
            ))
            view.layoutSubtreeIfNeeded()
        }
        func animationDiagnostic(for index: Int) -> String {
            let requestedRow = panel.scrollRequest.flatMap { view.textLayout.rowIndices[$0.lineId] }
            let configuredRow = view.configuration?.request.flatMap { view.textLayout.rowIndices[$0.lineId] }
            return "row=\(index) offset=\(view.contentView.bounds.minY) expected=\(view.textLayout.rows[index].frame.minY)"
                + " resolvedTarget=\(String(describing: view.offset(for: document.lines[index].id)))"
                + " animating=\(view.isScrollAnimating) motion=\(String(describing: view.scrollMotion))"
                + " jump=\(String(describing: view.jump)) displayLink=\(view.hasActiveDisplayLink)"
                + " visible=\(window.isVisible) unoccluded=\(window.occlusionState.contains(.visible))"
                + " mode=\(panel.browseMode) configuredFollow=\(view.configuration?.followsPlayback == true)"
                + " requestRow=\(String(describing: requestedRow)) configuredRow=\(String(describing: configuredRow))"
                + " requestMatches=\(panel.scrollRequest?.requestId == view.configuration?.request?.requestId)"
        }
        render()
        var firstOffset = view.contentView.bounds.minY
        for tick in 1...32 {
            sample.positionMs = Int64(tick) * 500
            sample.seq += 1
            controller.publish(sample)
            let expected = document.lines[tick / 4].id
            try await eventually("连续权威样本应更新当前行") { panel.syncDisplay.currentLineIds == [expected] }
            if tick == 12 || tick == 24 {
                let previous = area
                area = UUID()
                panel.lyricsAreaAppeared(area)
                view.prepareForRemoval()
                panel.lyricsAreaDisappeared(previous)
                view = LyricsScrollView()
                view.frame = NSRect(x: 0, y: 0, width: tick == 12 ? 640 : 284, height: tick == 12 ? 520 : 340)
                window.setContentSize(view.frame.size)
                window.contentView = view
                window.orderFrontRegardless()
            }
            render()
            try await Task.sleep(for: .milliseconds(160))
            precondition(panel.browseMode == .follow, "连续播放动画不得误进入手动模式")
        }
        // 与独立动效检查保持 2.5 秒上限；距离响应和系统显示刷新不保证固定时刻完成。
        try await eventually("多次更新后动画必须抵达最新权威歌词行", attempts: 500,
                             diagnostic: { animationDiagnostic(for: 8) }) {
            !view.isScrollAnimating && abs(view.contentView.bounds.minY - view.textLayout.rows[8].frame.minY) < 1
        }
        precondition(view.contentView.bounds.minY > firstOffset + 100, "小窗连续播放必须产生实际滚动")

        model.seek(toMs: 24_000)
        try await eventually("第一次 seek 已进入控制器") { controller.pendingTargets == [24_000] }
        model.seek(toMs: 4_000)
        try await eventually("连续 seek 均已提交") { controller.pendingTargets.count == 2 }
        controller.completeSeek(24_000)
        controller.completeSeek(4_000)
        try await eventually("连 seek 采用最新读回") { panel.syncDisplay.currentLineIds == [document.lines[2].id] }
        render()
        try await eventually("连续 seek 后动画必须抵达最新读回的歌词行", attempts: 500,
                             diagnostic: { animationDiagnostic(for: 2) }) {
            !view.isScrollAnimating && abs(view.contentView.bounds.minY - view.textLayout.rows[2].frame.minY) < 1
        }

        // 真正移动 clip，暂停自动跟随；权威采样仍持续前进，等待后应回到最新行。
        view.contentView.scroll(to: NSPoint(x: 0, y: view.contentView.bounds.minY + 140))
        precondition(panel.browseMode == .manual)
        sample = controller.snapshot()
        // 保留 14 次样本及最终权威位置；等待覆盖实际阅读设置，不沿用旧的 5 秒默认值。
        let idleSampleCount = 14
        let readingDelay = LyricsReadingSettings.resumeDelay(in: .standard)
        let idleSampleInterval = Duration.seconds(max(0.4, readingDelay / Double(idleSampleCount)))
        for _ in 0..<idleSampleCount {
            sample.positionMs = (sample.positionMs ?? 0) + 500
            sample.seq += 1
            controller.publish(sample)
            try await Task.sleep(for: idleSampleInterval)
            render()
        }
        try await eventually("连续播放中手动浏览空闲后恢复", diagnostic: {
            "configuredDelay=\(readingDelay) mode=\(panel.browseMode) "
                + "latestSample=\(sample.seq) publishedSample=\(model.snapshot.seq)"
        }) { panel.browseMode == .follow }
        try await eventually("恢复跟随应采用最后一次权威采样") {
            model.snapshot.seq == sample.seq && panel.syncDisplay.currentLineIds == [document.lines[5].id]
        }
        render()
        guard let id = panel.syncDisplay.currentLineIds?.first, let index = view.textLayout.rowIndices[id] else {
            preconditionFailure("恢复跟随后应有当前行")
        }
        try await eventually("恢复跟随后动画必须抵达最新权威歌词行", attempts: 500,
                             diagnostic: { animationDiagnostic(for: index) }) {
            !view.isScrollAnimating && abs(view.contentView.bounds.minY - view.textLayout.rows[index].frame.minY) < 1
        }

        let nextDocument = LyricDocument(lines: (0..<4).map {
            LyricLine(startMs: Int64($0) * 2_000, text: "切歌后的原创第 \($0) 句")
        })
        let nextBinding = SongBinding(persistentID: "ABC10002", lyricDocumentId: nextDocument.id)
        try await store.save(document: nextDocument, binding: nextBinding)
        sample.trackEpoch += 1
        sample.trackRef = nextBinding.trackKey
        sample.positionMs = 0
        sample.seq += 1
        controller.publish(sample)
        try await eventually("切歌后装载新文档") { panel.currentDocumentId == nextDocument.id }
        try await eventually("新文档当前行生效") { panel.syncDisplay.currentLineIds == [nextDocument.lines[0].id] }
        render()
        firstOffset = view.contentView.bounds.minY
        sample.positionMs = 2_500
        sample.seq += 1
        controller.publish(sample)
        try await eventually("切歌后的后续采样继续更新") { panel.syncDisplay.currentLineIds == [nextDocument.lines[1].id] }
        render()
        try await Task.sleep(for: .milliseconds(650))
        precondition(panel.browseMode == .follow && view.contentView.bounds.minY > firstOffset)
        view.prepareForRemoval()
        panel.lyricsAreaDisappeared(area)
        print("PASS 连续权威采样、真实歌词动画、小窗交接、连 seek、播放中自动回归与切歌续播")
    }

    @MainActor static func findPlaybackSlider(in view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider, slider.accessibilityLabel() == "播放进度" { return slider }
        return view.subviews.lazy.compactMap { findPlaybackSlider(in: $0) }.first
    }

    @discardableResult
    @MainActor static func sendSliderMouse(
        _ type: NSEvent.EventType, fraction: CGFloat, slider: NSSlider, window: NSWindow, localY: CGFloat? = nil
    ) -> NSPoint {
        let knob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
        var local = NSPoint(x: knob.width / 2 + fraction * (slider.bounds.width - knob.width), y: localY ?? slider.bounds.midY)
        // 此夹具抓旋钮中心；原生中心已按像素取整，数学近似会意外形成抓取偏移。
        if type == .leftMouseDown, knob.contains(local) { local.x = knob.midX }
        let location = slider.convert(local, to: nil)
        let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        window.sendEvent(event)
        return local
    }

    /// 向实际注册的局部tracking owner投递公开事件；不伪装成系统指针移动。
    @MainActor static func sliderHover(_ entered: Bool, slider: NSSlider, window: NSWindow) {
        slider.updateTrackingAreas()
        let area = slider.trackingAreas.first {
            ($0.owner as? NSView) === slider && $0.options.contains(.mouseEnteredAndExited)
        }
        precondition(area?.options.contains(.activeAlways) == true, "未激活窗口也应支持局部悬停")
        let event = NSEvent.enterExitEvent(
            with: entered ? .mouseEntered : .mouseExited,
            location: slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!
        let owner = area!.owner as! NSResponder
        if entered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
    }

    /// 直接检查生产cell绘出的轨道，避开系统焦点环；不读取私有交互状态。
    @MainActor static func renderedTrackHeight(_ slider: NSSlider) -> CGFloat {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 32,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (slider.cell as! NSSliderCell).drawBar(inside: NSRect(x: 0, y: 0, width: 160, height: 32), flipped: false)
        NSGraphicsContext.current?.flushGraphics()
        let alphas = (0..<32).map { bitmap.colorAt(x: 120, y: $0)?.alphaComponent ?? 0 }
        guard let peak = alphas.max(), peak > 0 else { return 0 }
        return alphas.reduce(0, +) / peak
    }

    @MainActor static func checkPlaybackDragging(store: GRDBLyricsStore, snapshot: PlaybackSnapshot) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for thin in [false, true] {
            var sample = snapshot
            sample.positionMs = 6_000
            let controller = CheckController(sample)
            let model = AppModel(
                isMock: true, controller: controller, searchService: nil,
                makeLyricsDatabase: { LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: URL(fileURLWithPath: "/tmp")) }
            )
            await model.start()
            let host = NSHostingView(rootView: PlaybackTimelineProgressView(showsTimeLabels: !thin, thinStyle: thin)
                .environmentObject(model).padding(20))
            let window = NSWindow(
                contentRect: NSRect(x: 60, y: 60, width: 360, height: 100),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.isMovableByWindowBackground = true
            window.contentView = host
            window.level = .floating
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            try await eventually("原生进度控件应进入窗口") { findPlaybackSlider(in: host) != nil }
            let slider = findPlaybackSlider(in: host)!
            // 先触发 SwiftUI 测量，再跨三个30fps周期等待真实样本和原生几何稳定。
            _ = host.fittingSize
            var previousFrame: NSRect?
            var previousBounds: NSRect?
            var previousKnob: NSRect?
            var previousBar: NSRect?
            var previousSize: NSSize?
            var stableSince = ProcessInfo.processInfo.systemUptime
            try await eventually("原生进度测量后的实例、真实样本、几何和命中应稳定") {
                let size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                host.displayIfNeeded()
                slider.displayIfNeeded()
                guard window.occlusionState.contains(.visible), findPlaybackSlider(in: host) === slider, slider.isEnabled,
                      slider.doubleValue == Double(sample.positionMs!),
                      slider.maxValue == Double(sample.durationMs!), let cell = slider.cell as? NSSliderCell else {
                    stableSince = ProcessInfo.processInfo.systemUptime
                    return false
                }
                let knob = cell.knobRect(flipped: slider.isFlipped)
                let bar = cell.barRect(flipped: slider.isFlipped)
                let point = slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: host.superview)
                guard knob.width > 0, knob.height > 0, bar.width > knob.width, host.hitTest(point) === slider else {
                    stableSince = ProcessInfo.processInfo.systemUptime
                    return false
                }
                if previousFrame != slider.frame || previousBounds != slider.bounds || previousKnob != knob
                    || previousBar != bar || previousSize != size {
                    previousFrame = slider.frame
                    previousBounds = slider.bounds
                    previousKnob = knob
                    previousBar = bar
                    previousSize = size
                    stableSince = ProcessInfo.processInfo.systemUptime
                    return false
                }
                return ProcessInfo.processInfo.systemUptime - stableSince >= 0.1
            }
            precondition(window.windowNumber > 0 && slider.isEnabled, "鼠标回归需要真实AppKit窗口及已启用的进度")
            // NSView.hitTest 的入参属于接收者的 superview 坐标，NSHostingView 本身是 flipped。
            let point = slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: host.superview)
            let hit = host.hitTest(point)
            precondition(hit === slider && !slider.mouseDownCanMoveWindow, "进度命中不得被宿主或拖窗接走")
            let restingHeight = thin ? renderedTrackHeight(slider) : 0
            let originalBounds = slider.bounds
            if thin {
                precondition(abs(slider.bounds.height - ThinPlaybackSliderSizing.hitHeight) < 0.01
                             && slider.alignmentRect(forFrame: slider.frame) == slider.frame,
                             "细进度原生边界与24点SwiftUI槽位应一致：\(slider.bounds)，\(slider.alignmentRectInsets)")
                for y in [slider.bounds.minY + 2, slider.bounds.maxY - 2] {
                    let edge = slider.convert(NSPoint(x: slider.bounds.midX, y: y), to: host.superview)
                    precondition(host.hitTest(edge) === slider, "轨道上下留白也必须可点击")
                }
                for point in [NSPoint(x: slider.bounds.midX, y: slider.bounds.minY - 1),
                              NSPoint(x: slider.bounds.midX, y: slider.bounds.maxY + 1),
                              NSPoint(x: slider.bounds.minX - 1, y: slider.bounds.midY),
                              NSPoint(x: slider.bounds.maxX + 1, y: slider.bounds.midY)] {
                    precondition(host.hitTest(slider.convert(point, to: host.superview)) !== slider,
                                 "轨道不得截获24点控制区域外的点击")
                }
                let knob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
                sliderHover(true, slider: slider, window: window)
                try await eventually("悬停必须经过真实的绘制中间态") {
                    let height = renderedTrackHeight(slider)
                    return height > restingHeight + 0.15 && height < 5.3
                }
                let beforeReverse = renderedTrackHeight(slider)
                sliderHover(false, slider: slider, window: window)
                precondition(abs(renderedTrackHeight(slider) - beforeReverse) < 0.15, "快速反向必须接续当前画面，不跳到端点")
                try await eventually("反向退出应回到静止轨道") { abs(renderedTrackHeight(slider) - restingHeight) < 0.15 }
                sliderHover(true, slider: slider, window: window)
                try await eventually("悬停结束应为柔和的5.5点轨道") { abs(renderedTrackHeight(slider) - 5.5) < 0.2 }
                precondition(slider.bounds == originalBounds && (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped) == knob,
                             "悬停不得改变控件布局或原生seek几何")
                precondition(controller.seekCount == 0, "悬停不得发送seek")
                sliderHover(false, slider: slider, window: window)
                try await eventually("离开应恢复静止轨道") { abs(renderedTrackHeight(slider) - restingHeight) < 0.15 }
            }
            let downPoint = sendSliderMouse(.leftMouseDown, fraction: 0.2, slider: slider, window: window, localY: thin ? 2 : nil)
            let valueAfterDown = slider.doubleValue
            if thin {
                sliderHover(false, slider: slider, window: window)
            }
            let dragPoint = sendSliderMouse(.leftMouseDragged, fraction: 0.78, slider: slider, window: window, localY: thin ? -6 : nil)
            try await Task.sleep(for: .milliseconds(25))
            precondition(controller.seekCount == 0 && abs(slider.doubleValue - 23_400) < 3,
                         "拖动中只更新原生滑块预览，不发送seek：thin=\(thin)，"
                         + "tracking=\((slider as? PlaybackScrubber.TrackingSlider)?.isTrackingMouse == true)，"
                         + "value=\(slider.doubleValue)，seekCount=\(controller.seekCount)，"
                         + "downPoint=\(downPoint)，dragPoint=\(dragPoint)，valueAfterDown=\(valueAfterDown)，"
                         + "pendingSeek=\(String(describing: model.pendingSeek))，"
                         + "bounds=\(slider.bounds)，knob=\((slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped))，"
                         + "windowVisible=\(window.isVisible)，unoccluded=\(window.occlusionState.contains(.visible))")
            if thin {
                try await eventually("按住后移出仍应保持6.5点强调，进度不等待动画") { abs(renderedTrackHeight(slider) - 6.5) < 0.2 }
                precondition(slider.focusRingType == .none, "鼠标按住不显示蓝色键盘焦点圈")
            }
            sample.seq += 1
            sample.positionMs = 4_000
            controller.publish(sample)
            try await eventually("拖动中权威样本仍继续更新") { model.snapshot.seq == sample.seq }
            try await Task.sleep(for: .milliseconds(25))
            precondition(abs(slider.doubleValue - 23_400) < 3, "同歌曲新采样不得覆盖拖动位置")
            sendSliderMouse(.leftMouseDragged, fraction: 0.35, slider: slider, window: window)
            precondition(abs(slider.doubleValue - 10_500) < 3, "向左拖动也必须更新预览")
            sendSliderMouse(.leftMouseUp, fraction: 0.35, slider: slider, window: window, localY: thin ? -6 : nil)
            if thin {
                try await eventually("轨道外松手应柔和恢复静止样式") { abs(renderedTrackHeight(slider) - restingHeight) < 0.15 }
                precondition(slider.bounds == originalBounds, "外观动画不能改变命中高度")
            }
            try await eventually("松手应只发出一次最终位置seek") { controller.seekCount == 1 }
            let target = controller.pendingTargets.first!
            precondition(abs(target - 10_500) < 3 && controller.pendingTargets.count == 1)
            precondition(model.pendingSeek?.positionMs == target, "松手应同步保留目标展示")
            for oldPosition: Int64 in [4_000, 4_200, 4_500] {
                sample.seq += 1
                sample.positionMs = oldPosition
                sample.status = .playing
                controller.publish(sample)
                try await eventually("命令未结束时仍接收旧位置采样") { model.snapshot.seq == sample.seq }
                // 跨过多个30fps绘制周期，确认旧estimate不能把真实NSSlider拉回。
                try await Task.sleep(for: .milliseconds(70))
                precondition(abs(slider.doubleValue - Double(target)) < 3, "松手等待确认期间进度不得回弹")
                precondition(model.snapshot.positionMs == oldPosition
                             && (model.estimatedPositionMs(nowMonotonicMs: AppModel.monotonicNowMs()).positionMs ?? target) < target,
                             "待确认展示不能伪改权威快照或时钟")
            }
            controller.completeSeek(target)
            try await eventually("拖动结果采用权威读回并释放展示目标") {
                model.snapshot.positionMs == target && model.pendingSeek == nil
            }
            sample = controller.snapshot()
            sample.status = .paused
            sample.seq += 1
            controller.publish(sample)
            try await eventually("确认后原生进度接回权威时钟") { abs(slider.doubleValue - Double(target)) < 3 }
            if thin {
                sendSliderMouse(.leftMouseDown, fraction: 0.35, slider: slider, window: window)
                sliderHover(false, slider: slider, window: window)
                try await eventually("Esc取消前应已有正在绘制的强调动画") { renderedTrackHeight(slider) > restingHeight + 0.15 }
                slider.cancelOperation(nil)
                sendSliderMouse(.leftMouseUp, fraction: 0.35, slider: slider, window: window)
                precondition(controller.seekCount == 1 && abs(renderedTrackHeight(slider) - restingHeight) < 0.15,
                             "Esc取消应清理按下样式且不提交seek")
                try await Task.sleep(for: .milliseconds(260))
                precondition(abs(renderedTrackHeight(slider) - restingHeight) < 0.15, "Esc后旧动画不得恢复按下样式")
            }
            sendSliderMouse(.leftMouseDown, fraction: 0.35, slider: slider, window: window)
            sendSliderMouse(.leftMouseDragged, fraction: 0.8, slider: slider, window: window)
            sample.trackEpoch += 1
            sample.trackRef = "music-script:persistent:ABC0D002"
            sample.seq += 2
            sample.positionMs = 2_000
            controller.publish(sample)
            try await eventually("拖动中切歌应可见") { model.snapshot.trackEpoch == sample.trackEpoch }
            try await Task.sleep(for: .milliseconds(25))
            sendSliderMouse(.leftMouseUp, fraction: 0.8, slider: slider, window: window)
            try await Task.sleep(for: .milliseconds(25))
            precondition(controller.seekCount == 1, "跨曲目松手不得对新歌曲发出旧seek")
            sample.positionMs = nil
            sample.seq += 1
            controller.publish(sample)
            try await eventually("未知播放位置应禁用原生进度") { !slider.isEnabled }
            sendSliderMouse(.leftMouseDown, fraction: 0.2, slider: slider, window: window)
            sendSliderMouse(.leftMouseDragged, fraction: 0.8, slider: slider, window: window)
            sendSliderMouse(.leftMouseUp, fraction: 0.8, slider: slider, window: window)
            try await Task.sleep(for: .milliseconds(25))
            precondition(controller.seekCount == 1, "未知位置不得通过鼠标手势发出seek")
            if thin {
                sliderHover(true, slider: slider, window: window)
                precondition(renderedTrackHeight(slider) <= restingHeight, "未知或禁用位置不显示可拖动强调")
                sample.positionMs = 2_000
                sample.seq += 1
                controller.publish(sample)
                try await eventually("恢复已知位置") { slider.isEnabled }
                let upperEdge = slider.bounds.maxY - 2
                sendSliderMouse(.leftMouseDown, fraction: 0.6, slider: slider, window: window, localY: upperEdge)
                sendSliderMouse(.leftMouseUp, fraction: 0.6, slider: slider, window: window, localY: upperEdge)
                try await eventually("上边缘真实点击应只提交一次seek") { controller.seekCount == 2 }
                let edgeTarget = controller.pendingTargets.first!
                precondition(abs(edgeTarget - 18_000) < 3, "边缘点击应保持原生横向seek换算")
                controller.completeSeek(edgeTarget)
                try await eventually("边缘点击应完成权威读回") { model.pendingSeek == nil }
                sendSliderMouse(.leftMouseDown, fraction: 0.2, slider: slider, window: window)
                try await eventually("卸载前应已有正在绘制的强调动画") { renderedTrackHeight(slider) > restingHeight + 0.15 }
                window.contentView = NSView()
                precondition(slider.trackingAreas.allSatisfy { ($0.owner as? NSView) !== slider }, "卸载应移除局部tracking")
                precondition(controller.seekCount == 2 && abs(renderedTrackHeight(slider) - restingHeight) < 0.15,
                             "卸载应取消拖动强调且不提交seek")
                try await Task.sleep(for: .milliseconds(260))
                precondition(abs(renderedTrackHeight(slider) - restingHeight) < 0.15, "卸载后不得由旧动画重新绘制按下样式")
            }
        }
        try await checkReducedMotionScrubber(snapshot: snapshot)
        print("PASS 默认/细进度拖动与单次seek；24点命中、动画中间态/快速反向、拖出保持、减少动态效果、Esc/卸载清理及未知禁用")
    }

    @MainActor static func checkReducedMotionScrubber(snapshot: PlaybackSnapshot) async throws {
        let view = PlaybackScrubber(snapshot: snapshot, positionMs: 6_000, durationMs: 30_000,
                                    enabled: true, thinStyle: true, reduceMotion: true,
                                    onPreview: { _ in }, onSeek: { _, _ in preconditionFailure("外观检查不可提交seek") })
        let host = NSHostingView(rootView: view.frame(height: 24).padding(20))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 360, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.level = .floating
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await eventually("减少动态效果夹具应完成原生状态更新") {
            guard let slider = findPlaybackSlider(in: host) else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
                && slider.isEnabled && slider.maxValue == 30_000 && slider.doubleValue == 6_000
        }
        let slider = findPlaybackSlider(in: host)!
        sliderHover(true, slider: slider, window: window)
        let immediateHover = renderedTrackHeight(slider)
        try await Task.sleep(for: .milliseconds(20))
        precondition(abs(immediateHover - 5.5) < 0.2 && abs(renderedTrackHeight(slider) - 5.5) < 0.2,
                     "减少动态效果应即时生效并保持，立即\(immediateHover)，下一帧\(renderedTrackHeight(slider))")
        sendSliderMouse(.leftMouseDown, fraction: 0.2, slider: slider, window: window)
        precondition(abs(renderedTrackHeight(slider) - 6.5) < 0.2, "减少动态效果时按下直接到终点")
        sliderHover(false, slider: slider, window: window)
        slider.cancelOperation(nil)
        sendSliderMouse(.leftMouseUp, fraction: 0.2, slider: slider, window: window)
        let immediateCancel = renderedTrackHeight(slider)
        try await Task.sleep(for: .milliseconds(260))
        precondition(abs(immediateCancel - 3) < 0.2 && abs(renderedTrackHeight(slider) - 3) < 0.2,
                     "减少动态效果取消应即时复位，旧动画不得回写")
    }

    @MainActor private static func checkCompactWindowLayout() async throws {
        let suite = "shin-window-layout-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let snapshot = PlaybackSnapshot(trackEpoch: 1, title: "原创窗口练习", positionMs: 1_000,
                                        durationMs: 30_000, status: .paused,
                                        trackRef: "music-script:persistent:ACED0010")
        func makeModel() -> AppModel {
            AppModel(isMock: true, controller: CheckController(snapshot), searchService: nil,
                     makeLyricsDatabase: {
                         LyricsDatabase.Database(store: store, locationDescription: "原创窗口临时库", directory: directory)
                     })
        }
        func makeWindow(_ model: AppModel, size: NSSize) -> (NSWindow, NSHostingView<AnyView>) {
            let host = NSHostingView(rootView: AnyView(ContentView(preferences: preferences)
                .environmentObject(model).defaultAppStorage(preferences)))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.collectionBehavior = [.fullScreenPrimary]
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            return (window, host)
        }
        func probe(in view: NSView) -> PlayerWindowAccessor.WindowProbe? {
            if let probe = view as? PlayerWindowAccessor.WindowProbe { return probe }
            return view.subviews.lazy.compactMap { probe(in: $0) }.first
        }
        preferences.set("compact", forKey: "player.presentationMode")
        preferences.set("nowPlaying", forKey: "player.compactReturnMode")
        let model = makeModel()
        await model.start()
        let (window, host) = makeWindow(model, size: NSSize(width: 1180, height: 780))
        defer { window.close() }
        try await eventually("持久化compact冷启动应恢复紧凑尺寸", attempts: 600) {
            host.layoutSubtreeIfNeeded()
            return abs(window.contentLayoutRect.width - PlayerWindowController.compactContentSize.width) < 2
                && preferences.string(forKey: "player.presentationMode") == "compact"
                && probe(in: host)?.controller.hasRestoredInitialLayout == true
        }
        window.setContentSize(NSSize(width: 1180, height: 780))
        try await eventually("用户拖宽应恢复原完整页面而非横向拉伸compact", attempts: 600) {
            host.layoutSubtreeIfNeeded()
            return preferences.string(forKey: "player.presentationMode") == "nowPlaying"
                && (findPlaybackSlider(in: host)?.bounds.width ?? 1180) < window.contentLayoutRect.width / 2
        }
        let controller = probe(in: host)!.controller
        @MainActor final class FullScreenTransitions {
            var entered = false
            var exited = false
        }
        let transitions = FullScreenTransitions()
        let entered = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                             object: window, queue: .main) { _ in
            Task { @MainActor in transitions.entered = true }
        }
        let exited = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                            object: window, queue: .main) { _ in
            Task { @MainActor in transitions.exited = true }
        }
        defer { NotificationCenter.default.removeObserver(entered); NotificationCenter.default.removeObserver(exited) }
        window.toggleFullScreen(nil)
        try await eventually("模拟窗口应完成原生全屏进入", attempts: 1_200) {
            transitions.entered && window.styleMask.contains(.fullScreen)
        }
        precondition(!controller.showCompact(reduceMotion: true), "全屏期间compact请求必须拒绝且不改变模式")
        precondition(preferences.string(forKey: "player.presentationMode") == "nowPlaying")
        window.toggleFullScreen(nil)
        try await eventually("模拟窗口应完成原生全屏退出", attempts: 1_200) {
            transitions.exited && !window.styleMask.contains(.fullScreen)
        }
        window.close()

        for presentBeforeAttach in [true, false] {
            preferences.set("compact", forKey: "player.presentationMode")
            let sheetModel = makeModel()
            await sheetModel.start()
            if presentBeforeAttach { sheetModel.isLibraryPresented = true }
            let (sheetWindow, sheetHost) = makeWindow(sheetModel, size: PlayerWindowController.compactContentSize)
            defer { sheetModel.isLibraryPresented = false; sheetWindow.close() }
            if !presentBeforeAttach { sheetModel.isLibraryPresented = true }
            try await eventually("预览必须优先展开，不受先openWindow再呈现的时序影响", attempts: 600) {
                sheetHost.layoutSubtreeIfNeeded()
                return sheetWindow.contentLayoutRect.width >= PlayerWindowController.compactBreakpoint
                    && probe(in: sheetHost)?.controller.hasRestoredInitialLayout == true
                    && sheetWindow.attachedSheet != nil
            }
            await Task.yield()
            precondition(sheetWindow.contentLayoutRect.width >= PlayerWindowController.compactBreakpoint)
            sheetModel.isLibraryPresented = false
            try await eventually("模拟预览应完成收起", attempts: 600) { sheetWindow.attachedSheet == nil }
        }
        print("PASS 窗口布局：compact冷启动、拖宽回完整、全屏拒绝compact、已有预览优先展开")
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await runChecks()
                fflush(nil)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func runChecks() async throws {
        if CommandLine.arguments.contains("--playback-options-only") {
            try await PlaybackOptionsUICheck.runChecks()
            return
        }
        if CommandLine.arguments.contains("--window-layout-only") {
            try await checkCompactWindowLayout()
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shin-ui-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let document = LyricDocument(lines: [
            LyricLine(startMs: 0, text: "晨光落在窗沿"),
            LyricLine(startMs: 10_000, text: "纸船驶过浅湾"),
            LyricLine(startMs: 20_000, text: "晚风收起帆")
        ])
        let binding = SongBinding(persistentID: "ABC00001", lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let initial = PlaybackSnapshot(
            trackEpoch: 1, title: "原创界面测试", positionMs: 2_000, durationMs: 30_000,
            status: .paused, seq: 1, sessionEpoch: 1, trackRef: binding.trackKey
        )
        var denied = initial
        denied.errorCode = AppModel.permissionDeniedCode
        let deniedController = CheckController(denied)
        var opened = 0
        var deniedModel: AppModel? = AppModel(
            isMock: false, controller: deniedController, searchService: nil,
            makeLyricsDatabase: {
                opened += 1
                try await Task.sleep(for: .milliseconds(20))
                return LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: URL(fileURLWithPath: "/tmp"))
            }
        )
        let deniedStartA = Task { await deniedModel?.start() }
        let deniedStartB = Task { await deniedModel?.start() }
        await deniedStartA.value
        await deniedStartB.value
        precondition(opened == 1 && deniedController.subscriberCount == 1, "重复启动必须复用初始化和订阅")
        precondition(deniedModel?.setup == .automationDenied, "数据库就绪不得覆盖自动化拒绝状态")
        deniedModel = nil
        try await eventually("模型释放应取消订阅") { deniedController.subscriberCount == 0 }
        print("PASS 重复启动、首快照权限、订阅清理")

        let controller = CheckController(initial)
        let model = AppModel(
            isMock: true, controller: controller, searchService: nil,
            makeLyricsDatabase: { LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: URL(fileURLWithPath: "/tmp")) }
        )
        await model.start()
        try await eventually("启动于暂停状态也应加载歌词并同步首行") {
            model.lyricsPanel?.syncDisplay.currentLineIds?.first == document.lines[0].id
        }
        precondition(model.snapshot == initial, "无需等待下一次采样即可显示现有快照")
        let panel = model.lyricsPanel!
        panel.enterManualBrowsing()
        model.seek(toMs: 11_000)
        try await eventually("seek 应送出") { controller.pendingTargets.contains(11_000) }
        controller.completeSeek(11_000)
        try await eventually("seek 后必须恢复跟随并定位新行") {
            panel.browseMode == .follow && panel.scrollRequest?.lineId == document.lines[1].id
        }
        print("PASS 暂停启动加载歌词、seek 恢复跟随并定位权威歌词行")

        model.seek(toMs: 12_000)
        try await eventually("第一条 seek 应送出") { controller.pendingTargets.contains(12_000) }
        model.seek(toMs: 13_000)
        try await eventually("第二条 seek 应送出") { controller.pendingTargets.contains(13_000) }
        controller.completeSeek(12_000, error: .unauthorized)
        await Task.yield()
        precondition(model.pendingSeek?.positionMs == 13_000, "旧请求失败不得清掉较新的展示目标")
        controller.completeSeek(13_000)
        try await eventually("最新 seek 应生效") { model.snapshot.positionMs == 13_000 && model.pendingSeek == nil }
        precondition(model.setup == .ready, "旧 seek 错误不得覆盖较新成功请求")

        model.seek(toMs: 14_000)
        try await eventually("切歌前 seek 应送出") { controller.pendingTargets.contains(14_000) }
        var nextTrack = initial
        nextTrack.trackEpoch += 1
        nextTrack.trackRef = "music-script:persistent:ABC00002"
        nextTrack.seq = 10
        controller.publish(nextTrack)
        controller.completeSeek(14_000, error: .unauthorized)
        try await eventually("切歌应可见且清掉旧展示目标") { model.snapshot.trackEpoch == 2 && model.pendingSeek == nil }
        model.seek(toMs: 15_000, expectedSnapshot: initial)
        try await Task.sleep(for: .milliseconds(20))
        precondition(!controller.pendingTargets.contains(15_000), "旧歌曲进度条松手不得跳转新歌")
        precondition(model.setup == .ready && model.playbackMessage == nil, "切歌后旧 seek 不得显示过期错误")
        model.seek(toMs: 17_000)
        try await eventually("失败分支请求已送出") { controller.pendingTargets.contains(17_000) }
        controller.completeSeek(17_000, error: .unknown("原创测试失败"))
        try await eventually("失败应清掉目标并显示错误") { model.pendingSeek == nil && model.playbackMessage != nil }
        model.seek(toMs: 18_000)
        try await eventually("无确认样本请求已送出") { controller.pendingTargets.contains(18_000) }
        controller.completeSeek(18_000, publishesPosition: false)
        try await eventually("无新seq不可无限保留目标") { model.pendingSeek == nil && model.playbackMessage != nil }
        model.seek(toMs: 19_000)
        try await eventually("会话切换前请求已送出") { controller.pendingTargets.contains(19_000) }
        var nextSession = controller.snapshot()
        nextSession.sessionEpoch += 1
        nextSession.seq += 1
        controller.publish(nextSession)
        try await eventually("会话变化应清掉目标") { model.snapshot.sessionEpoch == nextSession.sessionEpoch && model.pendingSeek == nil }
        controller.completeSeek(19_000, error: .unauthorized)
        model.seek(toMs: 20_000)
        try await eventually("权限失败请求已送出") { controller.pendingTargets.contains(20_000) }
        controller.completeSeek(20_000, error: .unauthorized)
        try await eventually("权限失败应清目标") { model.setup == .automationDenied && model.pendingSeek == nil }
        print("PASS 连续 seek 序号、切歌 epoch、拖动跨曲目保护")

        model.isImportPresented = true
        model.isLyricsEditorPresented = true
        model.isLyricsEditorPresented = false
        precondition(panel.isAutoScrollSuspended, "导入仍打开时不得提前恢复自动滚动")
        panel.resumeFollowing()
        precondition(panel.browseMode == .manual, "编辑或导入期间不得抢回歌词")
        model.isImportPresented = false
        precondition(!panel.isAutoScrollSuspended, "全部弹层关闭后恢复计时资格")
        print("PASS 导入和编辑的共同滚动挂起")
        var unavailable = initial
        unavailable.status = .noTrack
        unavailable.positionMs = nil
        controller.publish(unavailable)
        model.seek(toMs: 16_000, expectedSnapshot: unavailable)
        try await Task.sleep(for: .milliseconds(20))
        precondition(controller.pendingTargets.isEmpty, "无曲目时不得发出 seek")
        var anonymousTrack = initial
        anonymousTrack.trackRef = nil
        precondition(AppModel.canSeek(anonymousTrack, isMock: true), "无强标识但时间有效的曲目仍可跳转")
        let productionMock = MockPlaybackController()
        productionMock.setMockQueue([MockTrack(identity: CatalogIdentity(storefront: "test", catalogSongId: "seek-handoff"),
                                                title: "原创跳转测试", durationMs: 30_000, trackRef: initial.trackKey)])
        try await productionMock.pause()
        let mockModel = AppModel(isMock: true, controller: productionMock, searchService: nil,
                                 makeLyricsDatabase: { LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: URL(fileURLWithPath: "/tmp")) })
        await mockModel.start()
        try await eventually("生产Mock应关联原创歌词") { mockModel.lyricsPanel?.currentDocumentId == document.id }
        mockModel.lyricsPanel?.enterManualBrowsing()
        mockModel.seek(toMs: 11_000)
        try await eventually("生产Mock的seq=0读回应清目标并恢复歌词跟随") {
            mockModel.snapshot.seq == 0 && mockModel.snapshot.positionMs == 11_000 && mockModel.pendingSeek == nil
                && mockModel.lyricsPanel?.browseMode == .follow
        }
        precondition(mockModel.playbackMessage == nil, "生产Mock不得被误报无确认样本")
        try await checkAutoReturn(store: store, document: document, snapshot: initial)
        try await checkLyricsMenuActions(store: store, document: document, snapshot: initial)
        checkNativeScroll()
        try await checkLyricsRowInteraction()
        try await checkContinuousPlayback(store: store)
        try await LyricsMotionUICheck.run()
        try await PlaybackProgressUICheck.runChecks()
        try await PlaybackOptionsUICheck.runChecks()
        try await checkPlaybackDragging(store: store, snapshot: initial)
        fflush(nil)
        print("App player UI checks: AUTOMATED_PASS（未执行真实 Music 验证）")
    }
}
