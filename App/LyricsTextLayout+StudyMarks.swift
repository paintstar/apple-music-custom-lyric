import AppKit
import ShinAppleKit

/// 生词下划线临时属性、整句笔记标记绘制及鼠标划词/行定位提取。
/// 全程只读写 `NSLayoutManager` 临时属性，绝不改动 `NSTextStorage` 字符串或引起重排。
@MainActor
extension LyricsTextLayout {

    func clearStudyMarks() {
        clozeRangesByLine = [:]
        guard storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        manager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        reapplyEmphasisColors()
    }

    func applyStudyMarks(
        document: LyricDocument,
        occurrences: [VocabularyOccurrence],
        clozeEnabled: Bool = false
    ) {
        let previousClozeLines = Set(clozeRangesByLine.keys)
        self.clozeEnabled = clozeEnabled
        clozeRangesByLine = [:]

        guard storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        manager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        clearClozeForegroundAttributes(forLineIds: previousClozeLines)

        let styleValue = NSNumber(value: NSUnderlineStyle.single.rawValue)
        let colorValue = NSColor.systemTeal.withAlphaComponent(0.75)
        var collectedCloze: [UUID: [NSRange]] = [:]

        for occurrence in occurrences where occurrence.lyricDocumentId == document.id {
            guard let lineId = occurrence.lineId,
                  let rowIndex = rowIndices[lineId] else { continue }
            let row = rows[rowIndex]
            guard !row.isBlank, row.originalRange.length > 0,
                  let localRange = resolvedUnderlineRange(for: occurrence, in: row) else { continue }
            let targetRange = NSRange(
                location: row.originalRange.location + localRange.location,
                length: localRange.length
            )
            guard targetRange.location >= 0,
                  NSMaxRange(targetRange) <= storage.length else { continue }
            manager.addTemporaryAttribute(.underlineStyle, value: styleValue, forCharacterRange: targetRange)
            manager.addTemporaryAttribute(.underlineColor, value: colorValue, forCharacterRange: targetRange)
            collectedCloze[lineId, default: []].append(targetRange)
        }

        for (lineId, ranges) in collectedCloze {
            clozeRangesByLine[lineId] = Self.mergeOverlappingRanges(ranges)
        }
        applyClozeColors()
    }

    func refreshClozeVisibility(forLineIds lineIds: [UUID]) {
        guard clozeEnabled, storage.length > 0 else { return }
        for lineId in lineIds {
            guard let index = rowIndices[lineId],
                  let ranges = clozeRangesByLine[lineId], !ranges.isEmpty else { continue }
            if let motion = emphasisMotions[index] {
                paint(index: index, motion: motion)
            } else if lineId != hoveredId {
                for range in ranges where NSMaxRange(range) <= storage.length {
                    manager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
                }
            }
        }
        textView.needsDisplay = true
    }

    func drawClozeMasks(in dirtyRect: NSRect) {
        guard clozeEnabled, !clozeRangesByLine.isEmpty, storage.length > 0 else { return }
        let visible = visibleRows(in: dirtyRect.insetBy(dx: 0, dy: -12))
        guard !visible.isEmpty else { return }
        manager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let fillColor = NSColor.white.withAlphaComponent(0.22)
        let strokeColor = NSColor.white.withAlphaComponent(0.32)
        let emptySelection = NSRange(location: NSNotFound, length: 0)

        for row in visible where row.id != hoveredId && !row.isBlank && row.originalRange.length > 0 {
            guard let ranges = clozeRangesByLine[row.id], !ranges.isEmpty else { continue }
            for range in ranges where range.length > 0 && NSMaxRange(range) <= storage.length {
                let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphRange.length > 0 else { continue }
                manager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: emptySelection,
                    in: container
                ) { rect, _ in
                    Self.drawClozeCapsule(
                        rect: rect.offsetBy(dx: origin.x, dy: origin.y),
                        fillColor: fillColor,
                        strokeColor: strokeColor
                    )
                }
            }
        }
    }

    private func clearClozeForegroundAttributes(forLineIds lineIds: Set<UUID>) {
        for lineId in lineIds {
            guard let rowIndex = rowIndices[lineId] else { continue }
            let range = rows[rowIndex].originalRange
            if range.length > 0, NSMaxRange(range) <= storage.length {
                manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
        }
    }

    private func applyClozeColors() {
        reapplyEmphasisColors()
        guard clozeEnabled, storage.length > 0 else { return }
        for (lineId, ranges) in clozeRangesByLine where lineId != hoveredId {
            if let index = rowIndices[lineId], emphasisMotions[index] != nil {
                continue
            }
            for range in ranges where NSMaxRange(range) <= storage.length {
                manager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
            }
        }
        textView.needsDisplay = true
    }

    private static func drawClozeCapsule(rect: NSRect, fillColor: NSColor, strokeColor: NSColor) {
        guard !rect.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let verticalInset = min(1.5, rect.height * 0.08)
        let drawRect = rect.insetBy(dx: -2, dy: verticalInset)
        guard drawRect.width > 2, drawRect.height > 2 else { return }
        let radius = min(6, drawRect.height * 0.35)
        let path = NSBezierPath(roundedRect: drawRect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private static func mergeOverlappingRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { lhs, rhs in
                lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
            }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.location <= NSMaxRange(last) {
                let end = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func drawStudyNoteIndicators(in dirtyRect: NSRect) {
        let visible = visibleRows(in: dirtyRect.insetBy(dx: 0, dy: -12))
        guard !visible.isEmpty else { return }
        let rightEdge = textView.bounds.maxX
        guard rightEdge > 20 else { return }

        NSColor.systemTeal.withAlphaComponent(0.72).setFill()
        for row in visible where row.hasStudyNote && !row.isBlank && row.originalRange.length > 0 {
            let badgeWidth: CGFloat = 6.5
            let badgeHeight: CGFloat = 9.0
            let x = max(4, rightEdge - badgeWidth - 6)
            let y = row.frame.minY + min(max(4, row.frame.height * 0.25), 10)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + badgeWidth, y: y))
            path.line(to: NSPoint(x: x + badgeWidth, y: y + badgeHeight))
            path.line(to: NSPoint(x: x + badgeWidth * 0.5, y: y + badgeHeight - 2.6))
            path.line(to: NSPoint(x: x, y: y + badgeHeight))
            path.close()
            path.fill()
        }
    }

    func nonBlankRow(at point: NSPoint) -> Row? {
        guard let hit = row(at: point), !hit.isBlank, hit.originalRange.length > 0 else { return nil }
        return hit
    }

    func lineAnchorRect(for lineId: UUID, viewportRectConverter: (NSRect) -> CGRect) -> CGRect? {
        guard let index = rowIndices[lineId] else { return nil }
        let row = rows[index]
        guard !row.isBlank, row.originalRange.length > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let rectInTextView = row.frame.offsetBy(dx: origin.x, dy: origin.y)
        return viewportRectConverter(rectInTextView)
    }

    func wordSelection(
        for selectedRange: NSRange,
        document: LyricDocument,
        viewportRectConverter: (NSRect) -> CGRect
    ) -> LyricsWordSelection? {
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= storage.length,
              let match = singleIntersectingOriginalRow(for: selectedRange) else { return nil }

        let row = match.row
        let intersection = match.intersection
        let nsText = storage.string as NSString
        let rawSelection = nsText.substring(with: intersection)
        let trimmed = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let leadingCount = Self.leadingWhitespaceUTF16Count(in: rawSelection)
        let trimmedUTF16Length = (trimmed as NSString).length
        let adjustedLocationInStorage = intersection.location + leadingCount
        guard adjustedLocationInStorage >= row.originalRange.location,
              adjustedLocationInStorage + trimmedUTF16Length <= NSMaxRange(row.originalRange) else { return nil }

        let trimmedStorageRange = NSRange(location: adjustedLocationInStorage, length: trimmedUTF16Length)
        let utf16Location = adjustedLocationInStorage - row.originalRange.location
        let line = resolvedLine(for: row, in: document)
        let lineText = line?.text ?? nsText.substring(with: row.originalRange)
        let translation = line?.translations[LyricsSyncConstants.translationLanguage]?.text

        manager.ensureLayout(for: container)
        let glyphRange = manager.glyphRange(forCharacterRange: trimmedStorageRange, actualCharacterRange: nil)
        var rectInContainer = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        if rectInContainer.isEmpty || rectInContainer.width <= 0 {
            rectInContainer = row.frame
        }
        let origin = textView.textContainerOrigin
        let rectInTextView = rectInContainer.offsetBy(dx: origin.x, dy: origin.y)

        return LyricsWordSelection(
            documentId: document.id,
            documentRevision: document.revision,
            lineId: row.id,
            lineText: lineText,
            lineTranslation: translation,
            startMs: line?.startMs,
            surface: trimmed,
            utf16Location: utf16Location,
            utf16Length: trimmedUTF16Length,
            anchorRectInScrollViewport: viewportRectConverter(rectInTextView)
        )
    }

    private func singleIntersectingOriginalRow(for selectedRange: NSRange) -> (row: Row, intersection: NSRange)? {
        guard !rows.isEmpty else { return nil }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(rows[middle].originalRange) <= selectedRange.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let selectionEnd = NSMaxRange(selectedRange)
        var matched: (row: Row, intersection: NSRange)?
        var index = lower
        while index < rows.count, rows[index].originalRange.location < selectionEnd {
            let candidate = rows[index]
            index += 1
            guard !candidate.isBlank, candidate.originalRange.length > 0 else { continue }
            let intersection = NSIntersectionRange(selectedRange, candidate.originalRange)
            guard intersection.length > 0 else { continue }
            if matched != nil {
                return nil
            }
            matched = (candidate, intersection)
        }
        return matched
    }

    private func resolvedUnderlineRange(for occurrence: VocabularyOccurrence, in row: Row) -> NSRange? {
        if occurrence.utf16Location >= 0,
           occurrence.utf16Length > 0,
           occurrence.utf16Location + occurrence.utf16Length <= row.originalRange.length {
            return NSRange(location: occurrence.utf16Location, length: occurrence.utf16Length)
        }
        let surface = occurrence.surfaceInLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty, NSMaxRange(row.originalRange) <= storage.length else { return nil }
        let rowText = (storage.string as NSString).substring(with: row.originalRange) as NSString
        let found = rowText.range(of: surface)
        guard found.location != NSNotFound, found.length > 0 else { return nil }
        return found
    }

    private func resolvedLine(for row: Row, in document: LyricDocument) -> LyricLine? {
        if let index = rowIndices[row.id], index < document.lines.count, document.lines[index].id == row.id {
            return document.lines[index]
        }
        return document.lines.first { $0.id == row.id }
    }

    private static func leadingWhitespaceUTF16Count(in text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += scalar.utf16.count
            } else {
                break
            }
        }
        return count
    }
}
