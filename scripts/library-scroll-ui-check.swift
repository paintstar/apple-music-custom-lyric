import AppKit
import SwiftUI
import ShinAppleKit
import ShinAppleData
import ShinMusicScript

private actor ScrollFixture: MusicLibraryBrowsing {
    func prepareMusicInBackground() async throws {}
    func loadPlaylists() async throws -> [MusicLibraryPlaylist] { [] }
    func loadTracks(in source: MusicLibrarySource, offset: Int, limit: Int) async throws -> MusicLibraryTrackPage {
        let end = min(offset + limit, 447)
        let tracks = (offset..<end).map { index in
            MusicLibraryTrack(persistentID: String(format: "%016X", index + 1),
                              title: "滚动恢复原创歌曲\(index)", artist: "纸船乐队", durationMs: 180_000)
        }
        return MusicLibraryTrackPage(tracks: tracks, totalCount: 447, nextOffset: end < 447 ? end : nil)
    }
    func playTrack(_ trackRef: String, in source: MusicLibrarySource) async throws {
        preconditionFailure("滚动回归不得发出播放命令")
    }
}

/// 只返回原创方形封面；通过生产取图入口填充ArtworkStore，不发送任何Music事件。
private final class ArtworkFixture: MusicScriptExecutor, MusicArtworkProviding {
    let persistentID: String
    init(persistentID: String) { self.persistentID = persistentID }
    func readCurrentTrackArtwork() -> MusicArtworkResult? {
        let side = 512
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.18, green: 0.44, blue: 0.64, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.85, green: 0.48, blue: 0.20, alpha: 1))
        context.fillEllipse(in: CGRect(x: 96, y: 96, width: 320, height: 320))
        guard let image = context.makeImage() else { return nil }
        return MusicArtworkResult(persistentID: persistentID,
                                  image: NSImage(cgImage: image, size: NSSize(width: side, height: side)))
    }
    func readSnapshot() -> MusicSnapshotOutcome { preconditionFailure("封面夹具不可采样") }
    func play() throws { preconditionFailure("封面夹具不可播放") }
    func pause() throws { preconditionFailure("封面夹具不可暂停") }
    func nextTrack() throws { preconditionFailure("封面夹具不可切歌") }
    func previousTrack() throws { preconditionFailure("封面夹具不可切歌") }
    func seek(toSeconds seconds: Double) throws { preconditionFailure("封面夹具不可seek") }
    func playPersistentID(_ persistentID: String) throws { preconditionFailure("封面夹具不可点播") }
}

/// 真实布局关闭Mock提示，但播放能力仍全部来自可控内存适配器。
private final class CapabilityFixture: PlaybackController, @unchecked Sendable {
    let base: MockPlaybackController
    private let lock = NSLock()
    private var submittedSeeks: [Int64] = []
    var seekCount: Int { lock.withLock { submittedSeeks.count } }
    var lastSeek: Int64? { lock.withLock { submittedSeeks.last } }
    init(_ base: MockPlaybackController) { self.base = base }
    func snapshot() -> PlaybackSnapshot {
        var snapshot = base.snapshot()
        snapshot.capabilities = PlaybackCapabilities(playPause: true, next: true, previous: true, seek: true)
        return snapshot
    }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle { base.subscribe(handler) }
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws { try await base.setQueue(items, startAt: startAt) }
    func play() async throws { try await base.play() }
    func pause() async throws { try await base.pause() }
    func next() async throws { try await base.next() }
    func previous() async throws { try await base.previous() }
    func seek(positionMs: Int64) async throws {
        lock.withLock { submittedSeeks.append(positionMs) }
        try await base.seek(positionMs: positionMs)
    }
    func dispose() { base.dispose() }
}

@main
private struct LibraryScrollUICheck {
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
        let browser = MusicLibraryBrowserModel(service: ScrollFixture())
        browser.startIfNeeded()
        try await eventually("完整原创资料库载入") { browser.filteredTracks.count == 447 && !browser.isLoading }
        let model = AppModel(isMock: true, controller: MockPlaybackController(), searchService: nil)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func makeHost() -> NSHostingView<AnyView> {
            NSHostingView(rootView: AnyView(
                MusicLibraryBrowserView(browser: browser, page: .constant(.music(.recent)))
                    .environmentObject(model)
            ))
        }
        var host: NSHostingView<AnyView>? = makeHost()
        window.contentView = host
        var scroller: NSScrollView?
        try await eventually("原生资料库滚动区域布局") {
            host?.layoutSubtreeIfNeeded()
            scroller = host.flatMap(findLibraryScroll)
            return (scroller?.documentView?.frame.height ?? 0) > 10_000
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let initialScroll = scroller, let document = initialScroll.documentView else {
            preconditionFailure("未找到原生滚动区域")
        }
        let target = (document.frame.height - initialScroll.contentView.bounds.height) * 0.5
        initialScroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        initialScroll.reflectScrolledClipView(initialScroll.contentView)
        try await Task.sleep(for: .milliseconds(250))
        let originalFraction = fraction(initialScroll)
        precondition(originalFraction > 0.40, "实际滚动必须发生")
        let originalDocumentHeight = document.frame.height
        let originalOffset = initialScroll.contentView.bounds.minY
        browser.selectedTrackID = browser.filteredTracks[223].id
        window.contentView = NSView()
        host = nil
        scroller = nil
        try await Task.sleep(for: .milliseconds(120))
        host = makeHost()
        window.contentView = host
        try await eventually("销毁重建后的滚动区域布局") {
            host?.layoutSubtreeIfNeeded()
            scroller = host.flatMap(findLibraryScroll)
            return (scroller?.documentView?.frame.height ?? 0) > 10_000
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let rebuilt = scroller else { preconditionFailure("重建滚动区域缺失") }
        let rebuiltHeight = rebuilt.documentView?.frame.height ?? 0
        let rebuiltOffset = rebuilt.contentView.bounds.minY
        precondition(abs(rebuiltHeight - originalDocumentHeight) < 2, "重建前后真实文档高度必须稳定")
        precondition(abs(rebuiltOffset - originalOffset) < 2, "重建前后真实滚动偏移必须稳定")
        precondition(browser.selectedTrackID == browser.filteredTracks[223].id, "选择应保留")
        print("AUTOMATED_PASS: native library scroll survives destruction and recreation")
        try await checkContentPlayer(browser: browser)
    }

    @MainActor private static func checkContentPlayer(browser: MusicLibraryBrowserModel) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shin-content-mouse-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let document = LyricDocument(lines: (0..<24).map {
            LyricLine(startMs: Int64($0) * 7_000, text: "纸船经过第\($0)道晨光", translations: ["zh-Hans": Translation(text: "原创译文第\($0)行")])
        })
        let persistentID = "0000000000000001"
        let binding = SongBinding(persistentID: persistentID, lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let controller = MockPlaybackController()
        controller.setMockQueue([MockTrack(identity: CatalogIdentity(storefront: "us", catalogSongId: "content-fixture"),
                                          title: "滚动恢复原创歌曲0", artist: "纸船乐队", durationMs: 180_000,
                                          trackRef: binding.trackKey)])
        try await controller.pause()
        try await controller.seek(positionMs: 60_000)
        let playback = CapabilityFixture(controller)
        let model = AppModel(isMock: false, controller: playback, searchService: nil,
                             makeLyricsDatabase: { LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: URL(fileURLWithPath: "/tmp")) })
        model.musicLibraryBrowser = browser
        model.playbackOptions = PlaybackOptionsModel(service: MockPlaybackOptionsController())
        await model.start()
        try await eventually("原创歌词文档完成异步关联") {
            guard let panel = model.lyricsPanel, case .ready = panel.state else { return false }
            return true
        }
        let artworkController = MusicScriptPlaybackController(executor: ArtworkFixture(persistentID: persistentID),
                                                              startsSampler: false)
        defer { artworkController.dispose() }
        model.artworkStore.handleTrackChange(PlaybackSnapshot(), controller: artworkController)
        model.artworkStore.handleTrackChange(model.snapshot, controller: artworkController)
        try await eventually("原创方形NSImage通过生产入口载入") { model.artworkStore.currentArtwork?.size.width == 512 }
        let keys = ["player.presentationMode", "player.compactReturnMode"]
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let argumentDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var fixtureDefaults = argumentDefaults
        fixtureDefaults["player.presentationMode"] = "browser"
        fixtureDefaults["player.compactReturnMode"] = "browser"
        UserDefaults.standard.setVolatileDomain(fixtureDefaults, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(argumentDefaults, forName: UserDefaults.argumentDomain)
            for (key, value) in previous {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for size in [NSSize(width: 1404, height: 996), NSSize(width: 1163, height: 768), NSSize(width: 320, height: 640)] {
            let isCompact = size.width < PlayerWindowController.compactBreakpoint
            let suite = "shin-content-mouse-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.register(defaults: ["player.hasSavedPresentation": true, "player.showLibraryLyrics": true])
            defer { defaults.removePersistentDomain(forName: suite) }
            var compactAccessibility: (voiceOver: Bool, switchControl: Bool)?
            let host = NSHostingView(rootView: ContentView().environmentObject(model).defaultAppStorage(defaults)
                .background(CompactAccessibilityProbe { voiceOver, switchControl in
                    compactAccessibility = (voiceOver, switchControl)
                }))
            let initialSize = isCompact ? NSSize(width: 1163, height: 768) : size
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: initialSize),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await eventually("完整ContentView浮栏布局") {
                host.layoutSubtreeIfNeeded()
                return findSlider(host) != nil && findLibraryScroll(host) != nil
            }
            try await Task.sleep(for: .milliseconds(200))
            try checkWindowButtons(window)
            guard let slider = findSlider(host), let scroll = findLibraryScroll(host) else {
                throw failure("完整层级中的进度/列表缺失")
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_000))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(120))
            if isCompact {
                try await checkCompactPlayer(window: window, host: host, size: size,
                                             expectedOffset: scroll.contentView.bounds.minY,
                                             accessibility: { compactAccessibility })
                print("AUTOMATED_PASS: adaptive compact idle layout and library restoration at 320x640")
                continue
            }
            if size.width >= 900 {
                try await eventually("鼠标测试前真实歌词右栏必须已打开") {
                    allViews(host).contains { $0 is LyricsScrollView }
                }
            }
            saveSnapshot(host: host, size: size)
            if size.width == 1404 {
                try await captureScrubberAppearance(window: window, host: host, slider: slider, playback: playback)
                try await checkMenuClick(at: try floatingPoint("navigation", host: host),
                                         expectedItem: "设置", window: window)
                if let lyrics = allViews(host).first(where: { $0 is LyricsScrollView }) {
                    let frame = lyrics.convert(lyrics.bounds, to: nil)
                    let side = PlaybackControlSizing.optionSide
                    let menuPoint = NSPoint(x: frame.maxX - 1.5 * side - 4, y: frame.maxY + 16 + side / 2)
                    let seeksBeforeMenu = playback.seekCount
                    try await checkMenuClick(at: menuPoint,
                                             expectedItem: "显示译文", window: window)
                    try require(playback.seekCount == seeksBeforeMenu, "顶部歌词菜单不得触发歌词重听")
                }
            }
            for fraction: CGFloat in [0.2, 0.5, 0.8] {
                for y in [slider.bounds.minY + 2, slider.bounds.midY, slider.bounds.maxY - 2] {
                    let point = slider.convert(NSPoint(x: slider.bounds.width * fraction, y: y), to: nil)
                    try require(hit(at: point, host: host) === slider,
                                "完整ContentView进度上下边缘必须可点击且不被封面背景截获")
                }
            }
            try require(abs(slider.bounds.height - ThinPlaybackSliderSizing.hitHeight) < 0.01
                        && slider.alignmentRect(forFrame: slider.frame) == slider.frame,
                        "浮栏进度原生边界必须与24点可见控制槽位一致")
            for local in [NSPoint(x: slider.bounds.midX, y: slider.bounds.minY - 1),
                          NSPoint(x: slider.bounds.midX, y: slider.bounds.maxY + 1),
                          NSPoint(x: slider.bounds.minX - 1, y: slider.bounds.midY),
                          NSPoint(x: slider.bounds.maxX + 1, y: slider.bounds.midY)] {
                try require(hit(at: slider.convert(local, to: nil), host: host) !== slider,
                            "浮栏进度不得抢占控制槽位以外的点击")
            }
            let sampling = startSamples(controller)
            defer { sampling.cancel() }
            try await controller.play()
            try await eventually("开启30fps播放布局") { model.snapshot.status == .playing }
            try await Task.sleep(for: .milliseconds(600))
            try await clickFloating("play", window: window, host: host)
            try await eventually("播放中跨多帧点击暂停必须进入paused") { model.snapshot.status == .paused }
            try await clickFloating("play", window: window, host: host)
            try await eventually("完整层级点击播放必须进入playing") { model.snapshot.status == .playing }
            try await Task.sleep(for: .milliseconds(600))
            let liveSlider = findSlider(host)!
            let sliderIdentity = ObjectIdentifier(liveSlider)
            let commitsBefore = playback.seekCount
            let knob = (liveSlider.cell as! NSSliderCell).knobRect(flipped: liveSlider.isFlipped)
            func sliderPoint(_ fraction: CGFloat) -> NSPoint {
                liveSlider.convert(NSPoint(x: knob.width / 2 + fraction * (liveSlider.bounds.width - knob.width),
                                           y: liveSlider.bounds.midY), to: nil)
            }
            let edgeY = size.width == 1404 ? liveSlider.bounds.minY + 2 : liveSlider.bounds.maxY - 2
            let downPoint = liveSlider.convert(NSPoint(x: knob.midX, y: edgeY), to: nil)
            send(.leftMouseDown, at: downPoint, window: window)
            for fraction: CGFloat in [0.45, 0.6, 0.7] {
                try await Task.sleep(for: .milliseconds(110))
                send(.leftMouseDragged, at: sliderPoint(fraction), window: window)
                try require(findSlider(host).map(ObjectIdentifier.init) == sliderIdentity,
                            "30fps播放时可见进度控件不得被布局重新替换")
            }
            let previewTarget = Int64(liveSlider.doubleValue)
            let pixelMs = (liveSlider.maxValue - liveSlider.minValue) / (liveSlider.bounds.width - knob.width)
            try require(abs(liveSlider.doubleValue - 126_000) < pixelMs, "完整层级拖动位置与鼠标应在一个原生像素内一致")
            try require(playback.seekCount == commitsBefore, "权威采样可继续推进，松手前不得提交seek")
            send(.leftMouseUp, at: sliderPoint(0.7), window: window)
            try await eventually("完整层级拖动松手必须提交实际预览位置") {
                playback.seekCount == commitsBefore + 1 && playback.lastSeek == previewTarget
                    && (model.snapshot.positionMs ?? -1) >= previewTarget
                    && model.snapshot.positionMs == controller.snapshot().positionMs
            }
            if size.width >= 900 {
                try require(allViews(host).contains { $0 is LyricsScrollView }, "宽窗必须显示真实歌词右栏")
                if size.width == 1404 {
                    try await checkRailAnimation(window: window, host: host, defaults: defaults)
                } else {
                    try await clickFloating("lyrics", window: window, host: host)
                    try await eventually("浮栏歌词按钮必须实际移除右栏") { !allViews(host).contains { $0 is LyricsScrollView } }
                    try await clickFloating("lyrics", window: window, host: host)
                    try await eventually("浮栏歌词按钮必须重新显示右栏") { allViews(host).contains { $0 is LyricsScrollView } }
                    try await Task.sleep(for: .milliseconds(350))
                }
            }
            try await clickFloating("cover", window: window, host: host)
            try await eventually("浮栏封面必须打开完整播放器") { floatingBackground(host) == nil }
            try await controller.pause()
            try await controller.seek(positionMs: 60_000)
            try await eventually("下一尺寸重置播放位置") { model.snapshot.positionMs == 60_000 }
            print("AUTOMATED_PASS: full ContentView mouse controls with original NSImage at \(Int(size.width))x\(Int(size.height))")
        }
    }

    @MainActor private static func startSamples(_ controller: MockPlaybackController) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard !Task.isCancelled else { return }
                controller.advanceTime(byMs: 400)
            }
        }
    }

    /// 用同一原创完整底栏审查外观与中间帧；只预览，结束时取消，不改变播放位置。
    @MainActor private static func captureScrubberAppearance(window: NSWindow, host: NSView, slider: NSSlider,
                                                            playback: CapabilityFixture) async throws {
        guard let hud = floatingBackground(host) else { throw failure("缺少底栏外观截图区域") }
        slider.updateTrackingAreas()
        guard let owner = slider.trackingAreas.first(where: {
            ($0.owner as? NSView) === slider && $0.options.contains(.mouseEnteredAndExited)
        })?.owner as? NSResponder else { throw failure("细轨道未建立局部tracking") }
        let crop = host.convert(hud.bounds, from: hud).insetBy(dx: -8, dy: -8)
        func capture(_ state: String) {
            saveSnapshot(host: host, size: host.bounds.size, suffix: "-scrubber-\(state)", rect: crop)
        }
        func hover(_ entered: Bool) {
            let event = NSEvent.enterExitEvent(with: entered ? .mouseEntered : .mouseExited,
                                              location: slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, trackingNumber: 0, userData: nil)!
            if entered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
        }
        let seekCount = playback.seekCount
        capture("idle")
        hover(true)
        try await Task.sleep(for: .milliseconds(60))
        capture("enter-mid")
        hover(false)
        capture("reverse-start")
        try await Task.sleep(for: .milliseconds(80))
        capture("reverse-mid")
        try await Task.sleep(for: .milliseconds(180))
        hover(true)
        try await Task.sleep(for: .milliseconds(220))
        capture("hover")
        let knob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
        let pressPoint = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        send(.leftMouseDown, at: pressPoint, window: window)
        try await Task.sleep(for: .milliseconds(30))
        capture("press-mid")
        try await Task.sleep(for: .milliseconds(90))
        capture("pressed")
        slider.cancelOperation(nil)
        send(.leftMouseUp, at: pressPoint, window: window)
        hover(false)
        try await Task.sleep(for: .milliseconds(260))
        window.makeFirstResponder(nil)
        window.makeFirstResponder(slider)
        capture("keyboard")
        window.makeFirstResponder(nil)
        try require(playback.seekCount == seekCount, "外观预览与取消不得发出seek")
    }

    @MainActor private static func checkWindowButtons(_ window: NSWindow) throws {
        guard let close = window.standardWindowButton(.closeButton) else {
            throw failure("原生窗口关闭按钮缺失")
        }
        let closeFrame = close.convert(close.bounds, to: nil)
        try require(closeFrame.minX >= 18 && window.frame.height - closeFrame.maxY >= 8,
                    "原生窗口按钮应避开圆角边框并保留顶部留白")
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            try require(parent.bounds.contains(button.frame), "原生窗口按钮不得被父容器裁切")
        }
    }

    @MainActor private static func checkCompactPlayer(window: NSWindow, host: NSView, size: NSSize,
                                                      expectedOffset: CGFloat,
                                                      accessibility: () -> (voiceOver: Bool, switchControl: Bool)?) async throws {
        var pointerToRestore: CGPoint?
        defer {
            if let pointerToRestore {
                CGWarpMouseCursorPosition(pointerToRestore)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: pointerToRestore, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        let originalSize = host.bounds.size
        window.setContentSize(size)
        try await eventually("缩窄应自动替换浮栏为专用播放器") {
            host.layoutSubtreeIfNeeded()
            return floatingBackground(host) == nil && findSlider(host) != nil
                && allViews(host).contains { $0 is LyricsScrollView }
        }
        // 缩窗可能把测试窗口移到真实指针下；先建立窗口外前提，再验证空闲显隐。
        // 只在确有重叠时临时挪开，向系统投递移动事件使 SwiftUI 收到真实退出，退出时恢复。
        let pointer = NSEvent.mouseLocation
        if window.frame.contains(pointer) {
            guard let originalQuartzPoint = CGEvent(source: nil)?.location else {
                throw failure("无法读取指针位置，不能建立小窗空闲测试前提")
            }
            let margin: CGFloat = 16 // 避开测试窗口边缘、菜单栏和 Dock 的命中边界。
            let outside = NSScreen.screens.lazy.flatMap { screen -> [NSPoint] in
                let frame = screen.visibleFrame.insetBy(dx: margin, dy: margin)
                return [NSPoint(x: frame.minX, y: frame.minY), NSPoint(x: frame.maxX, y: frame.minY),
                        NSPoint(x: frame.minX, y: frame.maxY), NSPoint(x: frame.maxX, y: frame.maxY)]
            }.first { !window.frame.insetBy(dx: -margin, dy: -margin).contains($0) }
            guard let outside, CGPreflightPostEventAccess() else {
                throw failure("无法安全移出真实指针或缺少事件投递权限，不能建立小窗空闲测试前提")
            }
            // 使用同一当前位置在两套公共坐标系中的差值，兼容多显示器和不同坐标原点。
            let target = CGPoint(x: originalQuartzPoint.x + outside.x - pointer.x,
                                 y: originalQuartzPoint.y - (outside.y - pointer.y))
            guard let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: target, mouseButton: .left) else {
                throw failure("无法建立小窗指针退出事件")
            }
            pointerToRestore = originalQuartzPoint
            try require(CGWarpMouseCursorPosition(target) == .success, "无法临时将真实指针移出测试窗口")
            moved.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(350))
        try checkWindowButtons(window)
        let lyrics = allViews(host).first { $0 is LyricsScrollView }!
        let lyricsFrame = host.convert(lyrics.bounds, from: lyrics)
        let compactSlider = findSlider(host)!
        try require(!window.frame.contains(NSEvent.mouseLocation), "小窗空闲验证时真实指针必须在测试窗口外")
        guard let accessibility = accessibility() else { throw failure("尚未读取小窗辅助功能环境") }
        let keepsControlsVisible = accessibility.voiceOver || accessibility.switchControl
        let opacity = viewOpacity(compactSlider)
        try require(keepsControlsVisible ? opacity >= 0.99 : opacity == 0,
                    "窗口外控制显隐应尊重当前辅助功能配置；voiceOver=\(accessibility.voiceOver)，switchControl=\(accessibility.switchControl)，opacity=\(opacity)")
        try require(lyricsFrame.width <= size.width && lyricsFrame.height >= size.height * 0.4,
                    "小窗歌词视口应保留至少四成高度且不横向溢出")
        saveSnapshot(host: host, size: size, suffix: "-idle")
        print("NOT_RUN: real pointer hover, compact mouse controls and expand button require actual pointer verification; synthesized events did not trigger SwiftUI.onHover")
        window.setContentSize(originalSize)
        try await eventually("放大应自动恢复原资料库") {
            host.bounds.width >= PlayerWindowController.compactBreakpoint && floatingBackground(host) != nil
        }
        try await eventually("小窗放大应恢复原资料库滚动") {
            guard let restored = findLibraryScroll(host) else { return false }
            return abs(restored.contentView.bounds.minY - expectedOffset) < 2
        }
        await Task.yield()
        try checkWindowButtons(window)
    }

    private struct CompactAccessibilityProbe: View {
        @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
        @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
        let onUpdate: (Bool, Bool) -> Void
        var body: some View {
            Color.clear.allowsHitTesting(false).accessibilityHidden(true)
                .onAppear { onUpdate(voiceOver, switchControl) }
                .onChange(of: voiceOver) { _, _ in onUpdate(voiceOver, switchControl) }
                .onChange(of: switchControl) { _, _ in onUpdate(voiceOver, switchControl) }
        }
    }

    @MainActor private static func viewOpacity(_ view: NSView) -> CGFloat {
        var opacity: CGFloat = 1
        var current: NSView? = view
        while let value = current {
            opacity *= value.alphaValue
            current = value.superview
        }
        return opacity
    }

    @MainActor private static func floatingBackground(_ host: NSView) -> NSVisualEffectView? {
        allViews(host).compactMap { $0 as? NSVisualEffectView }
            .first { $0.material == .hudWindow && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 200 }
    }

    @MainActor private final class MenuObservation: NSObject {
        let expectedItem: String
        var opened = false
        private var menu: NSMenu?

        init(expectedItem: String) { self.expectedItem = expectedItem }

        @objc func didBegin(_ notification: Notification) {
            guard let menu = notification.object as? NSMenu else { return }
            opened = menu.items.contains { $0.title == expectedItem }
            self.menu = menu
            let timer = Timer(timeInterval: 0.12, target: self, selector: #selector(closeMenu), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }

        @objc private func closeMenu() { menu?.cancelTrackingWithoutAnimation() }
    }

    @MainActor private static func checkMenuClick(at point: NSPoint, expectedItem: String, window: NSWindow) async throws {
        let observation = MenuObservation(expectedItem: expectedItem)
        NotificationCenter.default.addObserver(observation, selector: #selector(MenuObservation.didBegin(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(observation) }
        queueClick(at: point, window: window, pressDuration: 0.04)
        try await eventually("菜单图标原生鼠标点击应打开实际菜单：\(expectedItem)") { observation.opened }
        try await Task.sleep(for: .milliseconds(250))
        print("AUTOMATED_PASS: native menu click opens \(expectedItem)")
    }

    /// 一个宽窗覆盖动画中间态与快速反向；终点必须真实卸载，不只隐藏透明度。
    @MainActor private static func checkRailAnimation(window: NSWindow, host: NSView, defaults: UserDefaults) async throws {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await eventually("原生鼠标测试环境未就绪：测试应用必须激活，窗口必须为key") {
            NSApplication.shared.isActive && window.isKeyWindow
        }
        for visible in [false, true] {
            guard let scroll = findLibraryScroll(host), let slider = findSlider(host), let hud = floatingBackground(host) else {
                throw failure("动画检查缺少资料库或进度")
            }
            let initialLibrary = displayedFrame(scroll, in: host)
            let initialSlider = displayedFrame(slider, in: host)
            let initialHUD = displayedFrame(hud, in: host)
            var libraryFrames: [NSRect] = []
            var sliderFrames: [NSRect] = []
            var sawPinkGlyph = false
            try require(defaults.bool(forKey: "player.showLibraryLyrics") != visible, "点击前右栏开关必须处于相反状态")
            queueClick(at: try floatingPoint("lyrics", host: host), window: window, pressDuration: 0.04)
            let captureRect = NSRect(x: 0, y: host.bounds.height - 120, width: host.bounds.width, height: 120)
            for frame in 0..<16 {
                try await Task.sleep(for: .milliseconds(25))
                libraryFrames.append(displayedFrame(scroll, in: host))
                sliderFrames.append(displayedFrame(slider, in: host))
                let before = displayedFrame(hud, in: host)
                guard let bitmap = saveSnapshot(host: host, size: host.bounds.size,
                                                suffix: frame == 2 ? "-rail-\(visible)-transition" : nil, rect: captureRect) else {
                    throw failure("动画图标截图不可用")
                }
                let after = displayedFrame(hud, in: host)
                let target = hud.convert(hud.bounds, to: nil)
                let slot = min(initialHUD.maxX, target.maxX) - 114
                let centerY = host.convert(NSPoint(x: before.midX, y: before.midY), from: nil).y - captureRect.minY
                let region = NSRect(x: slot - 18, y: centerY - 18,
                                    width: abs(initialHUD.maxX - target.maxX) + 36, height: 36)
                if let glyph = pinkGlyphExtent(bitmap, region: region, logicalWidth: captureRect.width) {
                    sawPinkGlyph = true
                    // glyph宽约20点；12点余量含半宽和抗锯齿，截图期间HUD本身仍可移动。
                    let allowed = (min(before.maxX, after.maxX) - 126)...(max(before.maxX, after.maxX) - 102)
                    try require(glyph.lowerBound >= allowed.lowerBound && glyph.upperBound <= allowed.upperBound,
                                "歌词图标必须随HUD槽位移动，实际粉色区间\(glyph)，允许区间\(allowed)")
                }
            }
            try require(defaults.bool(forKey: "player.showLibraryLyrics") == visible, "单次鼠标点击必须改变右栏开关状态")
            try require(allViews(host).contains { $0 is LyricsScrollView } == visible,
                        "歌词栏动画结束必须与实际挂载状态一致")
            let finalLibrary = displayedFrame(scroll, in: host)
            let finalSlider = displayedFrame(slider, in: host)
            try require(abs(finalLibrary.width - initialLibrary.width) > 200, "展开或收起歌词应重新分配资料库宽度")
            if !reducedMotion {
                try require(libraryFrames.contains { between($0.width, initialLibrary.width, finalLibrary.width) },
                            "资料库宽度应经过动画中间态：\(libraryFrames.map(\.width))")
                try require(sliderFrames.contains { between($0.minX, initialSlider.minX, finalSlider.minX) },
                            "浮栏应随资料库平滑移动：\(sliderFrames.map(\.minX))")
            }
            if visible { try require(sawPinkGlyph, "开栏采样必须实际看见粉色歌词图标") }
            saveSnapshot(host: host, size: host.bounds.size, suffix: "-rail-\(visible)-stable", rect: captureRect)
        }
        // 快速反向尚未结束的转场，最终仍显示右栏；不在隐藏视图中留下事件拦截层。
        for index in 1...4 {
            let previous = defaults.bool(forKey: "player.showLibraryLyrics")
            let point = try floatingPoint("lyrics", host: host)
            let downDiagnostic = rapidRailClickDiagnostic(index: index, phase: "beforeDown", point: point,
                                                         window: window, host: host, defaults: defaults)
            var releasePoint: NSPoint?
            var upDiagnostic = "尚未收到松开事件"
            queueMovingLyricsClick(at: point, window: window, host: host) { current in
                releasePoint = current
                upDiagnostic = current.map {
                    rapidRailClickDiagnostic(index: index, phase: "beforeUp", point: $0,
                                             window: window, host: host, defaults: defaults)
                } ?? "松开时未找到歌词按钮槽位"
            }
            try await Task.sleep(for: .milliseconds(80))
            if releasePoint == nil || defaults.bool(forKey: "player.showLibraryLyrics") == previous {
                let finalDiagnostic = rapidRailClickDiagnostic(index: index, phase: "after80ms",
                                                               point: releasePoint ?? point,
                                                               window: window, host: host, defaults: defaults)
                throw failure("第\(index)次移动目标鼠标手势必须实际翻转右栏开关；\(downDiagnostic)；\(upDiagnostic)；\(finalDiagnostic)")
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        try require(allViews(host).contains { $0 is LyricsScrollView }, "快速切换结束后右栏应处于最后请求状态")
        guard let slider = findSlider(host) else { throw failure("快速切换后缺少进度条") }
        for fraction: CGFloat in [0.2, 0.5, 0.8] {
            let point = slider.convert(NSPoint(x: slider.bounds.width * fraction, y: slider.bounds.midY), to: nil)
            try require(hit(at: point, host: host) === slider, "快速切换后不得残留透明鼠标遮挡")
        }
        print("AUTOMATED_PASS: lyrics rail transition, glyph stays in HUD slot and rapid reversal; systemReduceMotion=\(reducedMotion)")
    }

    /// 原创夹具关闭随机播放；底栏该区域内只有歌词状态使用粉色。
    @MainActor private static func pinkGlyphExtent(_ bitmap: NSBitmapImageRep, region: NSRect,
                                                   logicalWidth: CGFloat) -> ClosedRange<CGFloat>? {
        let scale = CGFloat(bitmap.pixelsWide) / logicalWidth
        var minimum = bitmap.pixelsWide
        var maximum = -1
        for y in stride(from: max(0, Int(region.minY * scale)), to: min(bitmap.pixelsHigh, Int(region.maxY * scale)), by: 2) {
            for x in stride(from: max(0, Int(region.minX * scale)), to: min(bitmap.pixelsWide, Int(region.maxX * scale)), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.redComponent > 0.65, color.redComponent - color.greenComponent > 0.30 else { continue }
                minimum = min(minimum, x)
                maximum = max(maximum, x)
            }
        }
        return maximum >= minimum ? (CGFloat(minimum) / scale)...(CGFloat(maximum) / scale) : nil
    }

    private static func between(_ value: CGFloat, _ first: CGFloat, _ last: CGFloat) -> Bool {
        value > min(first, last) + 1 && value < max(first, last) - 1
    }

    /// 仅记录原创 UI 夹具的布尔状态、命中类型及几何差，区分点击未提交与视图挂载异常。
    @MainActor private static func rapidRailClickDiagnostic(index: Int, phase: String, point: NSPoint,
                                                           window: NSWindow, host: NSView, defaults: UserDefaults) -> String {
        let target = hit(at: point, host: host)
        let hitType = target.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let hud = floatingBackground(host)
        let modelFrame = hud.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let visibleFrame = hud.map { displayedFrame($0, in: host) } ?? .zero
        let modelDelta = point.x - (modelFrame.maxX - 114)
        let visibleDelta = point.x - (visibleFrame.maxX - 114)
        return "click=\(index) phase=\(phase) preference=\(defaults.bool(forKey: "player.showLibraryLyrics")) mounted=\(allViews(host).filter { $0 is LyricsScrollView }.count) key=\(window.isKeyWindow) hit=\(hitType) point=\(point) modelSlotDeltaX=\(modelDelta) visibleSlotDeltaX=\(visibleDelta)"
    }

    @MainActor private static func displayedFrame(_ view: NSView, in host: NSView) -> NSRect {
        guard let layer = view.layer, let root = host.layer else { return view.convert(view.bounds, to: nil) }
        let current = layer.presentation() ?? layer
        let rootPresentation = root.presentation() ?? root
        return host.convert(current.convert(current.bounds, to: rootPresentation), to: nil)
    }

    @MainActor private static func floatingPoint(_ control: String, host: NSView) throws -> NSPoint {
        guard let background = floatingBackground(host) else { throw failure("缺少可见浮栏") }
        let frame = background.convert(background.bounds, to: nil)
        let narrow = frame.width < 560
        // 点位来自本回归实际渲染PNG与固定控件尺寸；以真实HUD区域定位，不依赖屏幕绝对坐标或AXPress。
        let point: NSPoint
        switch control {
        case "play":
            point = NSPoint(x: frame.minX + 112, y: narrow ? frame.minY + 30 : frame.midY)
        case "lyrics":
            point = NSPoint(x: frame.maxX - 114, y: narrow ? frame.minY + 30 : frame.midY)
        case "navigation":
            point = NSPoint(x: frame.maxX - 74, y: narrow ? frame.minY + 30 : frame.midY)
        case "cover":
            point = NSPoint(x: frame.minX + (narrow ? 38 : 244), y: narrow ? frame.maxY - 33 : frame.midY)
        default: throw failure("未知鼠标测试控件")
        }
        return point
    }

    /// 转场中的按钮会移动：按下后跟随一次最新槽位，再以原生拖动/松开完成同一个手势。
    /// 保留 20ms 按住与每 80ms 一次的转场反向，不重试点击，也不直接调用按钮动作。
    @MainActor private static func queueMovingLyricsClick(at point: NSPoint, window: NSWindow, host: NSView,
                                                          onRelease: @escaping @MainActor (NSPoint?) -> Void) {
        let timer = Timer(timeInterval: 0.02, repeats: false) { _ in
            MainActor.assumeIsolated {
                let current = try? floatingPoint("lyrics", host: host)
                onRelease(current)
                // 即使夹具已丢失目标，也要松开本次按键；调用方会明确报告失败，不能遗留按下状态。
                let release = current ?? point
                NSApplication.shared.postEvent(mouseEvent(.leftMouseDragged, at: release, window: window), atStart: false)
                NSApplication.shared.postEvent(mouseEvent(.leftMouseUp, at: release, window: window), atStart: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        NSApplication.shared.postEvent(mouseEvent(.leftMouseDown, at: point, window: window), atStart: false)
    }

    @MainActor private static func queueClick(at point: NSPoint, window: NSWindow, pressDuration: TimeInterval = 0.18) {
        let timer = Timer(timeInterval: pressDuration, repeats: false) { _ in
            MainActor.assumeIsolated {
                NSApplication.shared.postEvent(mouseEvent(.leftMouseUp, at: point, window: window), atStart: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        NSApplication.shared.postEvent(mouseEvent(.leftMouseDown, at: point, window: window), atStart: false)
    }

    @MainActor private static func clickFloating(_ control: String, window: NSWindow, host: NSView) async throws {
        queueClick(at: try floatingPoint(control, host: host), window: window)
        try await Task.sleep(for: .milliseconds(350))
    }

    @MainActor private static func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews($0) }
    }

    @discardableResult
    @MainActor private static func saveSnapshot(host: NSView, size: NSSize, suffix: String? = "", rect: NSRect? = nil) -> NSBitmapImageRep? {
        let region = rect ?? host.bounds
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: region) {
            host.cacheDisplay(in: region, to: bitmap)
            if let suffix, let data = bitmap.representation(using: .png, properties: [:]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("shin-content-hit-\(Int(size.width))\(suffix).png")
                try? data.write(to: url)
            }
            return bitmap
        }
        return nil
    }

    @MainActor private static func findSlider(_ view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider, slider.accessibilityLabel() == "播放进度",
           !slider.isHiddenOrHasHiddenAncestor, slider.bounds.width > 0 { return slider }
        return view.subviews.lazy.compactMap { findSlider($0) }.first
    }

    @MainActor private static func hit(at point: NSPoint, host: NSView) -> NSView? {
        host.hitTest(host.superview?.convert(point, from: nil) ?? point)
    }

    @MainActor private static func send(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        window.sendEvent(mouseEvent(type, at: point, window: window))
    }

    @MainActor private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) -> NSEvent {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(event.window === window, "事件必须属于当前真实窗口")
        return event
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LibraryMouseUICheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    @MainActor private static func findLibraryScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1_000 { return scroll }
        for child in view.subviews {
            if let found = findLibraryScroll(child) { return found }
        }
        return nil
    }

    @MainActor private static func fraction(_ view: NSScrollView) -> CGFloat {
        let maximum = max(1, (view.documentView?.frame.height ?? 0) - view.contentView.bounds.height)
        return view.contentView.bounds.minY / maximum
    }

    @MainActor private static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw failure(message)
    }
}
