import AppKit

@MainActor
enum FloatingLyricsResizeCursor {
    typealias Edge = FloatingLyricsResizeGeometry.Edge
    private static let cursors = Dictionary(uniqueKeysWithValues: Edge.allCases.map { ($0, makeCursor(for: $0)) })
    private static let risingDiagonal = diagonalCursor(angle: .pi / 4)
    private static let fallingDiagonal = diagonalCursor(angle: -.pi / 4)

    static func cursor(for edge: Edge) -> NSCursor { cursors[edge] ?? .arrow }
    static func isResizeCursor(_ cursor: NSCursor) -> Bool { cursors.values.contains { $0 === cursor } }

    private static func makeCursor(for edge: Edge) -> NSCursor {
        if #available(macOS 15, *) { return .frameResize(position: position(for: edge), directions: .all) }
        return fallbackCursor(for: edge)
    }

    /// macOS 14 没有公开的 frameResize API；仅角光标用公开 NSImage/NSCursor 绘制方向一致的双箭头。
    static func fallbackCursor(for edge: Edge) -> NSCursor {
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return fallingDiagonal
        case .topRight, .bottomLeft: return risingDiagonal
        }
    }

    @available(macOS 15, *)
    private static func position(for edge: Edge) -> NSCursor.FrameResizePosition {
        switch edge {
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }

    private static func diagonalCursor(angle: Double) -> NSCursor {
        let side: CGFloat = 24
        let center = side / 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let vertices: [(Double, Double)] = [(-8, 0), (-3.5, 4.5), (-3.5, 1.5), (3.5, 1.5), (3.5, 4.5),
                                               (8, 0), (3.5, -4.5), (3.5, -1.5), (-3.5, -1.5), (-3.5, -4.5)]
            let path = NSBezierPath()
            for (index, vertex) in vertices.enumerated() {
                let point = NSPoint(x: center + vertex.0 * cos(angle) - vertex.1 * sin(angle),
                                    y: center + vertex.0 * sin(angle) + vertex.1 * cos(angle))
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1.5
            NSColor.white.setStroke()
            path.stroke()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }
}
