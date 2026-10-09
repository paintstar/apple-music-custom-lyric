import AppKit
import Foundation
import SwiftUI
import ShinAppleKit
import ShinAppleData
import ShinAppServices
import ShinLyricsEngine

private final class FloatingCheckSubscription: PlaybackSubscriptionHandle, @unchecked Sendable {
    let cancelHandler: @Sendable () -> Void
    init(_ cancelHandler: @escaping @Sendable () -> Void) { self.cancelHandler = cancelHandler }
    func cancel() { cancelHandler() }
}

/// 命令不控制系统播放器；快照只由检查程序明确发布。
private final class FloatingCheckController: PlaybackController, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PlaybackSnapshot
    private var handlers: [UUID: @Sendable (PlaybackSnapshot) -> Void] = [:]
    init(_ current: PlaybackSnapshot) { self.current = current }
    var subscriberCount: Int { lock.withLock { handlers.count } }
    func snapshot() -> PlaybackSnapshot { lock.withLock { current } }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return FloatingCheckSubscription { [weak self] in
            _ = self?.lock.withLock { self?.handlers.removeValue(forKey: id) }
        }
    }
    func publish(_ snapshot: PlaybackSnapshot) {
        let callbacks = lock.withLock { current = snapshot; return Array(handlers.values) }
        callbacks.forEach { $0(snapshot) }
    }
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func seek(positionMs: Int64) async throws {}
    func dispose() { lock.withLock { handlers.removeAll() } }
}

private struct FloatingFixture {
    let first = LyricDocument(sourceLanguage: "en", sourceOffsetMs: 100, lines: [
        LyricLine(startMs: 1_000,
                  text: "A paper lantern follows the river, carrying our quiet wishes past the garden and toward a new morning.",
                  translations: ["zh-Hans": Translation(text: "纸灯沿着河流漂远，带着安静的心愿经过花园，迎向新的清晨。")]),
        LyricLine(startMs: 1_000, text: "We fold another little boat.",
                  translations: ["zh-Hans": Translation(text: "我们再折一只小纸船。", needsReview: true)]),
        LyricLine(startMs: 5_000, text: ""),
        LyricLine(startMs: 10_000,
                  text: "The garden wakes with gentle rain. We leave another paper boat beside the gate, then walk along the river while the lanterns paint quiet circles on the water and the morning opens every small window in the village.",
                  translations: ["zh-Hans": Translation(text: "花园在细雨中醒来。我们把另一只纸船放在门边，沿河慢慢行走。灯光在水面画出安静的圆，清晨推开村里每一扇小窗。")])
    ])
    let second = LyricDocument(lines: [LyricLine(startMs: 0, text: "另一张纸船写着新的故事")])
    let firstKey = SongBinding.trackKey(persistentID: "A000000000000091")
    let secondKey = SongBinding.trackKey(persistentID: "A000000000000092")

    func save(to store: GRDBLyricsStore) async throws {
        try await store.save(document: first,
                             binding: SongBinding(persistentID: "A000000000000091", lyricDocumentId: first.id,
                                                  userDelayMs: 200))
        try await store.save(document: second,
                             binding: SongBinding(persistentID: "A000000000000092", lyricDocumentId: second.id))
    }

    func snapshot(position: Int64? = 1_500, status: PlayerStatus = .playing, second: Bool = false,
                  epoch: Int = 1, seq: Int = 1) -> PlaybackSnapshot {
        PlaybackSnapshot(trackEpoch: epoch, title: second ? "原创纸船二" : "原创纸灯一",
                         positionMs: position, durationMs: 30_000, status: status, seq: seq,
                         sessionEpoch: 1, trackRef: second ? secondKey : firstKey)
    }
}

private struct FloatingToggleFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

@MainActor private final class FloatingToggleFrameProbe {
    var frame = CGRect.zero
}

@main
private struct FloatingLyricsUICheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await runChecks()
                fflush(nil)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("FAIL: 悬浮歌词检查失败：\(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func runChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shin-floating-data-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ShinApple.FloatingCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let fixture = FloatingFixture()
        try await fixture.save(to: store)
        try await checkProjection(store: store, fixture: fixture)
        checkGeometry()
        checkResizeGeometry()
        try await checkWindowAndLifecycle(store: store, directory: directory, fixture: fixture, defaults: defaults)
    }

    @MainActor private static func eventually(_ message: @autoclosure () -> String, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fflush(nil)
        preconditionFailure(message())
    }

    @MainActor private static func presentation(
        _ panel: LyricsPanelModel, _ coordinator: PlaybackLyricsCoordinator,
        _ snapshot: PlaybackSnapshot, translations: Bool = true
    ) -> FloatingLyricsPresentation {
        FloatingLyricsPresentation.resolve(snapshot: snapshot, panel: panel,
                                           display: coordinator.currentDisplay(), showsTranslations: translations)
    }

    @MainActor private static func checkProjection(store: GRDBLyricsStore, fixture: FloatingFixture) async throws {
        let panel = LyricsPanelModel(store: store)
        let coordinator = PlaybackLyricsCoordinator(onDisplayChange: { _ in })
        var snapshot = fixture.snapshot()
        coordinator.update(snapshot: snapshot)
        panel.attach(coordinator: coordinator)
        await panel.refresh(trackKey: snapshot.trackKey, trackEpoch: snapshot.trackEpoch)
        let initial = presentation(panel, coordinator, snapshot)
        guard case let .current(lines) = initial else { preconditionFailure("当前同组歌词应显示") }
        precondition(lines.map(\.id) == Array(fixture.first.lines.prefix(2)).map(\.id))
        precondition(lines[0].text == fixture.first.lines[0].text && lines[0].translation != nil)
        precondition(lines[1].translationNeedsReview, "人工译文待复核标记不能丢失")
        guard case let .current(hidden) = presentation(panel, coordinator, snapshot, translations: false) else {
            preconditionFailure("关闭译文不能影响原文")
        }
        precondition(hidden.allSatisfy { $0.translation == nil && !$0.translationNeedsReview })
        panel.enterManualBrowsing()
        panel.setAutoScrollSuspended(true)
        snapshot = fixture.snapshot(position: 11_000, seq: 2)
        coordinator.update(snapshot: snapshot)
        panel.apply(display: coordinator.currentDisplay())
        guard case let .current(followed) = presentation(panel, coordinator, snapshot) else {
            preconditionFailure("主窗手动浏览与编辑不能挂起浮窗同步")
        }
        precondition(followed.map(\.id) == [fixture.first.lines[3].id])
        snapshot.status = .paused
        coordinator.update(snapshot: snapshot)
        let paused = presentation(panel, coordinator, snapshot)
        try await Task.sleep(for: .milliseconds(30))
        precondition(presentation(panel, coordinator, snapshot) == paused, "暂停应冻结并保留当前句")
        checkWaitingAndUnknown(panel: panel, coordinator: coordinator, fixture: fixture)
        try await checkTrackChanges(panel: panel, coordinator: coordinator, fixture: fixture)
        print("PASS 当前多行、原文译文、待复核、主窗手动/编辑隔离、暂停、等待、未知位置与切歌")
    }

    @MainActor private static func checkWaitingAndUnknown(
        panel: LyricsPanelModel, coordinator: PlaybackLyricsCoordinator, fixture: FloatingFixture
    ) {
        for position: Int64 in [300, 7_000] {
            let snapshot = fixture.snapshot(position: position)
            coordinator.update(snapshot: snapshot)
            guard case let .waiting(interval) = presentation(panel, coordinator, snapshot) else {
                preconditionFailure("前奏与明确空白段应复用等待区间")
            }
            precondition(interval.nextLineId == fixture.first.lines[position < 1_000 ? 0 : 3].id)
            precondition(position >= interval.startMs && position < interval.endMs)
        }
        let valid = coordinator.currentDisplay()
        for position: Int64? in [nil, -1] {
            let result = FloatingLyricsPresentation.resolve(snapshot: fixture.snapshot(position: position), panel: panel,
                                                           display: valid, showsTranslations: true)
            guard case .message = result else { preconditionFailure("未知或负位置不能冒充 0") }
        }
        let ended = fixture.snapshot(position: 30_000, status: .ended)
        coordinator.update(snapshot: ended)
        guard case .message = presentation(panel, coordinator, ended) else { preconditionFailure("曲末不能假倒计时") }
        let cleared = PlaybackLyricsDisplay(content: .cleared(startMs: 5_100), userDelayMs: 200)
        let unknownIDs = PlaybackLyricsDisplay(content: .current(lineIds: [UUID()]), userDelayMs: 200)
        for display in [cleared, unknownIDs] {
            guard case .message = FloatingLyricsPresentation.resolve(snapshot: fixture.snapshot(position: 7_000),
                                                                    panel: panel, display: display,
                                                                    showsTranslations: true) else {
                preconditionFailure("无下一句清屏和不属于文档的行不能展示旧内容")
            }
        }
    }

    @MainActor private static func checkTrackChanges(
        panel: LyricsPanelModel, coordinator: PlaybackLyricsCoordinator, fixture: FloatingFixture
    ) async throws {
        let oldDisplay = PlaybackLyricsDisplay(content: .current(lineIds: [fixture.first.lines[0].id]), userDelayMs: 200)
        let next = fixture.snapshot(position: 400, second: true, epoch: 2, seq: 5)
        guard case .message = FloatingLyricsPresentation.resolve(snapshot: next, panel: panel, display: oldDisplay,
                                                                showsTranslations: true) else {
            preconditionFailure("切歌查询未返回前必须清除旧句")
        }
        coordinator.update(snapshot: next)
        await panel.refresh(trackKey: next.trackKey, trackEpoch: next.trackEpoch)
        let confirmed = presentation(panel, coordinator, next)
        coordinator.applyLyrics(trackKey: fixture.firstKey, trackEpoch: 1, document: fixture.first, userDelayMs: 200)
        precondition(presentation(panel, coordinator, next) == confirmed, "迟到的上一曲结果不能倒灌")
        guard case let .current(lines) = confirmed else { preconditionFailure("新曲目应完成装载") }
        precondition(lines.map(\.id) == fixture.second.lines.map(\.id))
        var replay = next
        replay.trackEpoch += 1
        guard case .message = presentation(panel, coordinator, replay) else {
            preconditionFailure("同曲目新生命周期不能使用旧epoch文档")
        }
        coordinator.update(snapshot: replay)
        await panel.refresh(trackKey: replay.trackKey, trackEpoch: replay.trackEpoch)
        precondition(panel.displayedTrackEpoch == replay.trackEpoch)
        let unavailable = LyricsPanelModel(store: nil)
        guard case .message = FloatingLyricsPresentation.resolve(snapshot: replay, panel: unavailable,
                                                                display: .empty, showsTranslations: true) else {
            preconditionFailure("不可用歌词库需要明确提示")
        }
    }

    @MainActor private static func checkGeometry() {
        let screens = [NSRect(x: 0, y: 0, width: 1_280, height: 800),
                       NSRect(x: 1_280, y: -100, width: 1_920, height: 1_080)]
        let second = NSRect(x: 1_440, y: 150, width: 640, height: 200)
        precondition(FloatingLyricsWindowGeometry.constrained(second, visibleFrames: screens) == second,
                     "有效的副屏位置应保留")
        for invalid in [NSRect(x: 90_000, y: 90_000, width: 900, height: 220),
                        NSRect(x: CGFloat.nan, y: 0, width: CGFloat.infinity, height: -20),
                        NSRect(x: -600, y: -500, width: 8_000, height: 8_000)] {
            let fixed = FloatingLyricsWindowGeometry.constrained(invalid, visibleFrames: screens)
            precondition(fixed.minX.isFinite && fixed.minY.isFinite && fixed.width.isFinite && fixed.height.isFinite)
            precondition(screens.contains { $0.contains(fixed) }, "无效/断开显示器位置应修正到完整可见")
        }
        let missing = FloatingLyricsWindowGeometry.initialFrame(visibleFrames: [])
        precondition(missing.width > 0 && missing.height > 0 && missing.minX.isFinite && missing.minY.isFinite)
        print("PASS 副屏位置保留、断屏/无效矩形修正与无显示器回退")
    }

    @MainActor private static func checkWindowAndLifecycle(
        store: GRDBLyricsStore, directory: URL, fixture: FloatingFixture, defaults: UserDefaults
    ) async throws {
        let player = FloatingCheckController(fixture.snapshot(status: .paused))
        let model = AppModel(isMock: true, controller: player, searchService: nil, makeLyricsDatabase: {
            LyricsDatabase.Database(store: store, locationDescription: "隔离的原创检查资料", directory: directory)
        })
        await model.start()
        try await eventually("暂停时关联结果也应更新浮窗") { model.lyricsPanel?.currentDocumentId == fixture.first.id }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        defaults.set(NSStringFromRect(NSRect(x: 90_000, y: 90_000, width: 900, height: 200)),
                     forKey: FloatingLyricsWindowController.framePreferenceKey)
        let floating = FloatingLyricsWindowController(defaults: defaults, visibleFrames: { [visible] })
        defer { floating.close() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let wasActive = NSApplication.shared.isActive
        let keyWindow = NSApplication.shared.keyWindow
        floating.show(model: model)
        try await eventually("浮窗应显示") { floating.isPresented && floating.window?.isVisible == true }
        guard let panel = floating.window else { preconditionFailure("浮窗必须使用独立panel") }
        precondition(panel.level == .floating && panel.styleMask.contains(.nonactivatingPanel))
        precondition(visible.contains(panel.frame), "离屏偏好必须修正")
        precondition(NSApplication.shared.isActive == wasActive && NSApplication.shared.keyWindow === keyWindow,
                     "展示浮窗不得抢应用激活状态或键盘焦点")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
                     "后台展示浮窗不得切换前台应用")
        for _ in 0..<4 {
            floating.toggle(model: model)
            precondition(!floating.isPresented && !panel.isVisible)
            floating.toggle(model: model)
            precondition(floating.isPresented && floating.window === panel && panel.isVisible)
        }
        var initialFrame = panel.frame
        initialFrame.size = FloatingLyricsWindowGeometry.defaultSize
        panel.setFrame(initialFrame, display: true)
        try await saveScreenshot(panel, name: "floating-lyrics-initial-original.png")
        try await checkBottomToggle(floating, model: model, player: player, fixture: fixture,
                                    visible: visible, defaults: defaults)
        await model.start()
        precondition(player.subscriberCount == 1, "浮窗反复开关不能增建采样订阅")
        try await checkIndependentScrolling(panel, model: model, player: player, fixture: fixture, defaults: defaults)
        try await checkNativeResize(panel)
        let main = NSWindow(contentRect: NSRect(x: visible.minX + 20, y: visible.minY + 20, width: 420, height: 240),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentView = NSHostingView(rootView: Text("原创检查主窗口").defaultAppStorage(defaults))
        main.makeKeyAndOrderFront(nil)
        try await eventually("主窗准备超时：key=\(main.isKeyWindow)，visible=\(main.isVisible)") {
            main.isKeyWindow && main.isVisible
        }
        main.miniaturize(nil)
        player.publish(fixture.snapshot(position: 11_000, seq: 2))
        try await eventually("主窗最小化检查超时：minimized=\(main.isMiniaturized)，floatingVisible=\(panel.isVisible)，"
                             + "expectedLyrics=\(currentIDs(model) == [fixture.first.lines[3].id])") {
            main.isMiniaturized && panel.isVisible && currentIDs(model) == [fixture.first.lines[3].id]
        }
        main.contentView = nil
        main.close()
        model.lyricsPanel?.enterManualBrowsing()
        model.isLyricsEditorPresented = true
        player.publish(fixture.snapshot(position: 1_600, status: .paused, seq: 3))
        try await eventually("主窗销毁、手动浏览和编辑挂起后浮窗仍应更新") {
            currentIDs(model) == Array(fixture.first.lines.prefix(2)).map(\.id)
        }
        var screenshotFrame = panel.frame
        screenshotFrame.size = FloatingLyricsWindowGeometry.defaultSize
        panel.setFrame(screenshotFrame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        try await saveScreenshot(panel)
        let rememberedFrame = panel.frame
        // 无标题栏panel的关闭出口经控制器；原生close同样必须经delegate同步按钮状态。
        panel.close()
        try await eventually("窗口关闭需同步开关状态") { !floating.isPresented && !panel.isVisible }
        floating.close()
        floating.close()
        precondition(!floating.isPresented)
        let stored = defaults.string(forKey: FloatingLyricsWindowController.framePreferenceKey) ?? ""
        precondition(NSRectFromString(stored) == rememberedFrame, "关闭应记住实际窗口位置与尺寸")
        let restored = FloatingLyricsWindowController(defaults: defaults, visibleFrames: { [visible] })
        restored.show(model: model)
        precondition(restored.window?.frame == rememberedFrame, "新控制器应从隔离偏好恢复窗口位置")
        restored.close()
        print("PASS 独立唯一窗口、开关/关闭同步、背景焦点、暂停初始化、主窗最小化/销毁及长句双语")
    }

    @MainActor private static func checkBottomToggle(
        _ controller: FloatingLyricsWindowController, model: AppModel, player: FloatingCheckController,
        fixture: FloatingFixture, visible: NSRect, defaults: UserDefaults
    ) async throws {
        let probe = FloatingToggleFrameProbe()
        let control = FloatingLyricsToggleButton(controller: controller, model: model)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: FloatingToggleFramePreference.self,
                                           value: geometry.frame(in: .named("floating-check-bar")))
                }
            }
        let host = NSHostingView(rootView: PlayerBarView(
            artworkStore: model.artworkStore, availableWidth: PlayerBarView.maximumWidth,
            floatingLyricsControl: AnyView(control)
        ).environmentObject(model).defaultAppStorage(defaults).environment(\.colorScheme, .dark).padding(20)
            .coordinateSpace(name: "floating-check-bar")
            .onPreferenceChange(FloatingToggleFramePreference.self) { frame in
                Task { @MainActor in probe.frame = frame }
            })
        let window = NSWindow(contentRect: NSRect(x: visible.minX + 20, y: visible.maxY - 160,
                                                width: 760, height: 140),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await saveScreenshot(window, name: "floating-lyrics-bottom-bar-original.png")
        try await eventually("底栏按钮应完成实际布局并能接收点击") {
            host.layoutSubtreeIfNeeded()
            return window.isKeyWindow && probe.frame.width > 0 && probe.frame.height > 0
        }
        try await clickButton(frame: probe.frame, host: host, window: window)
        try await eventually("底栏实际点击应关闭浮窗") { !controller.isPresented && controller.window?.isVisible == false }
        try await clickButton(frame: probe.frame, host: host, window: window)
        try await eventually("底栏实际点击应重新开启浮窗") { controller.isPresented && controller.window?.isVisible == true }
        guard let panel = controller.window else { preconditionFailure("锁定检查需要已显示浮窗") }
        controller.setLocked(true)
        precondition(controller.isLocked && panel.ignoresMouseEvents, "锁定必须使用系统整窗鼠标穿透")
        player.publish(fixture.snapshot(position: 11_000, status: .paused, seq: 4))
        try await eventually("锁定后歌词仍应随已有播放快照更新") {
            currentIDs(model) == [fixture.first.lines[3].id]
        }
        let lockedBitmap = try await visibleTextBitmap(panel)
        precondition(hasClearToolbar(lockedBitmap), "锁态不得留下悬浮工具或背景遮挡")
        try await saveScreenshot(panel, name: "floating-lyrics-locked-original.png")
        try await clickButton(frame: probe.frame, host: host, window: window)
        try await eventually("底栏首击只解锁并保持浮窗显示") {
            !controller.isLocked && !panel.ignoresMouseEvents && controller.isPresented && panel.isVisible
        }
        controller.setLocked(true)
        controller.close()
        precondition(!controller.isLocked, "关闭锁态浮窗应重置锁定")
        controller.show(model: model)
        precondition(!controller.isLocked && !panel.ignoresMouseEvents && panel.isVisible,
                     "关闭重开必须恢复鼠标操作")
        player.publish(fixture.snapshot(position: 1_500, status: .paused, seq: 5))
        try await eventually("恢复第一组供后续检查") {
            currentIDs(model) == Array(fixture.first.lines.prefix(2)).map(\.id)
        }
        try await saveScreenshot(window, name: "floating-lyrics-bottom-bar-original.png")
        print("PASS 实际底栏开关、整窗鼠标穿透、锁态同步/无遮挡、首击解锁与关闭恢复")
    }

    @MainActor private static func clickButton(frame: CGRect, host: NSView, window: NSWindow) async throws {
        let point = NSPoint(x: frame.midX, y: host.isFlipped ? frame.midY : host.bounds.height - frame.midY)
        precondition(host.bounds.contains(point), "测试按钮位置应来自实际host布局")
        let event: @MainActor @Sendable (NSEvent.EventType) -> NSEvent = { type in
            let value = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            precondition(value.window === window, "鼠标事件必须只属于本次检查窗口")
            return value
        }
        let release = Timer(timeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.postEvent(event(.leftMouseUp), atStart: false) }
        }
        RunLoop.main.add(release, forMode: .common)
        RunLoop.main.add(release, forMode: .eventTracking)
        NSApplication.shared.postEvent(event(.leftMouseDown), atStart: false)
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor private static func checkIndependentScrolling(
        _ window: NSWindow, model: AppModel, player: FloatingCheckController,
        fixture: FloatingFixture, defaults: UserDefaults
    ) async throws {
        var frame = window.frame
        frame.size = NSSize(width: 420, height: 180)
        window.setFrame(frame, display: true)
        defaults.set(true, forKey: LyricsPanelView.translationsSettingKey)
        try await eventually("双语长句应可独立滚动") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let scroll = findScrollView(window.contentView), let document = scroll.documentView else { return false }
            return document.frame.height > scroll.contentView.bounds.height + 30
        }
        guard let scroll = findScrollView(window.contentView), let document = scroll.documentView else {
            preconditionFailure("悬浮长句需要实际滚动视图")
        }
        let originalMode = model.lyricsPanel?.browseMode
        let translatedHeight = document.frame.height
        defaults.set(false, forKey: LyricsPanelView.translationsSettingKey)
        try await eventually("注入的翻译偏好应只影响测试浮窗") {
            window.contentView?.layoutSubtreeIfNeeded()
            return document.frame.height < translatedHeight - 10
        }
        defaults.set(true, forKey: LyricsPanelView.translationsSettingKey)
        try await eventually("恢复译文后应保持长句可滚动") {
            window.contentView?.layoutSubtreeIfNeeded()
            return document.frame.height >= translatedHeight - 1
        }
        let before = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: before.x, y: before.y + 50))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.contentView.bounds.minY > before.y + 20, "用户应能滚动阅读长句")
        precondition(model.lyricsPanel?.browseMode == originalMode, "浮窗滚动不得修改主窗浏览模式")
        player.publish(fixture.snapshot(position: 11_000, status: .paused, seq: 7))
        try await eventually("换到下一组长句应复位到首行") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard currentIDs(model) == [fixture.first.lines[3].id] else { return false }
            return abs(scroll.contentView.bounds.minY - before.y) < 1
        }
        precondition(document.frame.height > scroll.contentView.bounds.height + 30,
                     "下一组也应足够长，不能只依赖短内容收缩把滚动夹回顶部")
        player.publish(fixture.snapshot(position: 1_500, status: .paused, seq: 8))
        try await eventually("恢复第一组供窗口生命周期检查") {
            currentIDs(model) == Array(fixture.first.lines.prefix(2)).map(\.id)
        }
        print("PASS 长句独立滚动、测试域译文开关及换组复位")
    }

    @MainActor private static func findScrollView(_ view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScrollView).first
    }

    @MainActor private static func checkResizeGeometry() {
        typealias Geometry = FloatingLyricsResizeGeometry
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 180)
        let initial = NSRect(x: 300, y: 250, width: 400, height: 200)
        let screen = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let minimum = FloatingLyricsWindowGeometry.minimumSize
        let limits = Geometry.Limits(minimumSize: minimum, maximumSize: NSSize(width: 650, height: 400),
                                     visibleFrame: screen)
        precondition(Geometry.handle(at: NSPoint(x: bounds.midX, y: bounds.midY), in: bounds) == nil,
                     "歌词中心不能成为缩放命中区")
        for edge in Geometry.Edge.allCases {
            let region = Geometry.region(for: edge, in: bounds)
            precondition(Geometry.handle(at: NSPoint(x: region.midX, y: region.midY), in: bounds) == edge,
                         "四边角的宽命中带必须可抓取")
            let dx: CGFloat
            let dy: CGFloat
            switch edge {
            case .left: (dx, dy) = (-1, 0)
            case .right: (dx, dy) = (1, 0)
            case .top: (dx, dy) = (0, 1)
            case .bottom: (dx, dy) = (0, -1)
            case .topLeft: (dx, dy) = (-1, 1)
            case .topRight: (dx, dy) = (1, 1)
            case .bottomLeft: (dx, dy) = (-1, -1)
            case .bottomRight: (dx, dy) = (1, -1)
            }
            for scale: CGFloat in [30, -10_000, 10_000] {
                let changed = Geometry.resizedFrame(initial: initial, delta: NSSize(width: dx * scale, height: dy * scale),
                                                    edge: edge, limits: limits)
                precondition(screen.contains(changed) && changed.width >= minimum.width && changed.height >= minimum.height)
                precondition(changed.width <= limits.maximumSize.width && changed.height <= limits.maximumSize.height)
                if dx < 0 { precondition(changed.maxX == initial.maxX, "左侧缩放必须固定右侧") }
                if dx > 0 { precondition(changed.minX == initial.minX, "右侧缩放必须固定左侧") }
                if dy < 0 { precondition(changed.maxY == initial.maxY, "下侧缩放必须固定上侧") }
                if dy > 0 { precondition(changed.minY == initial.minY, "上侧缩放必须固定下侧") }
                if scale < 0 {
                    if dx != 0 { precondition(changed.width == minimum.width) }
                    if dy != 0 { precondition(changed.height == minimum.height) }
                }
            }
        }
        print("PASS 四边角宽带命中、中心放行、对侧锚点及最小/最大/屏幕缩放约束")
    }

    @MainActor private static func checkNativeResize(_ window: NSWindow) async throws {
        try await eventually("原生缩放区应挂载") {
            window.contentView?.layoutSubtreeIfNeeded()
            return findResizeView(window.contentView)?.bounds.width == window.contentView?.bounds.width
        }
        guard let view = findResizeView(window.contentView) else { preconditionFailure("缺少原生缩放区") }
        let initial = window.frame
        let band = FloatingLyricsResizeGeometry.hitWidth / 2
        let point = NSPoint(x: view.bounds.maxX - band, y: view.bounds.midY)
        precondition(view.hitTest(view.convert(point, to: view.superview)) === view, "宽边中心应命中原生缩放区")
        precondition(view.hitTest(view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: view.superview)) == nil,
                     "中心须保留歌词滚动和点击")
        view.isEnabled = false
        precondition(view.hitTest(view.convert(point, to: view.superview)) == nil, "禁用后缩放区不可拦截")
        view.isEnabled = true
        let start = window.convertPoint(toScreen: view.convert(point, to: nil))
        let end = NSPoint(x: start.x + 40, y: start.y)
        let event: @MainActor (NSEvent.EventType, NSPoint) -> NSEvent = { type, location in
            let value = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: location),
                                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            precondition(value.window === window, "缩放事件必须只属于本次浮窗")
            return value
        }
        window.sendEvent(event(.leftMouseDown, start))
        window.sendEvent(event(.leftMouseDragged, end))
        window.sendEvent(event(.leftMouseUp, end))
        precondition(abs(window.frame.width - initial.width - 40) < 1 && window.frame.minX == initial.minX,
                     "实际原生边缘拖拽应增宽且保持对侧锚点")
        window.setFrame(initial, display: true)
        print("PASS 原生宽边命中、锁态放行、中心不拦截与实际鼠标拖拽缩放")
    }

    @MainActor private static func findResizeView(_ view: NSView?) -> FloatingLyricsResizeRegion.ResizeView? {
        guard let view else { return nil }
        if let resize = view as? FloatingLyricsResizeRegion.ResizeView { return resize }
        return view.subviews.lazy.compactMap(findResizeView).first
    }

    private static func hasClearToolbar(_ bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<max(1, bitmap.pixelsHigh / 10) {
            for x in (bitmap.pixelsWide / 10)..<(bitmap.pixelsWide * 9 / 10) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { return false }
            }
        }
        return true
    }

    @MainActor private static func currentIDs(_ model: AppModel) -> [UUID]? {
        let value = FloatingLyricsPresentation.resolve(snapshot: model.snapshot, panel: model.lyricsPanel,
                                                      display: model.lyricsCoordinator?.currentDisplay() ?? .empty,
                                                      showsTranslations: true)
        if case let .current(lines) = value { return lines.map(\.id) }
        return nil
    }

    @MainActor private static func saveScreenshot(
        _ window: NSWindow, name: String = "floating-lyrics-original.png"
    ) async throws {
        let bitmap = try await visibleTextBitmap(window)
        guard let output = ProcessInfo.processInfo.environment["FLOATING_LYRICS_CHECK_OUTPUT"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("原创浮窗截图无法编码")
        }
        let path = directory.appendingPathComponent(name)
        try data.write(to: path)
        print("Mock 浮窗截图：\(path.path)")
    }

    /// SwiftUI图层可能晚于布局就绪；只在缓存里实际存在正文文字时接受截图。
    @MainActor private static func visibleTextBitmap(_ window: NSWindow) async throws -> NSBitmapImageRep {
        guard let view = window.contentView else { preconditionFailure("原创检查窗口没有内容视图") }
        for _ in 0..<200 {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            view.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                // 未绘制图层不能被未初始化内存误判成有效像素。
                bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if containsBodyText(bitmap) { return bitmap }
            }
            view.needsDisplay = true
            try await Task.sleep(for: .milliseconds(10))
        }
        fflush(nil)
        preconditionFailure("原创检查截图在时限内仍没有实际正文文字像素")
    }

    private static func containsBodyText(_ bitmap: NSBitmapImageRep) -> Bool {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return false }
        var textPixels = 0
        // 忽略顶部工具区和四周边缘；100个高亮像素避免仅关闭图标也被当成正文。
        for y in (height / 5)..<(height * 19 / 20) {
            for x in (width / 20)..<(width * 19 / 20) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.4,
                      min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 else { continue }
                textPixels += 1
                if textPixels >= 100 { return true }
            }
        }
        return false
    }
}
