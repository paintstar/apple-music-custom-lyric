import AppKit
import ShinAppleKit
import ShinLyricsEngine

/// TextKit 以固定字体建立准确行坐标；只在文档、排版或宽度变化时重新排版。
/// 歌词焦点只改变绘制，不改变字形、换行或文档高度。
@MainActor
final class LyricsTextLayout {
    struct Row {
        let id: UUID
        let timed: Bool
        let isBlank: Bool
        let hasStudyNote: Bool
        let originalRange: NSRange
        let pronunciationRange: NSRange?
        let translationRange: NSRange?
        var frame: NSRect = .zero
        var interactionFrame: NSRect = .zero
    }

    let storage = NSTextStorage()
    let manager = LyricsFocusLayoutManager()
    let container = NSTextContainer()
    let textView: LyricsInteractiveTextView
    private(set) var rows: [Row] = []
    private(set) var rowIndices: [UUID: Int] = [:]
    private var timeGroupIndices: [UUID: Int] = [:]
    private var blankTimeGroups: Set<Int> = []
    private(set) var preludeFrame: NSRect?
    private var preludeRange: NSRange?
    private var waitingSlotLineIds: Set<UUID> = []
    var emphasizedIndices: Set<Int> = []
    var activeIds: Set<UUID> = []
    var hoveredId: UUID?
    var clozeEnabled = false
    var clozeRangesByLine: [UUID: [NSRange]] = [:]
    /// 是否为亮度渐变（由宿主随 reduceMotion 配置；false 时直接应用终值）。
    var animatesEmphasis = true
    var focusesPlayback = false {
        didSet { if oldValue != focusesPlayback { finishFocus() } }
    }

    // 滚动宿主统一驱动每帧提亮；这里不再拥有独立的 Timer。
    var onNeedsAnimation: (() -> Void)?
    struct EmphasisMotion {
        var original: LyricsScalarMotion
        var pronunciation: LyricsScalarMotion?
        var translation: LyricsScalarMotion?
        var sharpness = LyricsScalarMotion(position: 0)
    }
    var emphasisMotions: [Int: EmphasisMotion] = [:]
    var hasActiveEmphasis = false

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
        textView.setAccessibilityLabel("同步歌词；双击重听，拖动选择文字")
    }

    func rebuild(
        document: LyricDocument,
        typography: LyricsTypography,
        showTranslations: Bool,
        showPronunciations: Bool = true,
        userDelayMs: Int64 = 0
    ) {
        let text = NSMutableAttributedString(string: "")
        resetEmphasis()
        clearStudyMarks()
        rows = []
        rowIndices = [:]
        let times = Array(Set(document.lines.compactMap(\.startMs))).sorted()
        let groups = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($0.element, $0.offset) })
        timeGroupIndices = [:]
        blankTimeGroups = Set(groups.values)
        activeIds = []
        hoveredId = nil
        manager.focusedRanges = nil
        preludeRange = nil
        preludeFrame = nil
        // 整文档一次预计算紧凑槽；资格采用有效时间，进入/退出等待不重新排版。
        let intervals = LyricsTimelineIndex(document: document, userDelayMs: userDelayMs).indicatorIntervals
        waitingSlotLineIds = Set(intervals.compactMap(\.anchorLineId))
        let preludeLineId = intervals.first { $0.anchorLineId == nil }?.nextLineId
        for line in document.lines {
            let isBlank = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let start = line.startMs, let group = groups[start] {
                timeGroupIndices[line.id] = group
                if !isBlank { blankTimeGroups.remove(group) }
            }
            if line.id == preludeLineId {
                preludeRange = appendWaitingSlot(to: text)
            }
            let pronunciation: LinePronunciation? = (!isBlank && showPronunciations)
                ? line.pronunciation.flatMap {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                }
                : nil
            let translation = showTranslations ? line.translations[LyricsSyncConstants.translationLanguage] : nil
            let originalRange: NSRange
            if isBlank, waitingSlotLineIds.contains(line.id) {
                originalRange = appendWaitingSlot(to: text)
            } else if isBlank, line.startMs != nil, translation == nil {
                // 只压缩展示；文档中空行的文本、稳定身份、时间及人工翻译均不改。
                originalRange = NSRange(location: text.length, length: 0)
            } else {
                let compactBlank = isBlank && line.startMs != nil
                let afterOriginalSpacing = pronunciation != nil
                    ? LyricsTypography.pronunciationSpacing
                    : (translation != nil ? LyricsTypography.translationSpacing : LyricsTypography.groupSpacing)
                originalRange = append(
                    isBlank ? "\u{00a0}" : line.text, to: text,
                    style: (.systemFont(ofSize: compactBlank ? 1 : typography.lineSize, weight: .bold),
                            line.startMs == nil ? 0.3 : 0.35),
                    spacing: afterOriginalSpacing,
                    lineSpacing: compactBlank ? 0 : typography.lineSize * LyricsTypography.lineSpacingFactor
                )
            }
            var pronunciationRange: NSRange?
            if let pronunciation {
                pronunciationRange = append(
                    pronunciation.text + (pronunciation.needsReview ? "  · 待复核" : ""), to: text,
                    style: (.systemFont(ofSize: typography.pronunciationSize, weight: .medium), 0.60),
                    spacing: translation == nil ? LyricsTypography.groupSpacing : LyricsTypography.translationSpacing,
                    lineSpacing: 2
                )
            }
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
                hasStudyNote: !isBlank && line.studyNote != nil,
                originalRange: originalRange,
                pronunciationRange: pronunciationRange,
                translationRange: translationRange
            ))
        }
        storage.setAttributedString(text)
    }

    private func appendWaitingSlot(to text: NSMutableAttributedString) -> NSRange {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = LyricsSyncConstants.waitingSlotHeight
        paragraph.maximumLineHeight = LyricsSyncConstants.waitingSlotHeight
        let range = NSRange(location: text.length, length: 1)
        text.append(NSAttributedString(string: "\u{00a0}\n", attributes: [
            .font: NSFont.systemFont(ofSize: 1), .foregroundColor: NSColor.clear, .paragraphStyle: paragraph
        ]))
        return range
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
            preludeFrame = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        }
        for index in rows.indices {
            guard rows[index].originalRange.length > 0 else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: rows[index].originalRange, actualCharacterRange: nil)
            rows[index].frame = waitingSlotLineIds.contains(rows[index].id)
                ? manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                : manager.boundingRect(forGlyphRange: glyphs, in: container)
            var groupFrame = rows[index].frame
            if let range = rows[index].pronunciationRange {
                let pronounced = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                groupFrame = groupFrame.union(manager.boundingRect(forGlyphRange: pronounced, in: container))
            }
            if let range = rows[index].translationRange {
                let translated = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                groupFrame = groupFrame.union(manager.boundingRect(forGlyphRange: translated, in: container))
            }
            rows[index].interactionFrame = NSRect(x: 0, y: groupFrame.minY, width: width, height: groupFrame.height)
        }
        let height = ceil(manager.usedRect(for: container).height)
        var nextY = height
        for index in rows.indices.reversed() {
            if rows[index].originalRange.length == 0 {
                rows[index].frame = NSRect(x: 0, y: nextY, width: 0, height: 0)
                rows[index].interactionFrame = rows[index].frame
            } else { nextY = rows[index].frame.minY }
        }
        return height
    }

    /// 同时间组和相邻时间组是普通推进，长句的高度不能把换句误判成远距离 seek。
    /// 合并等待段内的连续打轴空白可跨过；含实词的时间组不能跳过。
    func areNeighboringAnchors(_ previous: UUID?, _ next: UUID) -> Bool {
        guard let previous, let from = timeGroupIndices[previous], let to = timeGroupIndices[next] else { return false }
        return areNeighboringGroups(min(from, to), max(from, to))
    }

    func advancesToNearbyGroup(from previous: Set<UUID>, to next: Set<UUID>, within distance: CGFloat) -> Bool {
        guard let first = previous.compactMap({ rowIndices[$0] }).min(),
              let last = next.compactMap({ rowIndices[$0] }).min(),
              let from = timeGroupIndices[rows[first].id], let to = timeGroupIndices[rows[last].id], from < to else { return false }
        if areNeighboringGroups(from, to) { return true }
        // 一个采样间隔可能跨过很短的句子。近距连续移动时直接交接给实际的新句。
        let advance = rows[last].frame.minY - rows[first].frame.minY
        return advance > 0 && advance <= distance
    }

    private func areNeighboringGroups(_ lower: Int, _ upper: Int) -> Bool {
        return upper - lower <= 1 || ((lower + 1)..<upper).allSatisfy { blankTimeGroups.contains($0) }
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

/// 保留 NSTextView 原生拖选划词；无修饰键双击歌词行只触发重听跳转且不选中文字，单击用于拖选或取消选区。
@MainActor
final class LyricsInteractiveTextView: NSTextView {
    var lineAtPoint: ((NSPoint) -> UUID?)?
    var hoverLineAtPoint: ((NSPoint) -> UUID?)?
    var onReplayLine: ((UUID) -> Void)?
    var onHoverLine: ((UUID?) -> Void)?
    var replayCursorRects: (() -> [NSRect])?
    var onSelectionChanged: ((NSRange) -> Void)?
    var resolveContextMenuWord: (() -> LyricsWordSelection?)?
    var resolveContextMenuLine: ((NSPoint) -> (lineId: UUID, anchorRect: CGRect)?)?
    var resolveLineLoopMenuState: ((UUID) -> LyricsLineLoopMenuState?)?
    var onRequestWordStudy: ((LyricsWordSelection) -> Void)?
    var onRequestLineStudy: ((UUID, CGRect) -> Void)?
    var onRequestLineEdit: ((UUID, CGRect) -> Void)?
    var onToggleSingleLineLoop: ((UUID) -> Void)?
    var onSetABLoopAnchor: ((UUID) -> Void)?
    var onCompleteABLoop: ((UUID) -> Void)?
    var drawStudyIndicators: ((NSRect) -> Void)?
    var pendingMenuWordSelection: LyricsWordSelection?
    var pendingMenuLineTarget: (lineId: UUID, anchorRect: CGRect)?
    private(set) var hoveredLineId: UUID?
    private var clickCandidate: UUID?
    private var didDragDuringMouseDown = false
    private var releasePoint: NSPoint?
    private var hoverTracking: NSTrackingArea?

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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawStudyIndicators?(dirtyRect)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let hadSelection = hasTextSelection
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if hadSelection != hasTextSelection { needsDisplay = true }
    }

    var hasTextSelection: Bool { selectedRanges.contains { $0.rangeValue.length > 0 } }

    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setHoveredLine(nil) }

    func updateHover(at point: NSPoint) {
        setHoveredLine((hoverLineAtPoint ?? lineAtPoint)?(point))
    }

    private func setHoveredLine(_ id: UUID?) {
        guard hoveredLineId != id else { return }
        hoveredLineId = id
        onHoverLine?(id)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        didDragDuringMouseDown = false
        beginPointerInteraction(at: point, clickCount: event.clickCount, modifiers: event.modifierFlags)
        let selectionModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        if event.clickCount >= 2, event.modifierFlags.isDisjoint(with: selectionModifiers) {
            if selectedRange().length > 0 {
                setSelectedRange(NSRange(location: 0, length: 0))
            }
            if event.clickCount == 2 {
                endPointerInteraction(at: point, hasSelection: false)
            } else {
                clickCandidate = nil
            }
            onSelectionChanged?(NSRange(location: 0, length: 0))
            return
        }
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
        let selectionRange = selectedRange()
        endPointerInteraction(at: endpoint, hasSelection: selectedRanges.contains { $0.rangeValue.length > 0 })
        let publishesStudySelection = event.clickCount == 1 || didDragDuringMouseDown
        onSelectionChanged?(publishesStudySelection ? selectionRange : NSRange(location: 0, length: 0))
    }

    func beginPointerInteraction(at point: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) {
        releasePoint = nil
        clickCandidate = nil
        let selectionModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        guard clickCount == 2, modifiers.isDisjoint(with: selectionModifiers),
              let id = lineAtPoint?(point) else { return }
        clickCandidate = id
    }

    func pointerDragged() {
        clickCandidate = nil
        didDragDuringMouseDown = true
    }

    override func selectionRange(forProposedRange range: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        // NSTextView 内部的拖选不一定经过局部事件监视器；保留原生选区，只取消重听候选。
        if NSApplication.shared.currentEvent?.type == .leftMouseDragged { pointerDragged() }
        return super.selectionRange(forProposedRange: range, granularity: granularity)
    }

    func endPointerInteraction(at point: NSPoint, hasSelection: Bool) {
        _ = hasSelection
        defer { clickCandidate = nil }
        guard let candidateId = clickCandidate, lineAtPoint?(point) == candidateId else { return }
        onReplayLine?(candidateId)
    }

    func clearInteraction() {
        clickCandidate = nil
        didDragDuringMouseDown = false
        setHoveredLine(nil)
    }
}
