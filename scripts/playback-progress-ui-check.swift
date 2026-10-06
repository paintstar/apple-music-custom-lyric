import AppKit
import Foundation
import SwiftUI
import ShinAppleKit
import ShinAppleData

/// 与生产歌词换句同时驱动生产浮栏；只使用临时本地库和原创内存快照。
@MainActor
enum PlaybackProgressUICheck {
    static func runChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shin-progress-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBLyricsStore(path: directory.appendingPathComponent("lyrics.sqlite").path)
        let document = LyricDocument(lines: (0..<80).map { index in
            LyricLine(startMs: Int64(index) * 400, text: "Paper boats cross original morning \(index)",
                      translations: ["zh-Hans": Translation(text: "原创纸船经过第 \(index) 道晨光")])
        })
        let binding = SongBinding(persistentID: "00000000F0000001", lyricDocumentId: document.id)
        try await store.save(document: document, binding: binding)
        let controller = ProgressController(PlaybackSnapshot(
            trackEpoch: 1, title: "原创进度回归", artist: "纸船乐队", positionMs: 8_000,
            durationMs: 32_000, status: .playing, sessionEpoch: 1, trackRef: binding.trackKey,
            sampledAtMonotonicMs: AppModel.monotonicNowMs(),
            capabilities: PlaybackCapabilities(playPause: true, next: true, previous: true, seek: true)
        ))
        let model = AppModel(isMock: false, controller: controller, searchService: nil,
                             makeLyricsDatabase: {
            LyricsDatabase.Database(store: store, locationDescription: "临时测试库", directory: directory)
        })
        model.playbackOptions = PlaybackOptionsModel(service: MockPlaybackOptionsController())
        await model.start()
        try await settle("原创歌词关联") {
            guard let panel = model.lyricsPanel, case .ready = panel.state else { return false }
            return true
        }
        let host = NSHostingView(rootView:
            HStack(spacing: 0) {
                Color.gray.opacity(0.12)
                    .overlay(alignment: .bottom) {
                        PlayerBarView(artworkStore: model.artworkStore, availableWidth: 650)
                            .padding(20)
                    }
                MusicLibraryLyricsRail(artworkStore: model.artworkStore, onClose: {})
                    .frame(width: 260)
            }
            .environmentObject(model)
            .environment(\.colorScheme, .dark)
        )
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 950, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await settle("生产进度和歌词控件挂载") {
            host.layoutSubtreeIfNeeded()
            guard let slider = findSlider(host), findLyrics(host) != nil else { return false }
            return slider.isEnabled && slider.maxValue == 32_000 && slider.doubleValue >= 8_000
        }
        let slider = findSlider(host)!
        let lyrics = findLyrics(host)!
        let identity = ObjectIdentifier(slider)
        slider.updateTrackingAreas()
        let trackingArea = slider.trackingAreas.first {
            ($0.owner as? NSView) === slider && $0.options.contains(.mouseEnteredAndExited)
        }!
        let initialFrame = slider.frame
        let initialBounds = slider.bounds
        let restingPaint = trackPaint(slider)
        let start = controller.snapshot().sampledAtMonotonicMs
        var lastPosition = slider.doubleValue
        var lastRequest = model.lyricsPanel?.scrollRequest?.requestId
        var requestChanges = 0
        var animatedFrames = 0
        var sampleBucket: Int64 = -1
        for _ in 0..<180 {
            let elapsed = AppModel.monotonicNowMs() - start
            let bucket = elapsed / 400
            if bucket != sampleBucket {
                sampleBucket = bucket
                controller.advance(to: 8_000 + elapsed)
            }
            try await Task.sleep(for: .milliseconds(17))
            precondition(findSlider(host).map(ObjectIdentifier.init) == identity,
                         "歌词换句不能重建原生进度控件")
            precondition(slider.frame == initialFrame && slider.bounds == initialBounds,
                         "歌词自动滚动不能改变底栏进度布局")
            precondition(slider.isEnabled && slider.doubleValue >= lastPosition - 60,
                         "连续播放换句不得让进度归零或明显回退：\(lastPosition) → \(slider.doubleValue)")
            let paint = trackPaint(slider)
            precondition(abs(paint.height - restingPaint.height) < 0.15
                         && abs(paint.opacity - restingPaint.opacity) < 0.02,
                         "歌词换句不得使静止轨道粗细或亮度闪变")
            precondition(slider.trackingAreas.contains { $0 === trackingArea },
                         "歌词滚动不得拆除并重建进度悬停区")
            precondition(slider.alphaValue == 1 && (slider.layer?.presentation()?.opacity ?? 1) == 1,
                         "歌词过渡不能使进度条淡出")
            lastPosition = slider.doubleValue
            let request = model.lyricsPanel?.scrollRequest?.requestId
            if request != lastRequest { requestChanges += 1; lastRequest = request }
            if lyrics.isScrollAnimating { animatedFrames += 1 }
        }
        precondition(requestChanges >= 5 && animatedFrames > 10,
                     "必须覆盖多次实际换句和连续自动滚动，不能用静态歌词代替")
        let entered = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: slider.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!
        (trackingArea.owner as! NSResponder).mouseEntered(with: entered)
        try await settle("悬停外观应完成原生动画") { abs(trackPaint(slider).height - 5.5) < 0.2 }
        let hoveredPaint = trackPaint(slider)
        var hoverRequestChanges = 0
        for _ in 0..<60 {
            let elapsed = AppModel.monotonicNowMs() - start
            let bucket = elapsed / 400
            if bucket != sampleBucket { sampleBucket = bucket; controller.advance(to: 8_000 + elapsed) }
            try await Task.sleep(for: .milliseconds(17))
            let paint = trackPaint(slider)
            precondition(abs(paint.height - hoveredPaint.height) < 0.15
                         && abs(paint.opacity - hoveredPaint.opacity) < 0.02,
                         "歌词换句和采样不能闪回或重启已完成的进度悬停外观")
            precondition(findSlider(host).map(ObjectIdentifier.init) == identity
                         && slider.trackingAreas.contains { $0 === trackingArea },
                         "悬停期间换句仍须保留原生控件及跟踪区")
            let request = model.lyricsPanel?.scrollRequest?.requestId
            if request != lastRequest { hoverRequestChanges += 1; lastRequest = request }
        }
        precondition(hoverRequestChanges >= 2, "悬停验证必须同样跨过实际歌词换句")
        precondition(controller.seekCount == 0, "自动滚动不得触发播放跳转")
        print("PASS 歌词自动滚动期间浮栏进度实例、轨道绘制/透明度、布局与悬停区稳定；\(requestChanges) 次普通/\(hoverRequestChanges) 次悬停换句、\(animatedFrames) 个滚动帧")
    }

    private static func settle(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(message)
    }

    private static func findSlider(_ view: NSView) -> NSSlider? {
        if let slider = view as? NSSlider, slider.accessibilityLabel() == "播放进度" { return slider }
        return view.subviews.lazy.compactMap(findSlider).first
    }

    private static func findLyrics(_ view: NSView) -> LyricsScrollView? {
        if let lyrics = view as? LyricsScrollView { return lyrics }
        return view.subviews.lazy.compactMap(findLyrics).first
    }

    /// 从生产 cell 的实际像素求轨道高度，确保原生状态没有在换句时闪回另一种外观。
    private static func trackPaint(_ slider: NSSlider) -> (height: CGFloat, opacity: CGFloat) {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 32,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (slider.cell as! NSSliderCell).drawBar(inside: NSRect(x: 0, y: 0, width: 160, height: 32), flipped: false)
        NSGraphicsContext.current?.flushGraphics()
        let alphas = (0..<32).map { bitmap.colorAt(x: 145, y: $0)?.alphaComponent ?? 0 }
        guard let peak = alphas.max(), peak > 0 else { return (0, 0) }
        let filledPeak = (0..<32).map { bitmap.colorAt(x: 12, y: $0)?.alphaComponent ?? 0 }.max() ?? 0
        return (alphas.reduce(0, +) / peak, filledPeak)
    }
}

private final class ProgressSubscription: PlaybackSubscriptionHandle, @unchecked Sendable {
    func cancel() {}
}

private final class ProgressController: PlaybackController, @unchecked Sendable {
    private let lock = NSLock()
    private var current: PlaybackSnapshot
    private var handler: (@Sendable (PlaybackSnapshot) -> Void)?
    private var seeks = 0
    var seekCount: Int { lock.withLock { seeks } }
    init(_ initial: PlaybackSnapshot) { current = initial }
    func snapshot() -> PlaybackSnapshot { lock.withLock { current } }
    func subscribe(_ handler: @escaping @Sendable (PlaybackSnapshot) -> Void) -> PlaybackSubscriptionHandle {
        lock.withLock { self.handler = handler }
        return ProgressSubscription()
    }
    func advance(to position: Int64) {
        let (sample, callback) = lock.withLock {
            current.seq += 1
            current.positionMs = position
            current.sampledAtMonotonicMs = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
            return (current, handler)
        }
        callback?(sample)
    }
    func setQueue(_ items: [CatalogIdentity], startAt: CatalogIdentity?) async throws {}
    func play() async throws {}
    func pause() async throws {}
    func next() async throws {}
    func previous() async throws {}
    func seek(positionMs: Int64) async throws { lock.withLock { seeks += 1 } }
    func dispose() {}
}
