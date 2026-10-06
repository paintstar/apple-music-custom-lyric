import AppKit
import Foundation
import ShinAppleKit
import ShinAppleData
import ShinAppServices
import ShinLyricsEngine

/// 真实窗口中的原创歌词回归；只观察实际视口、绘制结果与播放输入，不复刻动画公式。
@MainActor
enum LyricsMotionUICheck {
    static func run() async throws {
        try await checkContinuousMotion()
        try await checkNarrowLongMotion()
        try await checkScrollerPresentation()
        try await checkVisibilityResume()
        try await checkWaitingPresentation()
    }

    private static func makeWindow(size: NSSize = NSSize(width: 520, height: 480)) -> (NSWindow, LyricsScrollView) {
        let view = LyricsScrollView()
        view.frame = NSRect(origin: .zero, size: size)
        view.drawsBackground = true
        view.backgroundColor = .black
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 90, y: 90), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "原创歌词动效检查"
        window.backgroundColor = .black
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private static func settle(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure(message)
    }

    private static func sampleOffsets(_ view: LyricsScrollView, count: Int = 12) async throws -> [CGFloat] {
        var result = [view.contentView.bounds.minY]
        for _ in 0..<count {
            try await Task.sleep(for: .milliseconds(8))
            result.append(view.contentView.bounds.minY)
        }
        return result
    }

    private static func assertForward(_ offsets: [CGFloat], target: CGFloat) {
        precondition(zip(offsets, offsets.dropFirst()).allSatisfy { $1 >= $0 - 0.5 },
                     "同方向歌词滚动不能反向或回弹")
        precondition(offsets.allSatisfy { $0 <= target + 0.5 }, "歌词不能越过目标后再退回")
    }

    private static func pixels(of view: NSView) -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("无法获取真实歌词视图的绘制结果")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("无法编码歌词绘制结果")
        }
        return data
    }

    private static func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SHIN_LYRICS_CAPTURE_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pixels(of: view).write(to: directory.appendingPathComponent(name + ".png"))
        print("原创歌词截图：\(name).png")
    }

    private static func checkContinuousMotion() async throws {
        let document = LyricDocument(lines: (0..<12).map { index in
            LyricLine(startMs: Int64(index) * 2_000, text: "Paper boats follow the evening light \(index).",
                      translations: ["zh-Hans": Translation(text: "纸船沿着晚霞向前，原创第 \(index) 句。")])
        })
        let (window, view) = makeWindow()
        defer { view.prepareForRemoval(); window.orderOut(nil) }
        var unexpectedManual = 0
        func show(_ index: Int, reduceMotion: Bool = false, request: LyricsPanelModel.ScrollAnchorRequest? = nil) {
            view.configure(NativeLyricsScrollView(
                document: document, typography: .resolved(line: 30, translation: 15, width: view.frame.width),
                showTranslations: true, currentLineIds: [document.lines[index].id],
                request: request ?? .init(requestId: UUID(), lineId: document.lines[index].id),
                followsPlayback: true, reduceMotion: reduceMotion,
                onInteraction: { unexpectedManual += 1 }, onDragStateChange: { _ in }, onTapLine: { _ in }
            ))
            view.layoutSubtreeIfNeeded()
        }
        show(0)
        try await Task.sleep(for: .milliseconds(250))
        let initialFrames = view.textLayout.rows.map(\.frame)
        let initialPixels = pixels(of: view)
        try capture(view, name: "lyrics-current")
        show(1)
        try await settle("屏幕刷新应产生真实滚动中间帧") {
            view.contentView.bounds.minY > 2 && view.isScrollAnimating
        }
        let before = try await sampleOffsets(view, count: 8)
        precondition(before.last! - before.first! > 1, "普通换行必须跨多帧移动")
        precondition(initialPixels != pixels(of: view), "实际绘制结果应随歌词移动变化")
        let interruptedAt = view.contentView.bounds.minY
        show(2)
        precondition(abs(view.contentView.bounds.minY - interruptedAt) < 1, "新目标应从当前画面接续")
        let after = try await sampleOffsets(view, count: 8)
        let previousTravel = before.last! - before.first!
        precondition(after.last! - after.first! > previousTravel * 0.2,
                     "同方向新目标不能让正在移动的歌词突然停下重新起步")
        let target = view.textLayout.rows[2].frame.minY
        var remainder = after
        while view.isScrollAnimating, remainder.count < 200 {
            try await Task.sleep(for: .milliseconds(8))
            remainder.append(view.contentView.bounds.minY)
        }
        assertForward(before, target: target)
        assertForward(remainder, target: target)
        precondition(!view.isScrollAnimating && abs(view.contentView.bounds.minY - target) < 1,
                     "连续换行必须准确停在最新目标")
        precondition(initialFrames == view.textLayout.rows.map(\.frame), "高亮及动画不能改变歌词排版")
        let inFlightRequest = LyricsPanelModel.ScrollAnchorRequest(requestId: UUID(), lineId: document.lines[3].id)
        show(3, request: inFlightRequest)
        try await settle("减少动态效果切换检查需要真实的滚动中间帧") {
            let offset = view.contentView.bounds.minY
            return view.isScrollAnimating && offset > target + 1 && offset < view.textLayout.rows[3].frame.minY - 1
        }
        // 设置变化不会生成新的播放定位请求；必须沿用 requestId 才能覆盖中途切换的真实路径。
        show(3, reduceMotion: true, request: inFlightRequest)
        precondition(!view.isScrollAnimating && abs(view.contentView.bounds.minY - view.textLayout.rows[3].frame.minY) < 1,
                     "滚动中打开减少动态效果，即使请求不变也必须立即定位，不能停在中间")
        show(11)
        try await settle("远距离 seek 应经过真实淡出中间态") { view.documentView!.alphaValue < 0.95 }
        show(9)
        try await settle("远距落位后必须有真实淡入中间帧") {
            view.jump?.positioned == true && view.canvas.alphaValue > 0.05 && view.canvas.alphaValue < 0.85
        }
        let fadingAlpha = view.canvas.alphaValue
        show(9)
        precondition(abs(view.canvas.alphaValue - fadingAlpha) < 0.01 && view.isScrollAnimating,
                     "淡入中重发同目标请求必须接续，不能突然变为全亮")
        show(10)
        precondition(abs(view.canvas.alphaValue - fadingAlpha) < 0.01 && view.jump != nil,
                     "淡入中进入相邻组时须保持亮度接续，同时自然移动")
        try await settle("淡出中改变目标后应抵达最新歌词") {
            !view.isScrollAnimating && abs(view.contentView.bounds.minY - view.textLayout.rows[10].frame.minY) < 1
        }
        precondition(view.documentView!.alphaValue == 1, "新目标完成后必须恢复正文透明度")
        precondition(unexpectedManual == 0, "程序动画不能误触发手动阅读")
        show(0)
        try await settle("手动取消检查需要正在淡出的正文") { view.documentView!.alphaValue < 0.95 }
        // 与已有辅助功能滚动检查相同：真实移动 clip，经过用户浏览检测路径取消自动定位。
        view.contentView.scroll(to: NSPoint(x: 0, y: view.contentView.bounds.minY + 24))
        let manualOffset = view.contentView.bounds.minY
        try await Task.sleep(for: .milliseconds(120))
        precondition(unexpectedManual == 1 && !view.isScrollAnimating && view.documentView!.alphaValue == 1
                     && abs(view.contentView.bounds.minY - manualOffset) < 0.01,
                     "手动阅读应取消远距定位并恢复透明度，旧目标不能再次滚回")
        // 跨过多个歌词组时仍要能取消过渡，卸载不能留下透明的正文。
        show(0)
        try await settle("卸载检查需要一个正在运行的动画") { view.hasActiveDisplayLink }
        try await Task.sleep(for: .milliseconds(40))
        view.prepareForRemoval()
        let removedOffset = view.contentView.bounds.minY
        try await Task.sleep(for: .milliseconds(120))
        precondition(!view.hasActiveDisplayLink && !view.isScrollAnimating
                     && abs(view.contentView.bounds.minY - removedOffset) < 0.01,
                     "卸载必须停止显示刷新，旧动画不得回写")
        precondition(view.documentView?.alphaValue == 1 && view.textLayout.textView.alphaValue == 1,
                     "卸载中断过渡后必须恢复正文透明度")
        print("PASS 歌词实际绘制中间帧、同向接续、终点无回弹、固定排版、减少动态效果与卸载清理")
    }

    private struct MotionSamples {
        var offsets: [CGFloat] = []
        var minimumAlpha: CGFloat = 1
        var duration: TimeInterval = 0
        var maximumStep: CGFloat {
            zip(offsets, offsets.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }
    }

    private static func collectMotion(_ view: LyricsScrollView) async throws -> MotionSamples {
        let started = ProcessInfo.processInfo.systemUptime
        var sample = MotionSamples(offsets: [view.contentView.bounds.minY])
        while view.isScrollAnimating && ProcessInfo.processInfo.systemUptime - started < 2.5 {
            try await Task.sleep(for: .milliseconds(5))
            sample.offsets.append(view.contentView.bounds.minY)
            sample.minimumAlpha = min(sample.minimumAlpha, view.canvas.alphaValue)
        }
        sample.duration = ProcessInfo.processInfo.systemUptime - started
        precondition(!view.isScrollAnimating, "普通歌词推进必须及时收敛")
        return sample
    }

    private static func checkNarrowLongMotion() async throws {
        let document = LyricDocument(lines: [
            LyricLine(startMs: 0, text: "Fold a paper boat."),
            LyricLine(startMs: 2_000,
                      text: "Beside the quiet river, we fold another paper boat and let the evening breeze carry a little lantern beneath the open bridge, past the garden, and toward the soft light on the far bank.",
                      translations: ["zh-Hans": Translation(text: "原创长句：我们折好纸船，沿着河边放下小灯，看它经过花园和小桥，慢慢驶向远处的灯光。")]),
            LyricLine(startMs: 4_000, text: ""),
            LyricLine(startMs: 4_250, text: ""),
            LyricLine(startMs: 4_500, text: ""),
            LyricLine(startMs: 4_750, text: ""),
            LyricLine(startMs: 5_000, text: ""),
            LyricLine(startMs: 5_250, text: ""),
            LyricLine(startMs: 6_000, text: "A small light waits."),
            LyricLine(startMs: 6_000, text: "Two paper boats drift together."),
            LyricLine(startMs: 8_000, text: "The garden falls asleep."),
            LyricLine(startMs: 10_000, text: "We watch the water turn."),
            LyricLine(startMs: 12_000, text: "A soft breeze follows."),
            LyricLine(startMs: 14_000, text: "Our last lantern rests.")
        ])
        let (window, view) = makeWindow(size: NSSize(width: 230, height: 360))
        defer { view.prepareForRemoval(); window.orderOut(nil) }
        func show(_ index: Int) {
            view.configure(NativeLyricsScrollView(
                document: document, typography: .resolved(line: 30, translation: 15, width: view.frame.width),
                showTranslations: true, currentLineIds: [document.lines[index].id],
                request: .init(requestId: UUID(), lineId: document.lines[index].id),
                followsPlayback: true, reduceMotion: false,
                onInteraction: {}, onDragStateChange: { _ in }, onTapLine: { _ in }
            ))
            view.layoutSubtreeIfNeeded()
        }
        show(0)
        try await Task.sleep(for: .milliseconds(250))
        let frames = view.textLayout.rows.map(\.frame)
        show(1)
        let short = try await collectMotion(view)
        let shortTarget = view.textLayout.rows[1].frame.minY
        assertForward(short.offsets, target: shortTarget)
        precondition(short.minimumAlpha == 1 && short.maximumStep < shortTarget * 0.3,
                     "短句应连续跨帧平移，不能淡出或单帧跳跃")
        show(2)
        let long = try await collectMotion(view)
        let longTarget = view.textLayout.rows[2].frame.minY
        let longDistance = longTarget - shortTarget
        precondition(longDistance > view.contentSize.height * LyricsMotionStyle.jumpViewportFraction,
                     "窄栏夹具必须覆盖超出远跳距离门槛的相邻长句")
        assertForward(long.offsets, target: longTarget)
        precondition(long.minimumAlpha == 1 && long.maximumStep < longDistance * 0.3,
                     "窄栏长句正常推进也必须连续平移，不能误作远seek让整栏闪淡")
        precondition(long.duration < 1.7 && long.duration > short.duration,
                     "长句应适度放缓且及时停稳，不能留下过长拖尾")
        let resumedDistance = view.textLayout.rows[8].frame.minY - longTarget
        precondition(resumedDistance > view.contentSize.height * LyricsMotionStyle.jumpViewportFraction,
                     "合并空白夹具须覆盖超过远seek门槛的等待段接续")
        for index in [8, 9, 10] {
            show(index)
            let normal = try await collectMotion(view)
            precondition(normal.minimumAlpha == 1, "合并多个明确空白后的实词及同时间组接续不能触发整栏淡出")
        }
        precondition(frames == view.textLayout.rows.map(\.frame), "相邻长句推进不能重排文本")
        print("歌词真实采样：短句 \(Int(short.duration * 1_000)) ms、最大步进 \(Int(short.maximumStep.rounded())) pt；"
              + "窄栏长句 \(Int(long.duration * 1_000)) ms、最大步进 \(Int(long.maximumStep.rounded())) pt")
        print("PASS 窄栏双语长句、明确空白、同时间组、连续相邻推进保持可见且及时停稳")
    }

    private static func checkScrollerPresentation() async throws {
        let document = LyricDocument(lines: (0..<15).map { index in
            LyricLine(startMs: Int64(index) * 1_000, text: "An original paper boat carries a lantern \(index).")
        })
        let (window, view) = makeWindow(size: NSSize(width: 300, height: 400))
        defer { view.prepareForRemoval(); window.orderOut(nil) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shin-scroller-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let binding = SongBinding(persistentID: "00000000B0000001", lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let panel = LyricsPanelModel(store: store)
        await panel.refresh(trackKey: binding.trackKey, trackEpoch: 1)
        let area = UUID()
        panel.lyricsAreaAppeared(area)
        defer { panel.lyricsAreaDisappeared(area) }
        view.catcher.onInteraction = { [weak view] in
            view?.beginUserInteraction()
            panel.enterManualBrowsing()
        }
        view.catcher.onDragStateChange = { [weak view] active in
            if active { view?.beginUserInteraction() }
            panel.setManualInteractionActive(active, in: area)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle("原生滚动条测试窗口应取得键盘焦点") { window.isKeyWindow }
        func show(_ index: Int) {
            view.configure(NativeLyricsScrollView(
                document: document, typography: .resolved(line: 30, translation: 15, width: 300),
                showTranslations: false, currentLineIds: [document.lines[index].id],
                request: .init(requestId: UUID(), lineId: document.lines[index].id),
                followsPlayback: panel.browseMode == .follow, reduceMotion: false,
                onInteraction: { panel.enterManualBrowsing() },
                onDragStateChange: { panel.setManualInteractionActive($0, in: area) }, onTapLine: { _ in }
            ))
            view.layoutSubtreeIfNeeded()
        }
        show(0)
        try await Task.sleep(for: .milliseconds(250))
        let scroller = view.lyricsScroller
        let quietPixels = pixels(of: scroller)
        let originalSize = view.contentSize
        let originalScroller = view.verticalScroller
        for index in 1...3 {
            show(index)
            var changedFrameCount = 0
            let initialOffset = view.contentView.bounds.minY
            let started = ProcessInfo.processInfo.systemUptime
            while view.isScrollAnimating && ProcessInfo.processInfo.systemUptime - started < 2.5 {
                try await Task.sleep(for: .milliseconds(12))
                if view.contentView.bounds.minY != initialOffset { changedFrameCount += 1 }
                precondition(pixels(of: scroller) == quietPixels,
                             "自动歌词滚动的实际叠加条绘制必须稳定，不能每次换句闪现")
            }
            precondition(!view.isScrollAnimating, "滚动条多帧检查超时：显示刷新未在2.5秒内完成歌词运动")
            precondition(changedFrameCount > 5, "滚动条检查必须覆盖实际歌词运动中间帧")
        }
        precondition(view.verticalScroller === originalScroller && view.scrollerStyle == .overlay
                     && view.contentSize == originalSize && scroller.doubleValue > 0,
                     "跟随时必须保留原生条及准确几何，不能切换条样式或挤动视口")
        try await checkScrollerGestures(view: view, window: window, panel: panel, quietPixels: quietPixels, show: show)
        print("PASS 原生滚动条真实多帧绘制稳定、悬停退出、原生拖动、跟随恢复与卸载")
    }

    private static func checkScrollerGestures(
        view: LyricsScrollView, window: NSWindow, panel: LyricsPanelModel, quietPixels: Data, show: (Int) -> Void
    ) async throws {
        let scroller = view.lyricsScroller
        let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        func pointerEvent(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  trackingNumber: 0, userData: nil)!
        }
        scroller.mouseEntered(with: pointerEvent(.mouseEntered))
        try await settle("鼠标进入滚动条区域必须绘制可用的原生条") { pixels(of: scroller) != quietPixels }
        precondition(view.hitTest(view.convert(point, from: nil)) === scroller,
                     "可见原生条必须保留真实命中，不能被歌词或透明覆盖层拦截")
        scroller.mouseExited(with: pointerEvent(.mouseExited))
        try await settle("跟随时鼠标离开条区域应恢复稳定隐去") { pixels(of: scroller) == quietPixels }
        scroller.mouseEntered(with: pointerEvent(.mouseEntered))
        try await settle("原生拖动前滚动条应再次显示") { pixels(of: scroller) != quietPixels }
        let beforeDrag = view.contentView.bounds.minY
        try await dragScroller(view: view, window: window)
        precondition(abs(view.contentView.bounds.minY - beforeDrag) > 10 && panel.browseMode == .manual,
                     "真实滚动条按下/拖动/松手必须移动视口并进入面板手动浏览")
        scroller.mouseExited(with: pointerEvent(.mouseExited))
        show(3)
        try await settle("手动浏览必须恢复原生滚动条实际绘制") { pixels(of: scroller) != quietPixels }
        let manualOffset = view.contentView.bounds.minY
        try await Task.sleep(for: .milliseconds(80))
        precondition(panel.browseMode == .manual && abs(view.contentView.bounds.minY - manualOffset) < 0.01,
                     "松手后的手动浏览期间不能抢回歌词位置")
        panel.resumeFollowing()
        show(4)
        let resumed = try await collectMotion(view)
        precondition(resumed.minimumAlpha == 1 && pixels(of: scroller) == quietPixels,
                     "恢复跟随后条绘制再次稳定，歌词继续自然平移")
        scroller.mouseEntered(with: pointerEvent(.mouseEntered))
        try await settle("卸载检查前鼠标悬停应再次显示原生条") { pixels(of: scroller) != quietPixels }
        view.prepareForRemoval()
        precondition(pixels(of: scroller) == quietPixels, "卸载必须清除未收到mouseExited的条悬停状态")
    }

    private static func dragScroller(view: LyricsScrollView, window: NSWindow) async throws {
        let scroller = view.lyricsScroller
        let knob = scroller.rect(for: .knob)
        precondition(knob.width > 0 && knob.height > 0, "原生滚动条拖动须命中真实旋钮")
        let start = NSPoint(x: knob.midX, y: knob.midY)
        let end = NSPoint(x: start.x, y: start.y + (start.y + 60 < scroller.bounds.maxY ? 60 : -60))
        let event: @MainActor @Sendable (NSEvent.EventType, NSPoint) -> NSEvent = { type, point in
            let value = NSEvent.mouseEvent(with: type, location: scroller.convert(point, to: nil), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            precondition(value.window === window, "滚动条鼠标事件只能属于测试窗口")
            return value
        }
        let dragging = Timer(timeInterval: 0.03, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.postEvent(event(.leftMouseDragged, end), atStart: false) }
        }
        let release = Timer(timeInterval: 0.07, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.postEvent(event(.leftMouseUp, end), atStart: false) }
        }
        for timer in [dragging, release] {
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        defer { dragging.invalidate(); release.invalidate() }
        NSApplication.shared.postEvent(event(.leftMouseDown, start), atStart: false)
        try await Task.sleep(for: .milliseconds(140))
    }

    private static func checkVisibilityResume() async throws {
        let document = LyricDocument(lines: (0..<6).map { index in
            LyricLine(startMs: Int64(index) * 2_000, text: "An original lantern rests beside a paper boat \(index).")
        })
        let (window, view) = makeWindow()
        defer { view.prepareForRemoval(); window.orderOut(nil) }
        func show(_ index: Int) {
            view.configure(NativeLyricsScrollView(
                document: document, typography: .resolved(line: 30, translation: 15, width: view.frame.width),
                showTranslations: false, currentLineIds: [document.lines[index].id],
                request: .init(requestId: UUID(), lineId: document.lines[index].id),
                followsPlayback: true, reduceMotion: false,
                onInteraction: {}, onDragStateChange: { _ in }, onTapLine: { _ in }
            ))
            view.layoutSubtreeIfNeeded()
        }
        show(0)
        try await Task.sleep(for: .milliseconds(250))
        window.orderOut(nil)
        try await settle("隐藏歌词窗口应停止显示刷新") {
            !window.isVisible && !window.occlusionState.contains(.visible) && !view.hasActiveDisplayLink
        }
        show(1)
        precondition(view.scrollMotion != nil && !view.hasActiveDisplayLink,
                     "隐藏夹具必须覆盖已排队但尚未启动的相邻歌词运动")
        let target = view.textLayout.rows[1].frame.minY
        var offsets = [view.contentView.bounds.minY]
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: view.contentView, queue: nil
        ) { _ in
            MainActor.assumeIsolated { offsets.append(view.contentView.bounds.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.orderFront(nil)
        try await settle("窗口恢复可见后应准确定位最新组并结束排队位移") {
            window.occlusionState.contains(.visible) && !view.isScrollAnimating
                && abs(view.contentView.bounds.minY - target) < 1
        }
        try await Task.sleep(for: .milliseconds(100))
        assertForward(offsets, target: target)
        precondition(abs(view.contentView.bounds.minY - target) < 1 && view.canvas.alphaValue == 1,
                     "恢复显示后旧motion不能回写旧位置，也不能留下透明正文")
        print("PASS 真实窗口隐藏时切换目标、恢复定位无回退、正文透明度及显示刷新清理")
    }

    private static func checkWaitingPresentation() async throws {
        let document = LyricDocument(lines: [
            LyricLine(startMs: 4_000, text: "A paper boat carries a little lantern.",
                      translations: ["zh-Hans": Translation(text: "一只纸船载着小灯，慢慢驶向浅湾。")]),
            LyricLine(startMs: 8_000, text: ""),
            LyricLine(startMs: 12_000,
                      text: "Along the quiet river, we fold another paper boat and let the evening breeze carry our little lantern toward the open bridge.",
                      translations: ["zh-Hans": Translation(text: "安静的河边，我们再折一只纸船，让晚风把小灯送往桥下；这是一段用于检查换行和双语排版的原创文字。")])
        ])
        let (window, view) = makeWindow()
        defer { view.prepareForRemoval(); window.orderOut(nil) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shin-lyrics-motion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let binding = SongBinding(persistentID: "ABC90101", lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let panel = LyricsPanelModel(store: store)
        let coordinator = PlaybackLyricsCoordinator(onDisplayChange: { _ in })
        var snapshot = PlaybackSnapshot(trackEpoch: 1, title: "原创等待测试", positionMs: 500, durationMs: 24_000,
                                        status: .playing, seq: 1, sessionEpoch: 1, trackRef: binding.trackKey)
        coordinator.update(snapshot: snapshot)
        panel.attach(coordinator: coordinator)
        await panel.refresh(trackKey: binding.trackKey, trackEpoch: 1)
        panel.apply(display: coordinator.currentDisplay())
        let introRequest = panel.scrollRequest
        var position: Int64 = 500
        let intro = LyricsWaitingInterval(startMs: 0, endMs: 4_000, nextLineId: document.lines[0].id, anchorLineId: nil)
        let interlude = LyricsWaitingInterval(startMs: 8_000, endMs: 12_000,
                                             nextLineId: document.lines[2].id, anchorLineId: document.lines[1].id)
        func show(waiting: LyricsWaitingInterval?, current: Int? = nil, playing: Bool = true,
                  reduceMotion: Bool = false, request: LyricsPanelModel.ScrollAnchorRequest? = nil) {
            let anchor = waiting?.anchorLineId ?? waiting?.nextLineId ?? document.lines[current ?? 0].id
            view.configure(NativeLyricsScrollView(
                document: document, typography: .resolved(line: 30, translation: 15, width: view.frame.width),
                showTranslations: true, currentLineIds: Set(current.map { [document.lines[$0].id] } ?? []),
                request: request ?? .init(requestId: UUID(), lineId: anchor), followsPlayback: true, reduceMotion: reduceMotion,
                onInteraction: {}, onDragStateChange: { _ in }, onTapLine: { _ in },
                waitingInterval: waiting, waitingPosition: { position }, waitingIsPlaying: playing
            ))
            view.layoutSubtreeIfNeeded()
        }
        precondition(panel.syncDisplay.waitingInterval == intro && introRequest?.lineId == document.lines[0].id,
                     "真实面板前奏请求应指向首句，并携带等待区间")
        show(waiting: panel.syncDisplay.waitingInterval, request: introRequest)
        try await settle("前奏等待区间必须显示圆点") { !view.waitingIndicator.isHidden && view.waitingIndicator.progress != nil }
        let viewport = view.contentSize
        let documentSize = view.documentView!.frame.size
        let rowFrames = view.textLayout.rows.map(\.frame)
        let firstProgress = view.waitingIndicator.progress!
        let firstPixels = pixels(of: view.waitingIndicator)
        position = 2_000
        try await settle("圆点进度必须随播放位置推进") { (view.waitingIndicator.progress ?? 0) > firstProgress }
        precondition(firstPixels != pixels(of: view.waitingIndicator), "播放推进应改变圆点实际绘制")
        try capture(view, name: "lyrics-waiting")
        show(waiting: intro, playing: false)
        try await settle("暂停像素比较前等待入场过渡完成") { !view.isScrollAnimating && view.documentView!.alphaValue == 1 }
        let pausedProgress = view.waitingIndicator.progress
        let pausedPixels = pixels(of: view.waitingIndicator)
        try await Task.sleep(for: .milliseconds(180))
        precondition(view.waitingIndicator.progress == pausedProgress && pixels(of: view.waitingIndicator) == pausedPixels,
                     "暂停时圆点必须停在当前位置，不能继续呼吸或倒计时")
        show(waiting: intro, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(40))
        precondition(!view.hasActiveDisplayLink, "减少动态效果时等待指示不能保留连续动画刷新")
        position = 4_000
        snapshot.positionMs = position
        snapshot.seq += 1
        coordinator.update(snapshot: snapshot)
        panel.apply(display: coordinator.currentDisplay())
        precondition(panel.scrollRequest?.lineId == introRequest?.lineId
                     && panel.scrollRequest?.requestId != introRequest?.requestId,
                     "前奏到首句即使 lineId 相同，也必须发出新的定位请求")
        show(waiting: panel.syncDisplay.waitingInterval, current: 0, reduceMotion: true, request: panel.scrollRequest)
        precondition(view.waitingIndicator.isHidden, "首句开始后必须隐藏前奏圆点")
        precondition(abs(view.contentView.bounds.minY - view.textLayout.rows[0].frame.minY) < 1,
                     "首句应从前奏槽移动到当前歌词锚点")
        precondition(view.contentSize == viewport && view.documentView!.frame.size == documentSize
                     && view.textLayout.rows.map(\.frame) == rowFrames,
                     "前奏圆点退出不能改变视口高度或歌词坐标")
        position = 9_000
        show(waiting: interlude, reduceMotion: true)
        precondition(!view.waitingIndicator.isHidden, "明确时间戳空白必须在间奏显示圆点")
        let dotFrame = view.waitingIndicator.convert(view.waitingIndicator.bounds, to: view.textLayout.textView)
        precondition(dotFrame.intersects(view.textLayout.rows[1].interactionFrame.insetBy(dx: -2, dy: -2)),
                     "间奏圆点应落在原空白行位置")
        position = 12_000
        show(waiting: nil, current: 2, reduceMotion: true)
        precondition(view.waitingIndicator.isHidden && view.contentSize == viewport
                     && view.documentView!.frame.size == documentSize && view.textLayout.rows.map(\.frame) == rowFrames,
                     "间奏结束接续双语长句不能重新排版或改变视口")
        try capture(view, name: "lyrics-bilingual-long-line")
        show(waiting: intro)
        try await settle("等待指示应恢复显示刷新") { view.hasActiveDisplayLink }
        view.prepareForRemoval()
        precondition(!view.hasActiveDisplayLink, "卸载等待歌词视图后必须停止显示刷新")
        print("PASS 前奏及明确空白圆点、真实进度绘制、暂停冻结、稳定视口、双语长句接续与等待卸载")
    }
}
