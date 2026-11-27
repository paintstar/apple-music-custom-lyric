import AppKit
import SwiftUI
import ShinAppleKit
import ShinLyricsEngine
import QuartzCore

/// 精确文本坐标 + 原生裁剪区滚动，避免 LazyVStack 远距离 seek 的行高估算误差。
struct NativeLyricsScrollView: NSViewRepresentable {
    let document: LyricDocument
    let typography: LyricsTypography
    let showTranslations: Bool
    var showPronunciations = true
    let currentLineIds: Set<UUID>
    let request: LyricsPanelModel.ScrollAnchorRequest?
    let followsPlayback: Bool
    let reduceMotion: Bool
    let onInteraction: () -> Void
    let onDragStateChange: (Bool) -> Void
    let onTapLine: (UUID) -> Void
    var canSeek = false
    var interactionIdentity = ""
    var viewportAnchorFraction = LyricsViewportAnchorKey.defaultValue
    var waitingInterval: LyricsWaitingInterval?
    /// 只读既有受限播放时钟；nil 表示未知、过期或 seek 中，保持静态。
    var waitingPosition: (() -> Int64?)?
    var waitingIsPlaying = false
    var focusesPlayback = false
    var userDelayMs: Int64 = 0
    var vocabularyOccurrences: [VocabularyOccurrence] = []
    var isClozeMode = false
    var onWordSelection: ((LyricsWordSelection?) -> Void)?
    var onRequestWordStudy: ((LyricsWordSelection) -> Void)?
    var onRequestLineStudy: ((UUID, CGRect) -> Void)?
    var onRequestLineEdit: ((UUID, CGRect) -> Void)?
    var resolveLineLoopMenuState: ((UUID) -> LyricsLineLoopMenuState?)?
    var onToggleSingleLineLoop: ((UUID) -> Void)?
    var onSetABLoopAnchor: ((UUID) -> Void)?
    var onCompleteABLoop: ((UUID) -> Void)?
    var clearSelectionToken = 0

    var resolvedViewportAnchorFraction: CGFloat { LyricsViewportAnchorKey.clamped(viewportAnchorFraction) }

    func makeNSView(context: Context) -> LyricsScrollView {
        LyricsScrollView()
    }

    func updateNSView(_ view: LyricsScrollView, context: Context) {
        view.onTapLine = onTapLine
        view.catcher.onInteraction = { [weak view] in
            view?.beginUserInteraction()
            onInteraction()
        }
        view.catcher.onDragStateChange = { [weak view] active in
            view?.cancelAnimation()
            if active { view?.beginUserInteraction() }
            onDragStateChange(active)
        }
        view.configure(self)
    }

    static func dismantleNSView(_ view: LyricsScrollView, coordinator: ()) {
        view.prepareForRemoval()
    }
}

@MainActor
final class LyricsScrollView: NSScrollView {
    let textLayout = LyricsTextLayout()
    let catcher = ScrollWheelCatcher()
    let lyricsScroller = LyricsOverlayScroller()
    var onTapLine: ((UUID) -> Void)?
    let canvas: NSView = LyricsDocumentCanvas()
    let waitingIndicator = InterludeDotsView()
    let displayLinkTarget = LyricsDisplayLinkTarget()
    nonisolated(unsafe) var frameLink: CADisplayLink?
    var lastFrameTime: TimeInterval?
    var scrollMotion: LyricsScrollMotion?
    var jump: LyricsJumpTransition?
    var waitingNeedsFrames = false
    var hasActiveDisplayLink: Bool { frameLink != nil }
    var isScrollAnimating: Bool { scrollMotion != nil || jump != nil }
    private var contentKey: String?
    private var measuredSize: NSSize = .zero
    private var measuredDocumentSize: NSSize = .zero
    var needsTextLayout = true
    private var isLayingOutText = false
    var appliedStudyMarksKey: StudyMarksKey?
    var hasActiveWordSelection = false
    private var lastClearSelectionToken = 0
    /// 嵌套配置、重排和动画定位都不能被误认为用户浏览。
    private var programmaticScrollDepth = 0
    private var accessibilityRows: [UUID: LyricRowAccessibilityElement] = [:]
    private var lastRequestId: UUID?
    var configuration: NativeLyricsScrollView?
    private var targetLineId: UUID?
    var textTopInset: CGFloat = 0
    private var viewportAnchorOffset: CGFloat {
        contentSize.height * (configuration?.resolvedViewportAnchorFraction ?? LyricsViewportAnchorKey.defaultValue)
    }
    nonisolated(unsafe) private var geometryTimer: Timer?
    private var isGeometrySettled = false
    /// AppKit 的窗口动画会在 SwiftUI 布局返回后继续校正 bounds；仅延后无事件滚动兜底。
    private let geometrySettleInterval: TimeInterval = 0.2
    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScroller = lyricsScroller
        lyricsScroller.onPointerEnter = { [weak self] in self?.flashScrollers() }
        borderType = .noBorder
        let clip = LyricsClipView()
        clip.drawsBackground = false
        clip.onBoundsChange = { [weak self] in self?.clipBoundsDidChange() }
        contentView = clip
        documentView = canvas
        canvas.addSubview(textLayout.textView)
        canvas.addSubview(waitingIndicator)
        displayLinkTarget.owner = self
        textLayout.onNeedsAnimation = { [weak self] in self?.ensureDisplayLink() }
        textLayout.textView.lineAtPoint = { [weak self] point in self?.replayableRow(at: point)?.id }
        textLayout.textView.hoverLineAtPoint = { [weak self] point in self?.hoverableRow(at: point)?.id }
        textLayout.textView.onHoverLine = { [weak self] id in self?.textLayout.hover(lineId: id) }
        textLayout.textView.replayCursorRects = { [weak self] in
            self?.visibleReplayRows().map(\.interactionFrame) ?? []
        }
        installStudyCallbacks()
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        catcher.install(in: self)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if window == nil {
            textLayout.textView.clearInteraction()
            lyricsScroller.endPointerHover()
            stopAllFrames()
            geometryTimer?.invalidate()
            geometryTimer = nil
            isGeometrySettled = false
        } else {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window
            )
            waitForStableGeometry()
            ensureDisplayLink()
        }
    }

    @objc private func windowResignedKey() {
        textLayout.textView.clearInteraction()
        lyricsScroller.endPointerHover()
    }

    @objc private func windowVisibilityChanged() {
        guard window?.occlusionState.contains(.visible) == true else {
            stopAllFrames()
            return
        }
        updateWaitingIndicator()
        if configuration?.followsPlayback == true, let targetLineId, let target = offset(for: targetLineId) {
            cancelAnimation()
            setScrollOffset(target)
        }
        ensureDisplayLink()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { waitForStableGeometry() }
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        super.setFrameSize(newSize)
    }

    override func tile() {
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        super.tile()
    }

    override func layout() {
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        super.layout()
        layoutTextIfNeeded()
    }

    func configure(_ value: NativeLyricsScrollView) {
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        textLayout.animatesEmphasis = !value.reduceMotion
        if value.reduceMotion {
            textLayout.finishEmphasis()
            cancelAnimation()
        }
        let interactionChanged = configuration?.interactionIdentity != value.interactionIdentity
            || configuration?.canSeek != value.canSeek
        configuration = value
        lyricsScroller.followsPlayback = value.followsPlayback
        onTapLine = value.onTapLine
        textLayout.textView.onReplayLine = value.onTapLine
        if interactionChanged {
            textLayout.textView.clearInteraction()
            accessibilityRows.removeAll()
        }
        let key = "\(value.document.id):\(value.document.revision):\(value.showTranslations):\(value.showPronunciations)"
            + ":\(value.typography.lineSize):\(value.typography.pronunciationSize)"
            + ":\(value.typography.translationSize):\(value.userDelayMs)"
        let didRebuild = key != contentKey
        if didRebuild {
            cancelAnimation()
            contentKey = key
            textLayout.textView.clearInteraction()
            clearActiveSelectionOnRebuild()
            accessibilityRows.removeAll()
            textLayout.rebuild(
                document: value.document,
                typography: value.typography,
                showTranslations: value.showTranslations,
                showPronunciations: value.showPronunciations,
                userDelayMs: value.userDelayMs
            )
            needsTextLayout = true
            targetLineId = nil
            lastRequestId = nil
        }
        if value.clearSelectionToken != lastClearSelectionToken {
            lastClearSelectionToken = value.clearSelectionToken
            textLayout.textView.setSelectedRange(NSRange(location: 0, length: 0))
            hasActiveWordSelection = false
        }
        syncStudyMarksIfNeeded(
            document: value.document,
            occurrences: value.vocabularyOccurrences,
            isClozeMode: value.isClozeMode,
            didRebuild: didRebuild
        )
        let focusesPlayback = value.focusesPlayback && value.followsPlayback && value.waitingInterval == nil
        let animatesFocus = textLayout.focusesPlayback && focusesPlayback && !value.reduceMotion
            && !didRebuild && !interactionChanged && jump?.positioned != false
            && window?.occlusionState.contains(.visible) == true && !textLayout.textView.hasTextSelection
        textLayout.focusesPlayback = focusesPlayback
        let focusDistance = animatesFocus ? contentSize.height * LyricsMotionStyle.jumpViewportFraction : nil
        let transfersFocus = textLayout.highlight(lineIds: value.currentLineIds, focusDistance: focusDistance)
        layoutTextIfNeeded()
        updateWaitingIndicator()
        updateAccessibilityRows()
        ensureDisplayLink()
        if !value.followsPlayback { cancelAnimation() }
        if value.reduceMotion, value.followsPlayback, let targetLineId, let target = offset(for: targetLineId) {
            // 开关减少动态效果时请求 ID 可能不变，仍须完成被中断的当前定位。
            setScrollOffset(target)
        }
        guard value.followsPlayback, let request = value.request,
              request.requestId != lastRequestId, textLayout.rowIndices[request.lineId] != nil else { return }
        let animate = lastRequestId != nil && !value.reduceMotion
        lastRequestId = request.requestId
        let previousLineId = targetLineId
        targetLineId = request.lineId
        scroll(to: request.lineId, animated: animate, previousLineId: previousLineId, transfersFocus: transfersFocus)
    }

    private func layoutTextIfNeeded() {
        guard !isLayingOutText, contentSize.width > 0, contentSize.height > 0 else { return }
        let viewport = contentSize
        let anchorOffset = viewportAnchorOffset
        guard needsTextLayout || measuredSize != viewport || textTopInset != anchorOffset else { return }
        isLayingOutText = true
        defer { isLayingOutText = false }
        cancelAnimation()
        textLayout.textView.clearInteraction()
        let oldInset = textTopInset
        let oldOffset = contentView.bounds.minY
        // 留白与滚动目标共用宿主锚点，首句和末句也能停在同一视口位置。
        textTopInset = anchorOffset
        let widthChanged = measuredSize.width != viewport.width
        let textHeight: CGFloat
        if needsTextLayout || widthChanged {
            textHeight = textLayout.layout(width: viewport.width)
        } else {
            textHeight = textLayout.textView.frame.height
        }
        textLayout.textView.frame = NSRect(
            x: 0, y: textTopInset, width: viewport.width, height: max(1, textHeight)
        )
        canvas.frame = NSRect(x: 0, y: 0, width: viewport.width, height: max(viewport.height, textHeight + viewport.height))
        measuredSize = viewport
        measuredDocumentSize = canvas.frame.size
        needsTextLayout = false
        if configuration?.followsPlayback == true,
           let targetLineId, let target = offset(for: targetLineId) {
            setScrollOffset(target)
        } else {
            setScrollOffset(oldOffset + textTopInset - oldInset, alignsToBacking: false)
        }
        updateWaitingIndicator()
        updateAccessibilityRows()
        waitForStableGeometry()
    }

    func offset(for lineId: UUID) -> CGFloat? {
        guard let index = textLayout.rowIndices[lineId] else { return nil }
        let rowY: CGFloat
        if let interval = configuration?.waitingInterval, interval.shouldShowIndicator, interval.anchorLineId == nil,
           interval.nextLineId == lineId, let prelude = textLayout.preludeFrame {
            rowY = prelude.minY
        } else {
            rowY = textLayout.rows[index].frame.minY
        }
        return clampedOffset(rowY + textTopInset - viewportAnchorOffset, alignsToBacking: true)
    }

    private func clampedOffset(_ proposed: CGFloat, alignsToBacking: Bool) -> CGFloat {
        let limit = max(0, canvas.frame.height - contentSize.height)
        let offset = min(max(0, proposed), limit)
        guard alignsToBacking, let window else { return offset }
        // 一次移动整设备像素，原文、注音和译文保持同一栅格位移。
        let scale = window.backingScaleFactor
        return min((offset * scale).rounded(), (limit * scale).rounded(.down)) / scale
    }

    func setScrollOffset(_ value: CGFloat, alignsToBacking: Bool = true) {
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        let destination = NSPoint(x: 0, y: clampedOffset(value, alignsToBacking: alignsToBacking))
        guard contentView.bounds.origin != destination else { return }
        contentView.scroll(to: destination)
        reflectScrolledClipView(contentView)
    }

    func beginUserInteraction() {
        cancelAnimation()
        lyricsScroller.followsPlayback = false
        textLayout.focusesPlayback = false
    }

    private func waitForStableGeometry() {
        isGeometrySettled = false
        geometryTimer?.invalidate()
        let timer = Timer(timeInterval: geometrySettleInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isGeometrySettled = true
                self?.geometryTimer = nil
            }
        }
        geometryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func prepareForRemoval() {
        stopAllFrames()
        textLayout.focusesPlayback = false
        geometryTimer?.invalidate()
        geometryTimer = nil
        isGeometrySettled = false
        configuration = nil
        waitingNeedsFrames = false
        waitingIndicator.configure(interval: nil, positionMs: nil, reduceMotion: true)
        textLayout.onNeedsAnimation = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        textLayout.textView.clearInteraction()
        textLayout.textView.onReplayLine = nil
        clearStudyCallbacks()
        lyricsScroller.endPointerHover()
        lyricsScroller.onPointerEnter = nil
        accessibilityRows.removeAll()
        canvas.setAccessibilityChildren([textLayout.textView])
        catcher.onInteraction = nil
        catcher.onDragStateChange = nil
        catcher.remove()
    }

    private func clipBoundsDidChange() {
        textLayout.textView.clearInteraction()
        updateAccessibilityRows()
        refreshSelectionBarIfActive()
        guard isGeometrySettled, programmaticScrollDepth == 0, !isLayingOutText,
              !needsTextLayout, contentSize == measuredSize,
              canvas.frame.size == measuredDocumentSize else { return }
        // 缩小窗口时 AppKit 可能先约束旧 bounds、稍后才重排；视口与文档尺寸都要稳定。
        // 辅助功能、键盘与选中文字后的滚动可能没有 NSEvent，仍采用同一浏览语义。
        beginUserInteraction()
        configuration?.onInteraction()
    }

    private func replayableRow(at point: NSPoint) -> LyricsTextLayout.Row? {
        guard configuration?.canSeek == true, let row = textLayout.row(at: point), row.timed, !row.isBlank else { return nil }
        return row
    }

    private func hoverableRow(at point: NSPoint) -> LyricsTextLayout.Row? {
        if let replayable = replayableRow(at: point) { return replayable }
        guard textLayout.clozeEnabled || textLayout.focusesPlayback else { return nil }
        return textLayout.nonBlankRow(at: point)
    }

    private func visibleReplayRows() -> ArraySlice<LyricsTextLayout.Row> {
        guard !needsTextLayout, configuration?.canSeek == true else { return [] }
        let visible = contentView.bounds.offsetBy(dx: 0, dy: -textTopInset).insetBy(dx: 0, dy: -40)
        return ArraySlice(textLayout.visibleRows(in: visible).filter { $0.timed && !$0.isBlank })
    }

    private func updateAccessibilityRows() {
        let rows = visibleReplayRows()
        let visibleIds = Set(rows.map(\.id))
        for id in Set(accessibilityRows.keys).subtracting(visibleIds) { accessibilityRows.removeValue(forKey: id) }
        for row in rows {
            let element: LyricRowAccessibilityElement
            if let existing = accessibilityRows[row.id] { element = existing } else {
                let expectedContent = contentKey
                let expectedIdentity = configuration?.interactionIdentity
                element = LyricRowAccessibilityElement(lineId: row.id) { [weak self] id in
                    guard let self, self.configuration?.canSeek == true,
                          self.contentKey == expectedContent,
                          self.configuration?.interactionIdentity == expectedIdentity else { return false }
                    self.onTapLine?(id)
                    return true
                }
                let originalText = textLayout.storage.attributedSubstring(from: row.originalRange).string
                element.setAccessibilityLabel("重听这句：" + originalText)
                element.setAccessibilityParent(canvas)
                accessibilityRows[row.id] = element
            }
            element.setAccessibilityValue(configuration?.currentLineIds.contains(row.id) == true ? "当前歌词" : "")
            element.setAccessibilityFrameInParentSpace(row.interactionFrame.offsetBy(dx: 0, dy: textTopInset))
        }
        let waitingChildren: [NSView] = waitingIndicator.isHidden ? [] : [waitingIndicator]
        canvas.setAccessibilityChildren([textLayout.textView] + waitingChildren + rows.compactMap { accessibilityRows[$0.id] })
        window?.invalidateCursorRects(for: textLayout.textView)
    }

    deinit {
        frameLink?.invalidate()
        geometryTimer?.invalidate()
    }
}
