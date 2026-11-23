import AppKit

/// 歌词行高亮与悬停亮度过渡（与滚动共用 displayLink，不改动字形与行高）。
@MainActor
extension LyricsTextLayout {
    func highlight(lineIds: Set<UUID>) {
        guard lineIds != activeIds else { return }
        activeIds = lineIds
        refreshEmphasis()
    }

    func hover(lineId: UUID?) {
        guard hoveredId != lineId else { return }
        let previousHoveredId = hoveredId
        hoveredId = lineId
        refreshEmphasis()
        if clozeEnabled {
            refreshClozeVisibility(forLineIds: [previousHoveredId, lineId].compactMap { $0 })
        }
    }

    /// 计算目标亮度并启动过渡（或直接应用终值）。
    func refreshEmphasis() {
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
            let pronunciation = next.contains(index) ? (current ? 0.85 : (hovered ? 0.78 : 0.60)) : 0.60
            let translation = next.contains(index) ? (current ? 0.8 : (hovered ? 0.75 : 0.5)) : 0.45
            var motion = emphasisMotions[index] ?? EmphasisMotion(
                original: LyricsScalarMotion(position: row.timed ? 0.35 : 0.3),
                pronunciation: row.pronunciationRange == nil ? nil : LyricsScalarMotion(position: 0.60),
                translation: row.translationRange == nil ? nil : LyricsScalarMotion(position: 0.45)
            )
            motion.original.retarget(original, omega: LyricsMotionStyle.omega)
            motion.pronunciation?.retarget(pronunciation, omega: LyricsMotionStyle.omega)
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
            motion.pronunciation?.advance(by: delta, omega: omega, tolerance: 0.002)
            motion.translation?.advance(by: delta, omega: omega, tolerance: 0.002)
            running = running
                || !motion.original.isSettled
                || motion.pronunciation?.isSettled == false
                || motion.translation?.isSettled == false
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
            motion.pronunciation?.finish()
            motion.translation?.finish()
            emphasisMotions[index] = motion
            paint(index: index, motion: motion)
        }
        hasActiveEmphasis = false
        emphasisMotions = emphasisMotions.filter { emphasizedIndices.contains($0.key) }
        textView.needsDisplay = true
    }

    func paint(index: Int, motion: EmphasisMotion) {
        let row = rows[index]
        manager.addTemporaryAttribute(
            .foregroundColor,
            value: NSColor.white.withAlphaComponent(motion.original.position),
            forCharacterRange: row.originalRange
        )
        if clozeEnabled, row.id != hoveredId, let clozeRanges = clozeRangesByLine[row.id] {
            for range in clozeRanges where NSMaxRange(range) <= storage.length {
                manager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
            }
        }
        if let range = row.pronunciationRange, let pronunciation = motion.pronunciation {
            manager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(pronunciation.position),
                forCharacterRange: range
            )
        }
        if let range = row.translationRange, let translation = motion.translation {
            manager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(translation.position),
                forCharacterRange: range
            )
        }
    }

    func reapplyEmphasisColors() {
        for (index, motion) in emphasisMotions where index < rows.count {
            paint(index: index, motion: motion)
        }
        textView.needsDisplay = true
    }

    func resetEmphasis() {
        hasActiveEmphasis = false
        manager.removeTemporaryAttribute(
            .foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length)
        )
        emphasisMotions = [:]
        emphasizedIndices = []
    }
}
