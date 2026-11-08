import SwiftUI

/// Glowing "comet" trail for the Complete strokes outline: a bright head and a tail
/// whose color cycles purple → blue → orange → red → purple along its length.
///
/// Kept cheap for the watch: the tail is split into a bounded number of polyline
/// chunks (one flat color each), the soft glow is a single blurred layer, and the
/// head is a radial gradient fill instead of another blur.
nonisolated enum WatchCometTrail {
    /// Screen points for one full color cycle.
    private static let cycleLength: CGFloat = 220
    /// Upper bound on stroke calls per pass, however long the trail gets.
    private static let maximumChunks = 48
    private static let minimumChunkLength: CGFloat = 8

    private static let palette: [RGB] = [
        (0.66, 0.45, 1.00), // purple
        (0.33, 0.56, 1.00), // blue
        (1.00, 0.62, 0.32), // orange
        (1.00, 0.33, 0.40), // red
    ]

    static func draw(_ outline: [CGPoint], transform: CGAffineTransform, in context: inout GraphicsContext) {
        guard let last = outline.last else { return }
        let points = outline.map { $0.applying(transform) }
        let head = last.applying(transform)

        var chunks: [(path: Path, color: Color, core: Color)] = []
        if points.count > 1 {
            var total: CGFloat = 0
            for index in 1..<points.count { total += WatchLassoGeometry.distance(points[index - 1], points[index]) }
            let step = max(minimumChunkLength, total / CGFloat(maximumChunks))
            chunks.reserveCapacity(Int(total / step) + 1)

            var path = Path()
            path.move(to: points[0])
            var chunkStart: CGFloat = 0, travelled: CGFloat = 0
            for index in 1..<points.count {
                travelled += WatchLassoGeometry.distance(points[index - 1], points[index])
                path.addLine(to: points[index])
                if travelled - chunkStart >= step || index == points.count - 1 {
                    let rgb = self.rgb(at: (chunkStart + travelled) / 2)
                    chunks.append((path, color(rgb), color(rgb, whitened: 0.55)))
                    chunkStart = travelled
                    path = Path()
                    path.move(to: points[index])
                }
            }
        }

        // Soft halo: opaque strokes in one layer, then a single blur and layer opacity,
        // so overlapping round caps at chunk joints don't show as brighter dots.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.opacity = 0.75
            let style = StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
            for chunk in chunks { layer.stroke(chunk.path, with: .color(chunk.color), style: style) }
        }
        // Bright core, washed toward white like a light trail.
        let core = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        for chunk in chunks { context.stroke(chunk.path, with: .color(chunk.core), style: core) }

        // Glowing head.
        let headColor = chunks.last?.color ?? color(palette[0])
        let glowRadius: CGFloat = 16
        context.fill(Path(ellipseIn: CGRect(x: head.x - glowRadius, y: head.y - glowRadius,
                                            width: glowRadius * 2, height: glowRadius * 2)),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white.opacity(0.9), location: 0.25),
                        .init(color: headColor.opacity(0.55), location: 0.5),
                        .init(color: headColor.opacity(0), location: 1),
                     ]), center: head, startRadius: 0, endRadius: glowRadius))
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private static func rgb(at length: CGFloat) -> RGB {
        let phase = (length / cycleLength).truncatingRemainder(dividingBy: 1) * CGFloat(palette.count)
        let index = Int(phase) % palette.count
        let t = Double(phase - CGFloat(Int(phase)))
        let a = palette[index], b = palette[(index + 1) % palette.count]
        return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    private static func color(_ rgb: RGB, whitened amount: Double = 0) -> Color {
        Color(red: rgb.r + (1 - rgb.r) * amount, green: rgb.g + (1 - rgb.g) * amount,
              blue: rgb.b + (1 - rgb.b) * amount)
    }
}
