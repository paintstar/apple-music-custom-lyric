import AppKit
import ApplicationServices
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

@MainActor private final class FloatingHoverProbe {
    var point = NSPoint(x: -90_000, y: -90_000)
    var time: TimeInterval = 100
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
        // 旧版的纵向间距 4 点不得迁移为新字距。
        defaults.set(4.0, forKey: "floatingLyrics.spacing")
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let fixture = FloatingFixture()
        try await fixture.save(to: store)
        let typographyOnly = ProcessInfo.processInfo.environment["SHIN_FLOATING_TYPOGRAPHY_CHECK_ONLY"] == "1"
            || ProcessInfo.processInfo.environment["SHIN_FLOATING_SETTINGS_SYNC_INTERACTIVE"] == "1"
        if !typographyOnly {
            try await checkProjection(store: store, fixture: fixture)
            checkGeometry()
            checkResizeGeometry()
            checkUnlockHover()
        }
        try await checkWindowAndLifecycle(store: store, directory: directory, fixture: fixture,
                                          defaults: defaults, typographyOnly: typographyOnly)
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
            if position < 1_000 {
                guard presentation(panel, coordinator, snapshot) == .message("") else {
                    preconditionFailure("不足 3 秒的短前奏不显示等待提示")
                }
                continue
            }
            guard case let .waiting(interval) = presentation(panel, coordinator, snapshot) else {
                preconditionFailure("明确长空白段应复用等待区间")
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
        store: GRDBLyricsStore, directory: URL, fixture: FloatingFixture, defaults: UserDefaults,
        typographyOnly: Bool
    ) async throws {
        let player = FloatingCheckController(fixture.snapshot(status: .paused))
        let model = AppModel(isMock: true, controller: player, searchService: nil, makeLyricsDatabase: {
            LyricsDatabase.Database(store: store, locationDescription: "隔离的原创检查资料", directory: directory)
        })
        await model.start()
        try await eventually("暂停时关联结果也应更新浮窗") { model.lyricsPanel?.currentDocumentId == fixture.first.id }
        if ProcessInfo.processInfo.environment["SHIN_FLOATING_SETTINGS_SYNC_INTERACTIVE"] == "1" {
            try await showSettingsSynchronizationFixture(model: model, defaults: defaults)
            return
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        defaults.set(NSStringFromRect(NSRect(x: 90_000, y: 90_000, width: 900, height: 200)),
                     forKey: FloatingLyricsWindowController.framePreferenceKey)
        let hoverProbe = FloatingHoverProbe()
        let floating = FloatingLyricsWindowController(defaults: defaults, visibleFrames: { [visible] },
                                                      mouseLocation: { hoverProbe.point },
                                                      monotonicTime: { hoverProbe.time })
        defer { floating.close() }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let wasActive = NSApplication.shared.isActive
        let keyWindow = NSApplication.shared.keyWindow
        floating.show(model: model)
        try await eventually("浮窗应显示") { floating.isPresented && floating.window?.isVisible == true }
        guard let panel = floating.window else { preconditionFailure("浮窗必须使用独立panel") }
        if typographyOnly {
            try await checkIndependentScrolling(panel, model: model, player: player, fixture: fixture, defaults: defaults)
            return
        }
        precondition(panel.level == .floating && panel.styleMask.contains(.nonactivatingPanel))
        precondition(panel.collectionBehavior.contains(.fullScreenNone)
                     && !panel.collectionBehavior.contains(.fullScreenAuxiliary), "悬浮窗不参与全屏")
        panel.toggleFullScreen(nil)
        precondition(!panel.styleMask.contains(.fullScreen), "悬浮窗不能进入原生全屏")
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
        try await checkTrackingAndFocus(panel)
        checkDetachedTrackingCleanup()
        try await saveScreenshot(panel, name: "floating-lyrics-initial-original.png")
        // 保留本检查自己的 key 窗，避免 accessory App 在关闭最后一扇主窗后异步失去激活。
        let bottomWindow = try await checkBottomToggle(floating, model: model, player: player, fixture: fixture,
                                                       visible: visible, defaults: defaults)
        defer { bottomWindow.close() }
        try await checkLockedHoverWindow(floating, model: model, probe: hoverProbe, defaults: defaults)
        await model.start()
        precondition(player.subscriberCount == 1, "浮窗反复开关不能增建采样订阅")
        try await checkIndependentScrolling(panel, model: model, player: player, fixture: fixture, defaults: defaults)
        try await checkNativeResize(panel)
        try await checkNativeDrag(floating, model: model)
        try await checkTrackingAfterResizeAndUnlock(floating)
        try await checkFloatingSettings(floating, model: model)
        let main = NSWindow(contentRect: NSRect(x: visible.minX + 20, y: visible.minY + 20, width: 420, height: 240),
                            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentView = NSHostingView(rootView: Text("原创检查主窗口").defaultAppStorage(defaults))
        // 本项显式准备可成为 key 的模拟主窗；此前的后台浮窗检查均已完成。
        NSApplication.shared.activate()
        main.makeKeyAndOrderFront(nil)
        try await eventually("主窗准备超时：key=\(main.isKeyWindow)，visible=\(main.isVisible)，appActive=\(NSApplication.shared.isActive)") {
            main.isKeyWindow && main.isVisible
        }
        bottomWindow.close()
        try await eventually("焦点已交给模拟主窗后，底栏夹具应关闭且主窗保持 key") {
            !bottomWindow.isVisible && main.isKeyWindow
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

    /// 供外部 GUI 工具操作原有 Stepper；不复制绑定实现，也不直接写入字号或字距。
    @MainActor private static func showSettingsSynchronizationFixture(model: AppModel, defaults: UserDefaults) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "原创夹具：悬浮歌词设置双向同步"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            Text("左侧改为 27 点 / 0.5 点并核对右侧；右侧改为 28 点 / 1 点并核对左侧；最后恢复 26 点 / 0 点，核对两侧后关闭窗口。")
                .font(.callout).padding(12)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                SettingsPageView(bottomContentInset: 0).environmentObject(model)
                Divider()
                FloatingLyricsSettingsPopover(model: model, onFetch: {}, onImport: {})
            }
        }.defaultAppStorage(defaults))
        window.center()
        defer { window.close() }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        print("INFO 双向同步交互夹具已就绪：真实主设置与浮窗设置共用隔离偏好；请通过控件与两侧标签核对，关闭窗口结束。")
        fflush(nil)
        while window.isVisible { try await Task.sleep(for: .milliseconds(250)) }
        print("INFO 交互夹具已关闭；双向同步是否通过应由外部 GUI 的真实控件与标签核对结果确认。")
    }

    private static func checkUnlockHover() {
        var hover = FloatingLyricsUnlockHover()
        precondition(!hover.shouldShow(isInside: true, time: 10, delay: 3))
        precondition(!hover.shouldShow(isInside: true, time: 12.99, delay: 3))
        precondition(hover.shouldShow(isInside: true, time: 13, delay: 3), "持续悬浮默认 3 秒显示锁标志")
        precondition(!hover.shouldShow(isInside: false, time: 14, delay: 3))
        precondition(!hover.shouldShow(isInside: true, time: 14.1, delay: 3), "移出后重新计时")
        precondition(hover.shouldShow(isInside: true, time: 14.7, delay: 0.5), "设置降低立即使用已有持续悬浮时间")
        precondition(!hover.shouldShow(isInside: true, time: 14.7, delay: 10), "增加等待时长立即生效")
        hover.reset()
        precondition(!hover.shouldShow(isInside: true, time: 20, delay: 0.5), "解锁或关闭不能保留旧计时")
        precondition(!hover.shouldShow(isInside: true, time: 19, delay: 0.5), "无效的时钟倒退重新计时")
        precondition(FloatingLyricsUnlockSettings.normalized(.nan) == 3)
        precondition(FloatingLyricsUnlockSettings.normalized(-1) == FloatingLyricsUnlockSettings.delayRange.lowerBound)
        print("PASS 连续悬浮 3 秒、移出复位、动态等待、生命周期复位与无效偏好")
    }

    @MainActor private static func checkLockedHoverWindow(
        _ controller: FloatingLyricsWindowController, model: AppModel,
        probe: FloatingHoverProbe, defaults: UserDefaults
    ) async throws {
        guard let panel = controller.window else { preconditionFailure("悬浮解锁检查需要歌词窗") }
        let appWasActive = NSApplication.shared.isActive
        let keyWindow = NSApplication.shared.keyWindow
        probe.point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        controller.setLocked(true)
        probe.time = 102.9
        try await Task.sleep(for: .milliseconds(150))
        precondition(controller.unlockWindow?.isVisible != true, "未满 3 秒不能显示锁标志")
        probe.time = 103
        try await eventually("悬浮满 3 秒应显示解锁标志") { controller.unlockWindow?.isVisible == true }
        guard let button = controller.unlockWindow else { preconditionFailure("解锁标志需要独立小窗") }
        precondition(panel.frame.contains(button.frame) && button.frame.width <= 40 && button.frame.height <= 40,
                     "只有锁标志区域接收鼠标，不遮挡整块歌词")
        precondition(panel.ignoresMouseEvents && !panel.isMovable && !panel.isMovableByWindowBackground)
        precondition(!button.ignoresMouseEvents && !button.canBecomeKey && !button.canBecomeMain)
        precondition(NSApplication.shared.isActive == appWasActive && NSApplication.shared.keyWindow === keyWindow,
                     "出现锁标志不能激活 App 或切换键盘焦点；beforeActive=\(appWasActive), "
                     + "afterActive=\(NSApplication.shared.isActive), keyBefore=\(keyWindow?.windowNumber ?? -1), "
                     + "keyAfter=\(NSApplication.shared.keyWindow?.windowNumber ?? -1)")
        probe.point = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        try await eventually("移出应隐藏锁标志") { !button.isVisible }
        probe.point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        probe.time = 200
        try await Task.sleep(for: .milliseconds(150))
        probe.time = 201
        defaults.set(0.5, forKey: FloatingLyricsUnlockSettings.delayPreferenceKey)
        try await eventually("降低设置无需重锁，应立即显示锁标志") { button.isVisible }
        guard let host = button.contentView else { preconditionFailure("锁标志必须可实际点击") }
        host.layoutSubtreeIfNeeded()
        try await clickButton(frame: host.bounds, host: host, window: button)
        try await eventually("锁标志实际点击应解锁并保持歌词窗") {
            !controller.isLocked && !panel.ignoresMouseEvents && controller.isPresented && panel.isVisible
                && controller.unlockWindow == nil
        }
        controller.setLocked(true)
        controller.close()
        probe.time = 1_000
        try await Task.sleep(for: .milliseconds(150))
        precondition(controller.unlockWindow == nil && !controller.isPresented,
                     "关闭必须清理待显示锁标志与采样计时器")
        controller.show(model: model)
        precondition(!controller.isLocked && controller.unlockWindow == nil)
        defaults.removeObject(forKey: FloatingLyricsUnlockSettings.delayPreferenceKey)
        probe.point = NSPoint(x: panel.frame.maxX + 100, y: panel.frame.maxY + 100)
        print("PASS 小区域解锁标志、鼠标穿透/焦点保持、移出隐藏、设置即时生效、实际点击与关闭清理")
    }

    @MainActor private static func checkBottomToggle(
        _ controller: FloatingLyricsWindowController, model: AppModel, player: FloatingCheckController,
        fixture: FloatingFixture, visible: NSRect, defaults: UserDefaults
    ) async throws -> NSWindow {
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
        try await eventually("锁定恢复透明背景且系统 mouseDown 命中穿过歌词窗") {
            let point = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            return panel.backgroundColor.alphaComponent == 0
                && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) != panel.windowNumber
        }
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
        return window
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
        // 已知所属窗口的 down 直接走生产分发链，避免排队期间恢复 frame 改变系统坐标换算。
        // up 保留在事件队列，支持 AppKit 按钮内部的鼠标跟踪循环。
        window.sendEvent(event(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(100))
    }

    @MainActor private static func checkIndependentScrolling(
        _ window: NSWindow, model: AppModel, player: FloatingCheckController,
        fixture: FloatingFixture, defaults: UserDefaults
    ) async throws {
        precondition(FloatingLyricsSettings.defaultCharacterSpacing == 0
                     && FloatingLyricsSettings.normalizedCharacterSpacing(.nan) == 0
                     && FloatingLyricsSettings.normalizedCharacterSpacing(-1) == 0
                     && FloatingLyricsSettings.normalizedCharacterSpacing(9) == 8,
                     "字距默认 0 点，无效值回退并限制在 0–8 点")
        precondition(FloatingLyricsSettings.normalizedFontSize(.infinity) == 26
                     && FloatingLyricsSettings.normalizedFontSize(10) == 16
                     && FloatingLyricsSettings.normalizedFontSize(60) == 56,
                     "字号无效值回退并限制在 16–56 点")
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
        defaults.set(FloatingLyricsSettings.characterSpacingRange.upperBound,
                     forKey: FloatingLyricsSettings.characterSpacingPreferenceKey)
        try await eventually("仅浮窗字距偏好应立即增加长句换行高度") {
            window.contentView?.layoutSubtreeIfNeeded()
            return document.frame.height > translatedHeight + 20
        }
        defaults.set(FloatingLyricsSettings.defaultCharacterSpacing,
                     forKey: FloatingLyricsSettings.characterSpacingPreferenceKey)
        try await eventually("浮窗字距恢复 0 应恢复原视觉高度，旧纵向间距不得成为默认字距") {
            window.contentView?.layoutSubtreeIfNeeded()
            return abs(document.frame.height - translatedHeight) < 1
        }
        defaults.set(FloatingLyricsSettings.fontSizeRange.upperBound, forKey: FloatingLyricsSettings.fontSizePreferenceKey)
        try await eventually("仅浮窗字号偏好应立即增加长句可滚动高度") {
            window.contentView?.layoutSubtreeIfNeeded()
            return document.frame.height > translatedHeight + 30
        }
        defaults.set(FloatingLyricsSettings.defaultFontSize, forKey: FloatingLyricsSettings.fontSizePreferenceKey)
        try await eventually("浮窗字号恢复默认应恢复原视觉高度") {
            window.contentView?.layoutSubtreeIfNeeded()
            return abs(document.frame.height - translatedHeight) < 1
        }
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
        print("PASS 字距与字号即时重排、默认恢复、长句独立滚动、测试域译文开关及换组复位")
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
            return findResizeView(window.contentView)?.bounds.size == window.contentLayoutRect.size
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
        precondition(view.activeEdge == .right, "合成按下事件应选择右侧缩放动作")
        window.sendEvent(event(.leftMouseDragged, end))
        window.sendEvent(event(.leftMouseUp, end))
        precondition(abs(window.frame.width - initial.width - 40) < 1 && window.frame.minX == initial.minX,
                     "合成缩放事件应增宽且保持对侧锚点")
        window.setFrame(initial, display: true)
        let northwest = FloatingLyricsResizeCursor.fallbackCursor(for: .topLeft)
        let northeast = FloatingLyricsResizeCursor.fallbackCursor(for: .topRight)
        precondition(northwest !== NSCursor.crosshair && northeast !== NSCursor.crosshair && northwest !== northeast,
                     "macOS 14 两组对角方向应映射到不同光标对象，不能使用crosshair对象")
        precondition(northwest === FloatingLyricsResizeCursor.fallbackCursor(for: .bottomRight)
                     && northeast === FloatingLyricsResizeCursor.fallbackCursor(for: .bottomLeft))
        print("PASS 原生缩放view合成事件的几何、宽边命中、禁用放行与对角光标对象映射")
    }

    @MainActor private static func checkNativeDrag(
        _ controller: FloatingLyricsWindowController, model: AppModel
    ) async throws {
        guard let window = controller.window, let host = window.contentView as? NSHostingView<AnyView> else {
            preconditionFailure("正文拖动检查需要实际悬浮歌词host")
        }
        let originalFrame = window.frame
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let screen = FloatingLyricsWindowGeometry.visibleFrame(for: originalFrame, visibleFrames: visibleFrames) else {
            preconditionFailure("实际正文拖动检查需要可用显示器")
        }
        // 离屏恢复检查可能将窗放在屏幕顶部；本项先留出实际拖动余量，再恢复夹具位置。
        window.setFrame(NSRect(x: screen.midX - originalFrame.width / 2, y: screen.midY - originalFrame.height / 2,
                               width: originalFrame.width, height: originalFrame.height), display: true)
        defer { window.setFrame(originalFrame, display: true) }
        try await eventually("正文拖动层应挂载") {
            host.layoutSubtreeIfNeeded()
            guard let drag = findDragView(host) else { return false }
            return drag.bounds.size == window.contentLayoutRect.size && host.bounds.size == drag.bounds.size
        }
        guard let drag = findDragView(host), let scroll = findScrollView(host) else {
            preconditionFailure("拖动层与长句滚动视图必须同时存在")
        }
        // 显式准备按钮检查的工具条状态；这不是系统鼠标悬浮或屏幕光标验收。
        drag.reportHover(true)
        try await eventually("按钮夹具的工具条排除位置应就绪") {
            host.layoutSubtreeIfNeeded()
            return toolbarLayoutIsCurrent(window, drag: drag)
        }
        let center = NSPoint(x: drag.bounds.midX, y: drag.bounds.midY)
        precondition(host.hitTest(drag.convert(center, to: host.superview)) === drag,
                     "正文实际命中拖动层，不能被歌词文本或ScrollView吞掉")
        let toolbar = drag.excludedRect
        let lockFrame = NSRect(x: toolbar.minX + 67, y: toolbar.minY + 4, width: 28, height: 28)
        let lockPoint = NSPoint(x: lockFrame.midX, y: lockFrame.midY)
        precondition(drag.hitTest(drag.convert(lockPoint, to: drag.superview)) == nil,
                     "工具按钮真实位置不能被拖动层覆盖")
        let corner = NSPoint(x: drag.bounds.maxX - 6, y: drag.bounds.maxY - 6)
        precondition(drag.hitTest(drag.convert(corner, to: drag.superview)) == nil,
                     "边角缩放优先于正文拖动")
        let initial = window.frame
        let appWasActive = NSApplication.shared.isActive
        let keyWindow = NSApplication.shared.keyWindow
        let start = window.convertPoint(toScreen: drag.convert(center, to: nil))
        let end = NSPoint(x: start.x + 36, y: start.y + 28)
        let event: @MainActor (NSEvent.EventType, NSPoint) -> NSEvent = { type, point in
            NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let downEvent = event(.leftMouseDown, start)
        window.sendEvent(downEvent)
        let draggingAfterDown = drag.isDragging
        precondition(drag.isDragging, "正文合成按下应开始拖动动作")
        host.layoutSubtreeIfNeeded()
        window.resetCursorRects()
        precondition(drag.isDragging, "布局与光标区域重建不能取消拖动动作")
        let draggedEvent = event(.leftMouseDragged, end)
        window.sendEvent(draggedEvent)
        let upEvent = event(.leftMouseUp, end)
        window.sendEvent(upEvent)
        let screens = NSScreen.screens.map(\.visibleFrame)
        let downHit = host.hitTest(drag.convert(center, to: host.superview)).map { String(describing: type(of: $0)) } ?? "nil"
        let dragDiagnostic = "initial=\(initial), current=\(window.frame), desiredDelta=(36,28), screens=\(screens), "
            + "draggingAfterDown=\(draggingAfterDown), draggingNow=\(drag.isDragging), downHit=\(downHit), "
            + "eventWindow=\(downEvent.windowNumber)/\(window.windowNumber), down=\(downEvent.locationInWindow), "
            + "drag=\(draggedEvent.locationInWindow), up=\(upEvent.locationInWindow), locked=\(controller.isLocked), "
            + "movable=\(window.isMovable), ignoresMouse=\(window.ignoresMouseEvents)"
        precondition(abs(window.frame.minX - initial.minX - 36) < 1 && abs(window.frame.minY - initial.minY - 28) < 1
                     && window.frame.size == initial.size, "正文合成拖动事件应移动窗口且不改变尺寸；\(dragDiagnostic)")
        precondition(!drag.isDragging, "合成松开事件应结束拖动动作")
        precondition(NSApplication.shared.isActive == appWasActive && NSApplication.shared.keyWindow === keyWindow,
                     "正文拖动不得切换 App 激活状态或键盘焦点")
        window.setFrame(initial, display: true)
        let originalMode = model.lyricsPanel?.browseMode
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = scroll.contentView.bounds.minY
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -45, wheel2: 0, wheel3: 0)!
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        drag.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        try await eventually("正文拖动层仍应转交实际滚轮事件，长句可以阅读") {
            scroll.contentView.bounds.minY > before + 10
        }
        precondition(model.lyricsPanel?.browseMode == originalMode, "浮窗滚轮不改变主窗歌词浏览模式")
        drag.reportHover(true)
        try await eventually("锁按钮夹具的工具条应重新就绪") {
            host.layoutSubtreeIfNeeded()
            return toolbarLayoutIsCurrent(window, drag: drag)
        }
        try await clickButton(frame: lockFrame, host: host, window: window)
        try await eventually("浮窗工具锁按钮首击必须生效，不能被正文拖动抢走") {
            controller.isLocked && window.ignoresMouseEvents
        }
        try await eventually("锁态拖动层不可命中") {
            host.layoutSubtreeIfNeeded()
            guard let lockedDrag = findDragView(host) else { return false }
            return !lockedDrag.isEnabled && lockedDrag.hitTest(lockedDrag.convert(center, to: lockedDrag.superview)) == nil
        }
        controller.setLocked(false)
        print("PASS 正文合成事件拖窗几何、布局不取消拖动、焦点保持、滚轮转交、工具首击与锁态禁用")
    }

    /// 内部注册、命中与焦点检查；不移动系统指针，不断言屏幕实际显示哪一种光标。
    @MainActor private static func checkTrackingAndFocus(_ window: NSWindow) async throws {
        try await eventually("悬浮窗应准备原生交互层") {
            window.contentView?.layoutSubtreeIfNeeded()
            return findDragView(window.contentView)?.bounds.size == window.contentLayoutRect.size
                && findResizeView(window.contentView)?.bounds.size == window.contentLayoutRect.size
        }
        guard let drag = findDragView(window.contentView), let resize = findResizeView(window.contentView),
              window is FloatingLyricsPanel else { preconditionFailure("缺少真实浮窗原生交互层") }
        let wasActive = NSApplication.shared.isActive
        let keyWindow = NSApplication.shared.keyWindow
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        precondition(!window.isKeyWindow && !window.canBecomeKey && window.areCursorRectsEnabled)
        let clickPoints = [NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), NSPoint(x: 2, y: 2),
                           NSPoint(x: drag.bounds.maxX - 2, y: drag.bounds.maxY - 2)]
        try await eventually("正文和边缘应成为实际窗口命中目标") {
            clickPoints.allSatisfy { point in
                let screenPoint = window.convertPoint(toScreen: drag.convert(point, to: nil))
                return NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber
            }
        }
        drag.updateTrackingAreas()
        resize.updateTrackingAreas()
        let dragAreas = interactionTrackingAreas(drag)
        let resizeAreas = interactionTrackingAreas(resize)
        precondition(dragAreas.count == 2 && resizeAreas.count == 1,
                     "正文应分开登记activeAlways鼠标tracking与合法cursorUpdate，边缘应登记合法cursorUpdate")
        precondition((dragAreas + resizeAreas).allSatisfy { $0.options.contains(.inVisibleRect) },
                     "交互tracking必须让AppKit自动同步可见区域")
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.resetCursorRects()
            drag.updateTrackingAreas()
            resize.updateTrackingAreas()
            precondition(sameTrackingAreas(interactionTrackingAreas(drag), as: dragAreas)
                         && sameTrackingAreas(interactionTrackingAreas(resize), as: resizeAreas),
                         "同一交互view的布局、光标区域重建与重复update不能替换inVisibleRect tracking对象")
        }
        let overlay = NSPanel(contentRect: NSRect(x: window.frame.maxX - 70, y: window.frame.minY, width: 70, height: 70),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.level = .popUpMenu
        overlay.contentView = NSHostingView(rootView: Text("原创设置浮层").frame(width: 70, height: 70).background(.black))
        overlay.orderFrontRegardless()
        defer { overlay.close() }
        let coveredPoint = NSPoint(x: window.frame.maxX - 6, y: window.frame.minY + 6)
        try await eventually("覆盖浮层应成为该位置的WindowServer命中目标") {
            NSWindow.windowNumber(at: coveredPoint, belowWindowWithWindowNumber: 0) == overlay.windowNumber
        }
        let activeAfter = NSApplication.shared.isActive
        let keyAfter = NSApplication.shared.keyWindow
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let focusDiagnostic = "appActiveBefore=\(wasActive), appActiveAfter=\(activeAfter), "
            + "keySame=\(keyAfter === keyWindow), floatingIsKey=\(window.isKeyWindow), overlayIsKey=\(overlay.isKeyWindow)"
        let externalSwitch = frontmostAfter != frontmost && frontmost != ownPID && frontmostAfter != ownPID
            && !wasActive && !activeAfter && keyAfter === keyWindow
        precondition(activeAfter == wasActive && keyAfter === keyWindow && (frontmostAfter == frontmost || externalSwitch),
                     "tracking与原生区域重建不能切换前台App或键盘焦点；\(focusDiagnostic)")
        print("PASS 原生tracking身份稳定、窗口/覆盖命中与非激活焦点")
        print("INFO 屏幕实际光标与真实鼠标进出另行人工验收；NSCursor.current和合成事件不作为该项通过证据")
    }

    @MainActor private static func interactionTrackingAreas(_ view: NSView) -> [NSTrackingArea] {
        view.trackingAreas.filter { area in
            (area.owner as? NSView) === view
                && (area.options.contains([.activeAlways, .mouseEnteredAndExited, .mouseMoved])
                    || area.options.contains([.activeInActiveApp, .cursorUpdate]))
        }
    }

    @MainActor private static func sameTrackingAreas(_ current: [NSTrackingArea], as original: [NSTrackingArea]) -> Bool {
        current.count == original.count && original.allSatisfy { old in current.contains { $0 === old } }
    }

    @MainActor private static func checkDetachedTrackingCleanup() {
        // 不展示此窗口，只验证同一对原生view脱离/重新加入窗口时的资源清理。
        let probe = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        probe.isReleasedWhenClosed = false
        defer { probe.contentView = nil; probe.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        let drag = FloatingLyricsDragRegion.DragView(frame: content.bounds)
        let resize = FloatingLyricsResizeRegion.ResizeView(frame: content.bounds)
        content.addSubview(drag)
        content.addSubview(resize)
        probe.contentView = content
        drag.updateTrackingAreas()
        resize.updateTrackingAreas()
        precondition(interactionTrackingAreas(drag).count == 2 && interactionTrackingAreas(resize).count == 1)
        probe.contentView = nil
        precondition(drag.window == nil && resize.window == nil
                     && interactionTrackingAreas(drag).isEmpty && interactionTrackingAreas(resize).isEmpty,
                     "离窗必须清理正文与边缘的自有tracking")
        probe.contentView = content
        drag.updateTrackingAreas()
        resize.updateTrackingAreas()
        precondition(drag.window === probe && resize.window === probe
                     && interactionTrackingAreas(drag).count == 2 && interactionTrackingAreas(resize).count == 1,
                     "同一view重新挂载后应恢复有效tracking")
        print("PASS 同一原生交互view离窗清理与重新挂载恢复tracking")
    }

    @MainActor private static func checkTrackingAfterResizeAndUnlock(_ controller: FloatingLyricsWindowController) async throws {
        guard let window = controller.window else { preconditionFailure("缺少光标生命周期窗口") }
        for _ in 0..<3 {
            controller.setLocked(true)
            try await eventually("锁定取消拖动和缩放") {
                window.contentView?.layoutSubtreeIfNeeded()
                return findDragView(window.contentView)?.isEnabled == false
                    && findResizeView(window.contentView)?.isEnabled == false
            }
            guard let disabledDrag = findDragView(window.contentView), let disabledResize = findResizeView(window.contentView) else {
                preconditionFailure("锁定检查缺少原生交互层")
            }
            precondition(interactionTrackingAreas(disabledDrag).isEmpty && interactionTrackingAreas(disabledResize).isEmpty,
                         "禁用后必须移除正文与边缘自有tracking")
            controller.setLocked(false)
            try await eventually("解锁重新启用交互") {
                window.contentView?.layoutSubtreeIfNeeded()
                return findDragView(window.contentView)?.isEnabled == true
                    && findResizeView(window.contentView)?.isEnabled == true
            }
            try await checkTrackingAndFocus(window)
            try await checkNativeResize(window)
            try await checkTrackingAndFocus(window)
        }
        print("PASS 锁定禁用tracking、解锁恢复及合成缩放后的原生区域注册")
    }

    @MainActor private static func findDragView(_ view: NSView?) -> FloatingLyricsDragRegion.DragView? {
        guard let view else { return nil }
        if let drag = view as? FloatingLyricsDragRegion.DragView { return drag }
        return view.subviews.lazy.compactMap(findDragView).first
    }

    @MainActor private static func toolbarLayoutIsCurrent(_ window: NSWindow, drag: FloatingLyricsDragRegion.DragView) -> Bool {
        let toolbar = drag.excludedRect
        return drag.bounds.size == window.contentLayoutRect.size && toolbar.width > 0
            && abs(toolbar.maxX - drag.bounds.maxX) < 0.5 && drag.bounds.contains(toolbar)
    }

    @MainActor private static func checkFloatingSettings(_ controller: FloatingLyricsWindowController, model: AppModel) async throws {
        guard let window = controller.window, let host = window.contentView else { preconditionFailure("缺少设置浮窗") }
        var routeCount = 0
        let previousRoute = controller.presentMainWindow
        controller.presentMainWindow = {
            precondition(!model.isLyricsFetchPresented && !model.isImportPresented, "必须先展示主窗，再启动获取/导入")
            routeCount += 1
        }
        defer { controller.presentMainWindow = previousRoute }
        func clickGear() async throws {
            guard let drag = findDragView(host) else { preconditionFailure("设置工具条缺少交互层") }
            let gear = NSRect(x: drag.excludedRect.minX + 35, y: drag.excludedRect.minY + 4, width: 28, height: 28)
            try await clickButton(frame: gear, host: host, window: window)
        }
        func openGear() async throws -> NSWindow {
            guard let drag = findDragView(host) else { preconditionFailure("设置工具条缺少交互层") }
            // 前一覆盖夹具刚关闭，先让当前窗口与 WindowServer 命中准备就绪，不激活 App。
            window.orderFrontRegardless()
            try await eventually("设置浮窗当前布局和正文点击命中应就绪") {
                host.layoutSubtreeIfNeeded()
                let point = window.convertPoint(toScreen: drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil))
                return drag.bounds.size == window.contentLayoutRect.size
                    && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber
            }
            // 只为设置按钮流程准备工具条，不将夹具状态当作真实鼠标hover通过。
            drag.reportHover(true)
            do {
                try await eventually("悬浮设置工具条应显示") {
                    host.layoutSubtreeIfNeeded()
                    return toolbarLayoutIsCurrent(window, drag: drag)
                }
            } catch {
                let point = window.convertPoint(toScreen: drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil))
                print("GEAR toolbar=\(drag.excludedRect), dragBounds=\(drag.bounds), contentLayout=\(window.contentLayoutRect), "
                      + "pointHitsOwn=\(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber), "
                      + "frontmostOwn=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier), "
                      + "routeCount=\(routeCount), presentedSheet=\(FloatingLyricsActions.hasPresentedSheet(model))")
                fflush(nil)
                throw error
            }
            let existing = Set(NSApplication.shared.windows.filter(\.isVisible).map(\.windowNumber))
            try await clickGear()
            var popup: NSWindow?
            try await eventually("gear 首击应打开实际可见的设置 popover") {
                popup = NSApplication.shared.windows.first { $0.isVisible && !existing.contains($0.windowNumber) && $0.contentView != nil }
                return popup != nil
            }
            guard let popup else { preconditionFailure("缺少实际设置 popover") }
            return popup
        }
        var reportedAXLimitation = false
        func perform(_ identifier: String, in popup: NSWindow, fallback: () -> Void) async throws {
            let result = pressAccessibleControl(identifier)
            if result.found {
                precondition(result.hasSpacing, "设置 popover 必须有悬浮歌词字间距控件")
                precondition(result.status == AXError.success.rawValue, "实际设置控件必须可操作")
            } else {
                // 独立 CLI 没有外部 AX 客户端时，整个 SwiftUI 树可能未构建。已有树但缺控件仍报错。
                precondition(result.status != AXError.success.rawValue || popup.contentView?.accessibilityChildren()?.isEmpty != false,
                             "已有 SwiftUI AX 节点时，设置控件不能缺失")
                if !reportedAXLimitation {
                    print("INFO 独立检查进程无法查询 SwiftUI AX 控件（公开 own-PID AX 状态：\(result.status)）；实际 gear/弹窗已验证，按钮操作需外部 AX 验证")
                    reportedAXLimitation = true
                }
                try await clickGear()
                try await eventually("再次点击 gear 应关闭实际设置 popover") { !popup.isVisible }
                fallback()
            }
        }
        precondition(model.canBeginOnlineFetch)
        let trackKey = model.currentTrackKey
        let fetchPopup = try await openGear()
        try await perform("floating-lyrics-fetch", in: fetchPopup) {
            FloatingLyricsActions.fetch(model, presentMainWindow: { controller.presentMainWindow?() })
        }
        try await eventually("浮窗获取复用主模型并冻结当前目标") {
            routeCount == 1 && model.isLyricsFetchPresented && model.lyricsFetchModel?.target.trackKey == trackKey
        }
        model.isLyricsFetchPresented = false
        model.lyricsFetchModel = nil
        try await eventually("获取入口操作后设置 popover 应关闭") { !fetchPopup.isVisible }
        let importPopup = try await openGear()
        try await perform("floating-lyrics-import", in: importPopup) {
            FloatingLyricsActions.importLyrics(model, presentMainWindow: { controller.presentMainWindow?() })
        }
        try await eventually("浮窗导入复用原流程并冻结当前目标") {
            routeCount == 2 && model.isImportPresented && model.importFlow?.target?.trackKey == trackKey
        }
        guard let flow = model.importFlow else { preconditionFailure("已有导入草稿需要原会话") }
        flow.pastedText = "[00:00.00]纸船上的新注记"
        let generation = flow.operationGeneration
        var focusedExisting = 0
        controller.presentMainWindow = { focusedExisting += 1 }
        FloatingLyricsActions.fetch(model, presentMainWindow: { focusedExisting += 1 })
        FloatingLyricsActions.importLyrics(model, presentMainWindow: { focusedExisting += 1 })
        precondition(flow.operationGeneration == generation && flow.pastedText == "[00:00.00]纸船上的新注记"
                     && model.isImportPresented && !model.isLyricsFetchPresented, "已有导入草稿不能被重复获取/导入覆盖")
        try await eventually("导入入口操作后设置 popover 应关闭") { !importPopup.isVisible }
        let resumePopup = try await openGear()
        try await perform("floating-lyrics-resume", in: resumePopup) { controller.presentMainWindow?() }
        precondition(focusedExisting == 3 && flow.operationGeneration == generation
                     && flow.pastedText == "[00:00.00]纸船上的新注记", "继续操作只聚焦现有会话，保留人工草稿")
        model.isImportPresented = false
        try await eventually("导入入口操作后设置 popover 应关闭") { !resumePopup.isVisible }
        print("PASS gear 首击/弹窗开关、先展示主窗再获取/导入、目标固定及人工草稿防重入")
    }

    @MainActor private static func pressAccessibleControl(_ identifier: String) -> (found: Bool, hasSpacing: Bool, status: Int32) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // 自进程 AX 会直接执行 SwiftUI action，必须留在 MainActor；不使用私有属性或申请辅助权限。
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(application, 0.5)
        var rootChildren: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(application, kAXChildrenAttribute as CFString, &rootChildren)
        guard query == .success else { return (false, false, query.rawValue) }
        var queue = [application]
        var visited: [AXUIElement] = []
        var control: AXUIElement?
        var hasSpacing = false
        while !queue.isEmpty {
            let element = queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { continue }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success {
                if value as? String == identifier { control = element }
                if value as? String == "floating-lyrics-spacing" { hasSpacing = true }
            }
            let attributes = CFEqual(element, application) ? [kAXChildrenAttribute, kAXWindowsAttribute] : [kAXChildrenAttribute]
            for attribute in attributes {
                value = nil
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let children = value as? [AXUIElement] { queue.append(contentsOf: children) }
            }
        }
        guard let control else { return (false, hasSpacing, query.rawValue) }
        return (true, hasSpacing, AXUIElementPerformAction(control, kAXPressAction as CFString).rawValue)
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
