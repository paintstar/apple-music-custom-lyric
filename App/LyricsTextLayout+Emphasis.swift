import AppKit

/// 歌词行的亮度和焦点过渡与滚动共用 displayLink，保留原有排版。
@MainActor
extension LyricsTextLayout {
    func highlight(lineIds: Set<UUID>, focusDistance: CGFloat?) -> Bool {
        guard lineIds != activeIds else { return false }
        let advances = focusDistance.map { advancesToNearbyGroup(from: activeIds, to: lineIds, within: $0) } ?? false
        activeIds = lineIds
        refreshEmphasis(animatingFocus: advances)
        return advances
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

    private func paintFocus() {
        guard focusesPlayback, activeIds.contains(where: { id in rowIndices[id].map { !rows[$0].isBlank } == true }) else {
            manager.focusedRanges = nil
            return
        }
        manager.focusedRanges = emphasisMotions.keys.sorted().compactMap { index in
            let row = rows[index]
            let sharpness = row.id == hoveredId ? 1 : (emphasisMotions[index]?.sharpness.position ?? 0)
            guard sharpness > 0 else { return nil }
            let range = NSUnionRange(row.originalRange, row.translationRange ?? row.pronunciationRange ?? row.originalRange)
            return LyricsFocusLayoutManager.FocusedRange(characters: range, sharpness: sharpness)
        }
    }

    func finishFocus() {
        for index in Array(emphasisMotions.keys) { emphasisMotions[index]?.sharpness.finish() }
        paintFocus()
    }

    /// 计算目标亮度并启动过渡（或直接应用终值）。
    private func refreshEmphasis(animatingFocus: Bool? = nil) {
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
            let pronunciation = current ? 0.96 : (hovered ? 0.78 : 0.60)
            let translation = next.contains(index) ? (current ? 0.92 : (hovered ? 0.75 : 0.5)) : 0.45
            var motion = emphasisMotions[index] ?? EmphasisMotion(
                original: LyricsScalarMotion(position: row.timed ? 0.35 : 0.3),
                pronunciation: row.pronunciationRange == nil ? nil : LyricsScalarMotion(position: 0.60),
                translation: row.translationRange == nil ? nil : LyricsScalarMotion(position: 0.45)
            )
            motion.original.retarget(original, omega: LyricsMotionStyle.omega)
            motion.pronunciation?.retarget(pronunciation, omega: LyricsMotionStyle.omega)
            motion.translation?.retarget(translation, omega: LyricsMotionStyle.omega)
            if let animatingFocus {
                motion.sharpness.retarget(current && !row.isBlank ? 1 : 0, omega: LyricsMotionStyle.omega)
                if !animatingFocus { motion.sharpness.finish() }
            }
            emphasisMotions[index] = motion
        }
        emphasizedIndices = next
        if animatesEmphasis {
            paintFocus()
            hasActiveEmphasis = true
            onNeedsAnimation?()
        } else {
            finishEmphasis()
        }
    }

    /// 跟随位移时共用它的进度，悬停和视口无需移动时单独按时间收敛。
    func advanceEmphasis(by delta: TimeInterval, focusStep: Double?) {
        guard hasActiveEmphasis, focusStep != 0 else { return }
        var running = false
        for index in Array(emphasisMotions.keys) {
            guard var motion = emphasisMotions[index] else { continue }
            motion.original.advanceEmphasis(by: delta, focusStep: focusStep)
            motion.pronunciation?.advanceEmphasis(by: delta, focusStep: focusStep)
            motion.translation?.advanceEmphasis(by: delta, focusStep: focusStep)
            motion.sharpness.advanceEmphasis(by: delta, focusStep: focusStep)
            running = running
                || !motion.original.isSettled
                || motion.pronunciation?.isSettled == false
                || motion.translation?.isSettled == false
                || !motion.sharpness.isSettled
            emphasisMotions[index] = motion
            paint(index: index, motion: motion)
        }
        hasActiveEmphasis = running
        if !running { emphasisMotions = emphasisMotions.filter { emphasizedIndices.contains($0.key) } }
        paintFocus()
        textView.needsDisplay = true
    }

    func finishEmphasis() {
        for index in Array(emphasisMotions.keys) {
            guard var motion = emphasisMotions[index] else { continue }
            motion.original.finish()
            motion.pronunciation?.finish()
            motion.translation?.finish()
            motion.sharpness.finish()
            emphasisMotions[index] = motion
            paint(index: index, motion: motion)
        }
        hasActiveEmphasis = false
        emphasisMotions = emphasisMotions.filter { emphasizedIndices.contains($0.key) }
        paintFocus()
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

private extension LyricsScalarMotion {
    mutating func advanceEmphasis(by delta: TimeInterval, focusStep: Double?) {
        if let focusStep { blend(by: focusStep) } else { advance(by: delta, omega: LyricsMotionStyle.omega, tolerance: 0.002) }
    }
}
