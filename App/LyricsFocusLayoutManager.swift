import Accelerate
import AppKit

/// 只柔化视口内的字形，保留 TextKit 原生排版、选区和文字交互。
@MainActor
final class LyricsFocusLayoutManager: NSLayoutManager {
    /// 三角核的半宽以点计，与设备像素密度无关。
    private static let blurRadius: CGFloat = 3
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    struct FocusedRange: Equatable {
        let characters: NSRange
        let sharpness: Double
    }

    /// nil 表示全部清晰。其余情况只列出当前、悬停和仍在过渡的行。
    var focusedRanges: [FocusedRange]? {
        didSet {
            if oldValue != focusedRanges { firstTextView?.needsDisplay = true }
        }
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        if Thread.isMainThread {
            // TextKit 允许后台绘制；焦点需要访问主线程上的 NSTextView 状态。
            nonisolated(unsafe) let layout = self
            if MainActor.assumeIsolated({ layout.drawFocusedGlyphs(glyphs, at: origin) }) { return }
        }
        super.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    private func drawFocusedGlyphs(_ glyphs: NSRange, at origin: NSPoint) -> Bool {
        guard let focusedRanges, let textView = firstTextView,
              !textView.selectedRanges.contains(where: { $0.rangeValue.length > 0 }),
              let container = textView.textContainer, let context = NSGraphicsContext.current?.cgContext else {
            return false
        }

        let visibleClip = context.boundingBoxOfClipPath.intersection(textView.visibleRect)
        guard !visibleClip.isEmpty, !visibleClip.isInfinite else { return false }
        let paddedClip = visibleClip.insetBy(dx: -Self.blurRadius, dy: -Self.blurRadius)
        let visibleGlyphs = glyphRange(
            forBoundingRectWithoutAdditionalLayout: paddedClip.offsetBy(dx: -origin.x, dy: -origin.y), in: container
        )
        guard visibleGlyphs.length > 0 else { return false }
        let visibleCharacters = characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let focusedGlyphs: [(range: NSRange, sharpness: Double)] = focusedRanges.compactMap { focus in
            let overlapping = NSIntersectionRange(focus.characters, visibleCharacters)
            guard overlapping.length > 0 else { return nil }
            return (glyphRange(forCharacterRange: overlapping, actualCharacterRange: nil), focus.sharpness)
        }

        let softenedGlyphs = unfocusedGlyphs(in: visibleGlyphs, excluding: focusedGlyphs.map(\.range))
        let softenedClip = glyphClip(softenedGlyphs, at: origin, visible: visibleClip)
        guard softenedClip.isEmpty || drawSoftenedGlyphs(
            softenedGlyphs, at: origin, clip: softenedClip, sharpness: 0, context: context
        ) else {
            return false
        }
        for focus in focusedGlyphs {
            if focus.sharpness < 1 {
                let rowClip = glyphClip([focus.range], at: origin, visible: visibleClip)
                if rowClip.isEmpty || drawSoftenedGlyphs(
                    [focus.range], at: origin, clip: rowClip, sharpness: focus.sharpness, context: context
                ) { continue }
            }
            let sharp = NSIntersectionRange(focus.range, glyphs)
            if sharp.length > 0 { super.drawGlyphs(forGlyphRange: sharp, at: origin) }
        }
        return true
    }

    private func glyphClip(_ ranges: [NSRange], at origin: NSPoint, visible: CGRect) -> CGRect {
        // 为实际字形和柔化边缘分配位图，短句和未填满视口时省掉留白。
        var bounds = CGRect.null
        for range in ranges {
            enumerateLineFragments(forGlyphRange: range) { _, used, _, _, _ in
                bounds = bounds.union(used)
            }
        }
        return bounds.offsetBy(dx: origin.x, dy: origin.y)
            .insetBy(dx: -Self.blurRadius, dy: -Self.blurRadius).intersection(visible)
    }

    private func unfocusedGlyphs(in visible: NSRange, excluding focused: [NSRange]) -> [NSRange] {
        var softened: [NSRange] = []
        var start = visible.location
        for range in focused {
            let clipped = NSIntersectionRange(range, visible)
            guard clipped.length > 0 else { continue }
            if clipped.location > start { softened.append(NSRange(location: start, length: clipped.location - start)) }
            start = max(start, NSMaxRange(clipped))
        }
        if start < NSMaxRange(visible) { softened.append(NSRange(location: start, length: NSMaxRange(visible) - start)) }
        return softened
    }

    private func drawSoftenedGlyphs(
        _ ranges: [NSRange], at origin: NSPoint, clip: CGRect, sharpness: Double, context: CGContext
    ) -> Bool {
        // 裁切边缘对齐到设备像素，过渡中的位图与最终原生字形使用相同的像素相位。
        let deviceRect = context.convertToDeviceSpace(clip.insetBy(dx: -Self.blurRadius, dy: -Self.blurRadius)).integral
        guard !deviceRect.isEmpty, !deviceRect.isInfinite,
              let bitmap = makeBitmap(in: deviceRect), let softened = makeBitmap(in: deviceRect),
              let sourceData = bitmap.data, let destinationData = softened.data else { return false }
        let rect = context.convertToUserSpace(deviceRect)
        let scale = deviceRect.width / rect.width
        bitmap.translateBy(x: -rect.minX * scale, y: rect.maxY * scale)
        bitmap.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        for range in ranges { super.drawGlyphs(forGlyphRange: range, at: origin) }
        NSGraphicsContext.restoreGraphicsState()

        var source = vImage_Buffer(data: sourceData, height: vImagePixelCount(bitmap.height),
                                   width: vImagePixelCount(bitmap.width), rowBytes: bitmap.bytesPerRow)
        var destination = vImage_Buffer(data: destinationData, height: vImagePixelCount(softened.height),
                                        width: vImagePixelCount(softened.width), rowBytes: softened.bytesPerRow)
        let radius = Int((Self.blurRadius * scale).rounded())
        let result = soften(source: &source, destination: &destination, radius: radius, sharpness: Float(sharpness))
        guard result == kvImageNoError, let image = softened.makeImage() else { return false }
        context.saveGState()
        context.clip(to: clip)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
        return true
    }

    private func soften(
        source: inout vImage_Buffer, destination: inout vImage_Buffer, radius: Int, sharpness: Float
    ) -> vImage_Error {
        let size = UInt32(radius * 2 + 1)
        let flags = vImage_Flags(kvImageEdgeExtend)
        if sharpness == 0 {
            return vImageTentConvolve_ARGB8888(&source, &destination, nil, 0, 0, size, size, nil, flags)
        }
        // 在完整三角核与原像素之间连续调节权重，每帧只有一个字形图像。
        let peak = radius + 1
        let weight = (1 - sharpness) / Float(peak * peak)
        var kernel = (-radius...radius).map { Float(peak - abs($0)) * weight }
        kernel[radius] += sharpness
        return vImageSepConvolve_ARGB8888(&source, &destination, nil, 0, 0, kernel, size, kernel, size, 0, nil, flags)
    }

    private func makeBitmap(in pixels: CGRect) -> CGContext? {
        CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                  bytesPerRow: 0, space: Self.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    }
}
