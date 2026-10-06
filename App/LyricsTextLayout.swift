import AppKit
import ShinAppleKit

/// TextKit 以固定字体建立准确行坐标；只在文档、排版或宽度变化时重新排版。
/// 当前行颜色使用临时绘制属性，不改变字形、换行或文档高度。
@MainActor
final class LyricsTextLayout {
    struct Row {
        let id: UUID
        let timed: Bool
        let isBlank: Bool
        let originalRange: NSRange
        let translationRange: NSRange?
        var frame: NSRect = .zero
        var interactionFrame: NSRect = .zero
    }

    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    let container = NSTextContainer()
    let textView: LyricsInteractiveTextView
    private(set) var rows: [Row] = []
    private(set) var rowIndices: [UUID: Int] = [:]
    private var timeGroupIndices: [UUID: Int] = [:]
    private var blankTimeGroups: Set<Int> = []
    private(set) var preludeFrame: NSRect?
    private var preludeRange: NSRange?
    private var emphasizedIndices: Set<Int> = []
    private var activeIds: Set<UUID> = []
    private var hoveredId: UUID?
    /// 是否为亮度渐变（由宿主随 reduceMotion 配置；false 时直接应用终值）。
    var animatesEmphasis = true

    // 滚动宿主统一驱动每帧提亮；这里不再拥有独立的 Timer。
    var onNeedsAnimation: (() -> Void)?
    private struct EmphasisMotion {
        var original: LyricsScalarMotion
        var translation: LyricsScalarMotion?
    }
    private var emphasisMotions: [Int: EmphasisMotion] = [:]
    private(set) var hasActiveEmphasis = false

    init() {
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        textView = LyricsInteractiveTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.setAccessibilityLabel("同步歌词；单击或双击重听，拖动选择文字")
    }

    func rebuild(document: LyricDocument, typography: LyricsTypography, showTranslations: Bool) {
        let text = NSMutableAttributedString(string: "")
        resetEmphasis()
        rows = []
        rowIndices = [:]
        let times = Array(Set(document.lines.compactMap(\.startMs))).sorted()
        let groups = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($0.element, $0.offset) })
        timeGroupIndices = [:]
        blankTimeGroups = Set(groups.values)
        activeIds = []
        hoveredId = nil
        preludeRange = nil
        preludeFrame = nil
        // 在最早的可见定时行前保留固定等待槽，切入/离开前奏不改变排版或视口。
        let firstStart = document.lines.compactMap(\.startMs).min()
        let preludeLineId = firstStart.flatMap { start in
            document.lines.first {
                $0.startMs == start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?.id
        }
        for line in document.lines {
            let isBlank = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let start = line.startMs, let group = groups[start] {
                timeGroupIndices[line.id] = group
                if !isBlank { blankTimeGroups.remove(group) }
            }
            if line.id == preludeLineId {
                preludeRange = append(
                    "\u{00a0}", to: text,
                    style: (.systemFont(ofSize: typography.lineSize, weight: .bold), 0),
                    spacing: LyricsTypography.groupSpacing,
                    lineSpacing: typography.lineSize * LyricsTypography.lineSpacingFactor
                )
            }
            let translation = showTranslations ? line.translations[LyricsSyncConstants.translationLanguage] : nil
            let originalRange = append(
                isBlank ? "\u{00a0}" : line.text, to: text,
                style: (.systemFont(ofSize: typography.lineSize, weight: .bold), line.startMs == nil ? 0.3 : 0.35),
                spacing: translation == nil ? LyricsTypography.groupSpacing : LyricsTypography.translationSpacing,
                lineSpacing: typography.lineSize * LyricsTypography.lineSpacingFactor
            )
            var translationRange: NSRange?
            if let translation {
                translationRange = append(
                    translation.text + (translation.needsReview ? "  · 待复核" : ""), to: text,
                    style: (.systemFont(ofSize: typography.translationSize, weight: .medium), 0.45),
                    spacing: LyricsTypography.groupSpacing, lineSpacing: 2
                )
            }
            rowIndices[line.id] = rows.count
            rows.append(Row(
                id: line.id, timed: line.startMs != nil,
                isBlank: isBlank,
                originalRange: originalRange, translationRange: translationRange
            ))
        }
        storage.setAttributedString(text)
    }

    private func append(
        _ value: String, to text: NSMutableAttributedString, style: (font: NSFont, opacity: CGFloat),
        spacing: CGFloat, lineSpacing: CGFloat
    ) -> NSRange {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = spacing
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let range = NSRange(location: text.length, length: (value as NSString).length)
        text.append(NSAttributedString(string: value + "\n", attributes: [
            .font: style.font,
            .foregroundColor: NSColor.white.withAlphaComponent(style.opacity),
            .paragraphStyle: paragraph
        ]))
        return range
    }

    /// 一次排版生成所有行的精确坐标。万行只是文本与范围，不创建万行视图。
    func layout(width: CGFloat) -> CGFloat {
        container.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        if let preludeRange {
            let glyphs = manager.glyphRange(forCharacterRange: preludeRange, actualCharacterRange: nil)
            preludeFrame = manager.boundingRect(forGlyphRange: glyphs, in: container)
        }
        for index in rows.indices {
            let glyphs = manager.glyphRange(forCharacterRange: rows[index].originalRange, actualCharacterRange: nil)
            rows[index].frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
            var groupFrame = rows[index].frame
            if let range = rows[index].translationRange {
                let translated = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                groupFrame = groupFrame.union(manager.boundingRect(forGlyphRange: translated, in: container))
            }
            rows[index].interactionFrame = NSRect(x: 0, y: groupFrame.minY, width: width, height: groupFrame.height)
        }
        return ceil(manager.usedRect(for: container).height)
    }

    func highlight(lineIds: Set<UUID>) {
        guard lineIds != activeIds else { return }
        activeIds = lineIds
        refreshEmphasis()
    }

    /// 同时间组和相邻时间组是普通推进，长句的高度不能把换句误判成远距离 seek。
    /// 合并等待段内的连续打轴空白可跨过；含实词的时间组不能跳过。
    func areNeighboringAnchors(_ previous: UUID?, _ next: UUID) -> Bool {
        guard let previous, let from = timeGroupIndices[previous], let to = timeGroupIndices[next] else { return false }
        let lower = min(from, to)
        let upper = max(from, to)
        return upper - lower <= 1 || ((lower + 1)..<upper).allSatisfy { blankTimeGroups.contains($0) }
    }

    func hover(lineId: UUID?) {
        guard hoveredId != lineId else { return }
        hoveredId = lineId
        refreshEmphasis()
    }

    /// 计算目标亮度并启动过渡（或直接应用终值）。
    private func refreshEmphasis() {
        let currentIndices = activeIds.compactMap { rowIndices[$0] }
        var next: Set<Int> = []
        if let anchor = currentIndices.min() {
            // 超过四行的远端维持底色；只更新前后少量范围，不重建整首文本。
            next = Set(max(0, anchor - 4)...min(rows.count - 1, anchor + 4))
        }
        next.formUnion(currentIndices)
        if let hoveredId, let index = rowIndices[hoveredId] { next.insert(index) }

        // 移出邻近范围的行回到底色；保留正在呈现的亮度和速度以接续快速换句。
        for index in emphasizedIndices.union(next).union(emphasisMotions.keys) {
            let row = rows[index]
            let current = activeIds.contains(row.id)
            let hovered = row.id == hoveredId
            let distance = currentIndices.map { abs(index - $0) }.min() ?? Int.max
            let original: Double = next.contains(index)
                ? (current ? 1 : max(hovered ? 0.88 : 0, LyricsTypography.opacity(distance: distance)))
                : (row.timed ? 0.35 : 0.3)
            let translation = next.contains(index) ? (current ? 0.8 : (hovered ? 0.75 : 0.5)) : 0.45
            var motion = emphasisMotions[index] ?? EmphasisMotion(
                original: LyricsScalarMotion(position: row.timed ? 0.35 : 0.3),
                translation: row.translationRange == nil ? nil : LyricsScalarMotion(position: 0.45)
            )
            motion.original.retarget(original, omega: LyricsMotionStyle.omega)
            motion.translation?.retarget(translation, omega: LyricsMotionStyle.omega)
            emphasisMotions[index] = motion
        }
        emphasizedIndices = next
        if animatesEmphasis {
            hasActiveEmphasis = true
            onNeedsAnimation?()
        } else {
            finishEmphasis()
        }
    }

    /// 与滚动共用 displayLink 和阻尼参数；只更新临时颜色，字形和行高保持不变。
    func advanceEmphasis(by delta: TimeInterval, omega: Double) {
        guard hasActiveEmphasis else { return }
        var running = false
        for index in Array(emphasisMotions.keys) {
            guard var motion = emphasisMotions[index] else { continue }
            motion.original.advance(by: delta, omega: omega, tolerance: 0.002)
            motion.translation?.advance(by: delta, omega: omega, tolerance: 0.002)
            running = running || !motion.original.isSettled || motion.translation?.isSettled == false
            emphasisMotions[index] = motion
            paint(index: index, motion: motion)
        }
        hasActiveEmphasis = running
        if !running { emphasisMotions = emphasisMotions.filter { emphasizedIndices.contains($0.key) } }
        textView.needsDisplay = true
    }

    func finishEmphasis() {
        for index in Array(emphasisMotions.keys) {
            guard var motion = emphasisMotions[index] else { continue }
            motion.original.finish()
            motion.translation?.finish()
            emphasisMotions[index] = motion
            paint(index: index, motion: motion)
        }
        hasActiveEmphasis = false
        emphasisMotions = emphasisMotions.filter { emphasizedIndices.contains($0.key) }
        textView.needsDisplay = true
    }

    private func paint(index: Int, motion: EmphasisMotion) {
        let row = rows[index]
        manager.addTemporaryAttribute(
            .foregroundColor,
            value: NSColor.white.withAlphaComponent(motion.original.position),
            forCharacterRange: row.originalRange
        )
        if let range = row.translationRange, let translation = motion.translation {
            manager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(translation.position),
                forCharacterRange: range
            )
        }
    }

    private func resetEmphasis() {
        hasActiveEmphasis = false
        manager.removeTemporaryAttribute(
            .foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length)
        )
        emphasisMotions = [:]
        emphasizedIndices = []
    }

    func row(at point: NSPoint) -> Row? {
        visibleRows(in: NSRect(origin: point, size: .zero)).first { $0.interactionFrame.contains(point) }
    }

    /// 二分找原文/译文整体与视口相交的行；不扫描整首歌词。
    func visibleRows(in rect: NSRect) -> ArraySlice<Row> {
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].interactionFrame.maxY < rect.minY { lower = middle + 1 } else { upper = middle }
        }
        let start = lower
        while lower < rows.count, rows[lower].interactionFrame.minY <= rect.maxY { lower += 1 }
        return rows[start..<lower]
    }

}

/// 保留 NSTextView 原生选词/拖选；单击与双击均重听，完整双击只触发一次。
@MainActor
final class LyricsInteractiveTextView: NSTextView {
    var lineAtPoint: ((NSPoint) -> UUID?)?
    var onReplayLine: ((UUID) -> Void)?
    var onHoverLine: ((UUID?) -> Void)?
    var replayCursorRects: (() -> [NSRect])?
    private(set) var hoveredLineId: UUID?
    private var clickCandidate: (id: UUID, isDoubleClick: Bool)?
    private var releasePoint: NSPoint?
    private var hoverTracking: NSTrackingArea?
    private var pendingReplay: ((UUID) -> Void)?
    nonisolated(unsafe) private var clickTimer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        hoverTracking = tracking
        addTrackingArea(tracking)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { window.acceptsMouseMovedEvents = true } else { clearInteraction() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in replayCursorRects?() ?? [] {
            let visible = rect.intersection(visibleRect)
            if !visible.isEmpty { addCursorRect(visible, cursor: .pointingHand) }
        }
    }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setHoveredLine(nil) }

    func updateHover(at point: NSPoint) { setHoveredLine(lineAtPoint?(point)) }

    private func setHoveredLine(_ id: UUID?) {
        guard hoveredLineId != id else { return }
        hoveredLineId = id
        onHoverLine?(id)
    }

    override func mouseDown(with event: NSEvent) {
        beginPointerInteraction(at: convert(event.locationInWindow, from: nil),
                                clickCount: event.clickCount, modifiers: event.modifierFlags)
        // NSTextView 的 mouseDown 内部消费整个拖选事件循环；局部观察其拖动/松手，不截断原生选择。
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] next in
            guard let self, next.window === self.window else { return next }
            self.releasePoint = self.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged { self.pointerDragged() }
            return next
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        super.mouseDown(with: event)
        let endpoint = releasePoint ?? convert(event.locationInWindow, from: nil)
        endPointerInteraction(at: endpoint, hasSelection: selectedRanges.contains { $0.rangeValue.length > 0 })
    }

    func beginPointerInteraction(at point: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) {
        cancelPendingClick()
        releasePoint = nil
        clickCandidate = nil
        let selectionModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        guard clickCount == 1 || clickCount == 2, modifiers.isDisjoint(with: selectionModifiers),
              let id = lineAtPoint?(point) else { return }
        clickCandidate = (id, clickCount == 2)
    }

    func pointerDragged() { clickCandidate = nil }

    override func selectionRange(forProposedRange range: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        // NSTextView 内部的拖选不一定经过局部事件监视器；保留原生选区，只取消重听候选。
        if NSApplication.shared.currentEvent?.type == .leftMouseDragged { pointerDragged() }
        return super.selectionRange(forProposedRange: range, granularity: granularity)
    }

    func endPointerInteraction(at point: NSPoint, hasSelection: Bool) {
        defer { clickCandidate = nil }
        guard let candidate = clickCandidate, candidate.isDoubleClick || !hasSelection,
              lineAtPoint?(point) == candidate.id else { return }
        if candidate.isDoubleClick {
            onReplayLine?(candidate.id)
            return
        }
        pendingReplay = onReplayLine
        // 等待系统双击窗口；第二次按下会取消此任务，并在双击松手时只重听一次。
        let timer = Timer(timeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clickTimer = nil
                let replay = self.pendingReplay
                self.pendingReplay = nil
                replay?(candidate.id)
            }
        }
        clickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func clearInteraction() {
        cancelPendingClick()
        clickCandidate = nil
        setHoveredLine(nil)
    }

    private func cancelPendingClick() {
        clickTimer?.invalidate()
        clickTimer = nil
        pendingReplay = nil
    }

    deinit { clickTimer?.invalidate() }
}
