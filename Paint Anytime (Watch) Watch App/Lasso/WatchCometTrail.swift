import SwiftUI

/// Glowing "comet" trail for the Complete strokes outline: a bright head and a tail
/// whose color cycles purple → blue → orange → red → purple along its length.
///
/// Kept cheap for the watch: the tail is split into short polyline chunks (each a
/// linear gradient between its end colors), the soft glow is a single blurred layer,
/// and the head is a radial gradient fill instead of another blur.
nonisolated enum WatchCometTrail {
    /// Screen points for one full color cycle.
    private static let cycleLength: CGFloat = 220
    /// Target chunk count for short trails; long trails exceed it so chunks stay
    /// shorter than `maximumChunkLength`.
    private static let maximumChunks = 48
    private static let minimumChunkLength: CGFloat = 8
    /// Keeps every chunk well inside one palette segment (cycleLength / palette.count).
    private static let maximumChunkLength: CGFloat = cycleLength / 8

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

        var chunks: [Chunk] = []
        if points.count > 1 {
            var total: CGFloat = 0
            for index in 1..<points.count { total += WatchLassoGeometry.distance(points[index - 1], points[index]) }
            // Chunks stay short relative to the color cycle however long the trail gets;
            // otherwise a long trail has only a few chunks per cycle and the glow bands.
            let step = max(minimumChunkLength, min(total / CGFloat(maximumChunks), maximumChunkLength))
            chunks.reserveCapacity(Int(total / step) + 1)

            var path = Path()
            path.move(to: points[0])
            var chunkStart: CGFloat = 0, travelled: CGFloat = 0, startPoint = points[0]
            for index in 1..<points.count {
                travelled += WatchLassoGeometry.distance(points[index - 1], points[index])
                path.addLine(to: points[index])
                if travelled - chunkStart >= step || index == points.count - 1 {
                    // Each chunk carries a gradient from its start color to its end color,
                    // so neighbouring chunks meet at the same color instead of a hard step.
                    let lengths = [chunkStart, (chunkStart + travelled) / 2, travelled]
                    let rgbs = lengths.map(rgb(at:))
                    chunks.append(Chunk(path: path, start: startPoint, end: points[index],
                                        colors: rgbs.map { color($0) },
                                        cores: rgbs.map { color($0, whitened: 0.55) }))
                    chunkStart = travelled
                    startPoint = points[index]
                    path = Path()
                    path.move(to: points[index])
                }
            }
        }

        // Soft halo: opaque strokes in one layer, then a single blur and layer opacity,
        // so overlapping round caps at chunk joints don't show as brighter dots.
        // Filters and opacity apply to each subsequent drawing operation, so they are set
        // on the outer context and the chunks are drawn as one nested layer: the blur then
        // runs once over the whole trail instead of separately per chunk, which made the
        // halo uneven and segmented at every chunk joint.
        context.drawLayer { halo in
            halo.addFilter(.blur(radius: 5))
            halo.opacity = 0.75
            halo.drawLayer { layer in
                let style = StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                for chunk in chunks { layer.stroke(chunk.path, with: chunk.shading(chunk.colors), style: style) }
            }
        }
        // Bright core, washed toward white like a light trail.
        let core = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
        for chunk in chunks { context.stroke(chunk.path, with: chunk.shading(chunk.cores), style: core) }

        // Glowing head.
        let headColor = chunks.last?.colors.last ?? color(palette[0])
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

    private struct Chunk {
        let path: Path
        let start: CGPoint
        let end: CGPoint
        let colors: [Color]
        let cores: [Color]

        func shading(_ colors: [Color]) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: colors), startPoint: start, endPoint: end)
        }
    }

    /// Palette in OKLCH (lightness, chroma, hue in radians).
    private static let lchPalette: [RGB] = palette.map(oklch(from:))

    /// Interpolates in OKLCH along the shorter hue arc. A plain RGB blend of blue and
    /// orange (opposite hues) passes through gray, which reads as a gap in the glow
    /// once per color cycle; keeping chroma keeps every point of the trail saturated.
    private static func rgb(at length: CGFloat) -> RGB {
        let phase = (length / cycleLength).truncatingRemainder(dividingBy: 1) * CGFloat(lchPalette.count)
        let index = Int(phase) % lchPalette.count
        let t = Double(phase - CGFloat(Int(phase)))
        let a = lchPalette[index], b = lchPalette[(index + 1) % lchPalette.count]
        var hueDelta = (b.b - a.b).truncatingRemainder(dividingBy: 2 * .pi)
        if hueDelta > .pi { hueDelta -= 2 * .pi } else if hueDelta < -.pi { hueDelta += 2 * .pi }
        return srgb(fromOKLCH: (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + hueDelta * t))
    }

    private static func oklch(from rgb: RGB) -> RGB {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let labA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let labB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (lightness, hypot(labA, labB), atan2(labB, labA))
    }

    private static func srgb(fromOKLCH lch: RGB) -> RGB {
        let labA = lch.g * cos(lch.b), labB = lch.g * sin(lch.b)
        let l = pow(lch.r + 0.3963377774 * labA + 0.2158037573 * labB, 3)
        let m = pow(lch.r - 0.1055613458 * labA - 0.0638541728 * labB, 3)
        let s = pow(lch.r - 0.0894841775 * labA - 1.2914855480 * labB, 3)
        func gamma(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    private static func color(_ rgb: RGB, whitened amount: Double = 0) -> Color {
        Color(red: rgb.r + (1 - rgb.r) * amount, green: rgb.g + (1 - rgb.g) * amount,
              blue: rgb.b + (1 - rgb.b) * amount)
    }
}
