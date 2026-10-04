import SwiftUI

// Procedural watchOS brushes. Apple Pencil pressure/tilt and PencilKit's
// proprietary ink textures are not available to this finger-driven canvas.
nonisolated enum WatchStrokeDrawing {
    static func commands(for stroke: Stroke) -> [WatchDrawingCommand] {
        var context = WatchDrawingContext()
        draw(stroke, in: &context)
        return context.storage.commands
    }

    private static func draw(_ stroke: Stroke, in context: inout WatchDrawingContext) {
        guard !stroke.points.isEmpty else { return }
        let ink = stroke.style.color
        var paint = context
        switch stroke.style.instrument {
        case .monoline:
            paint.stroke(centerline(stroke), with: .color(ink), style: StrokeStyle(
                lineWidth: CGFloat(stroke.style.width), lineCap: .round, lineJoin: .round))
            drawDotIfNeeded(stroke, ink: ink, in: &paint)
        case .pen:
            paint.fill(shape(BrushGeometry.roundPolygons(for: stroke)), with: .color(ink))
        case .fountainPen, .reed:
            paint.fill(shape(FountainPenGeometry.polygons(for: stroke)), with: .color(ink))
        case .marker:
            // Composite marker coverage once, even when a long path is drawn in batches.
            paint.usesOpacityLayer = true
            paint.opacity *= 0.7
            paint.blendMode = .multiply
            paint.fill(shape(BrushGeometry.markerPolygons(for: stroke)), with: .color(ink))
        case .pencil:
            pencil(stroke, ink: ink, in: &paint)
        case .crayon:
            texture(stroke, ink: ink, in: &paint)
        case .watercolor:
            watercolor(stroke, ink: ink, in: &paint)
        case .eraser:
            guard stroke.style.eraserMode == .pixels else { return }
            // Erase alpha, never paint white over the drawing.
            paint.blendMode = .destinationOut
            paint.stroke(centerline(stroke), with: .color(SIMD4<Float>(0, 0, 0, 1)), style: StrokeStyle(
                lineWidth: CGFloat(stroke.style.width), lineCap: .round, lineJoin: .round))
            drawDotIfNeeded(stroke, ink: SIMD4<Float>(0, 0, 0, 1), in: &paint)
        }
    }

    private static func centerline(_ stroke: Stroke) -> Path {
        var path = Path()
        guard let first = stroke.points.first else { return path }
        path.move(to: point(first.position))
        for sample in stroke.points.dropFirst() { path.addLine(to: point(sample.position)) }
        return path
    }

    private static func drawDotIfNeeded(_ stroke: Stroke, ink: SIMD4<Float>, in context: inout WatchDrawingContext) {
        guard stroke.points.count == 1, let sample = stroke.points.first else { return }
        let radius = CGFloat(stroke.style.width) / 2
        context.fill(Path(ellipseIn: CGRect(x: CGFloat(sample.position.x) - radius,
                                           y: CGFloat(sample.position.y) - radius,
                                           width: radius * 2, height: radius * 2)), with: .color(ink))
    }

    private static func shape(_ polygons: [[SIMD2<Float>]]) -> Path {
        var path = Path()
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            path.move(to: point(first))
            for vertex in polygon.dropFirst() { path.addLine(to: point(vertex)) }
            path.closeSubpath()
        }
        return path
    }

    // Paper-space grain: increasing the nib width exposes more grains instead
    // of spreading a fixed number over a larger footprint. One cell is deposited
    // only once per gesture, including joins and retraced sections.
    private static func pencil(_ stroke: Stroke, ink: SIMD4<Float>,
                               in context: inout WatchDrawingContext) {
        let polygons = BrushGeometry.pencilPolygons(for: stroke)
        // UUID bytes are stable across redraws, saves and exports. Every new
        // gesture deposits a different pattern, so repeated passes fill old gaps.
        let strokeSeed = stroke.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let cellSize = 0.48
        // Give every polygon the same winding before testing the union; joins
        // must not cut holes in the rectangular segment coverage.
        let footprintUnion = shape(polygons.map { polygon in
            let area = zip(polygon, polygon.dropFirst() + polygon.prefix(1)).reduce(Float(0)) {
                $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y
            }
            return area < 0 ? Array(polygon.reversed()) : polygon
        })
        let feather = Double(max(0.35, min(2.4, stroke.style.width * 0.20)))
        let probes = (0..<8).map { index in
            let angle = Double(index) * Double.pi / 4
            return CGPoint(x: cos(angle) * feather, y: sin(angle) * feather)
        }
        var deposited = Set<SIMD2<Int>>()
        var bands = Array(repeating: Path(), count: 9)
        for polygon in polygons {
            let footprint = shape([polygon])
            let bounds = footprint.boundingRect
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            let minX = Int(floor(bounds.minX / cellSize))
            let maxX = Int(floor(bounds.maxX / cellSize))
            let minY = Int(floor(bounds.minY / cellSize))
            let maxY = Int(floor(bounds.maxY / cellSize))
            for y in minY...maxY {
                for x in minX...maxX {
                    let cell = SIMD2<Int>(x, y)
                    guard !deposited.contains(cell) else { continue }
                    let seed = (x &* 73856093) ^ (y &* 19349663) ^ strokeSeed
                    let center = CGPoint(
                        x: (Double(x) + noise(seed)) * cellSize,
                        y: (Double(y) + noise(seed &+ 1)) * cellSize)
                    guard footprint.contains(center) else { continue }
                    deposited.insert(cell)
                    // Density and opacity fall near the boundary of the complete
                    // stroke, not at individual event segments. Broken edge grains
                    // retain the flat cap without a hard rectangular silhouette.
                    let inside = probes.reduce(0) { count, offset in
                        count + (footprintUnion.contains(CGPoint(
                            x: center.x + offset.x, y: center.y + offset.y)) ? 1 : 0)
                    }
                    let coverage = Double(inside) / Double(probes.count)
                    let edgeDensity = 0.12 + 0.88 * pow(coverage, 3)
                    guard noise(seed &+ 11) < edgeDensity else { continue }
                    let edgeBand = coverage > 0.87 ? 2 : (coverage > 0.62 ? 1 : 0)
                    // Overlapping irregular grains form dense graphite clusters.
                    // Coarser paper tooth modulates them independently of nib width.
                    let toothX = Int(floor(Double(center.x) / 1.8))
                    let toothY = Int(floor(Double(center.y) / 1.8))
                    let tooth = noise((toothX &* 83492791) ^ (toothY &* 2971215073) ^ strokeSeed)
                    guard noise(seed &+ 2) > (tooth < 0.22 ? 0.30 : 0.025) else { continue }
                    let band = edgeBand * 3 + min(2, Int(noise(seed &+ 3) * 3))
                    let grainScale: Float = tooth < 0.22 ? 0.75 : 1
                    let halfWidth = Float(0.30 + noise(seed &+ 4) * 0.34) * grainScale
                    let halfLength = Float(0.24 + noise(seed &+ 5) * 0.32) * grainScale
                    let angle = Float(noise(seed &+ 6)) * 2 * Float.pi
                    let along = SIMD2<Float>(cos(angle), sin(angle))
                    let across = SIMD2<Float>(-along.y, along.x)
                    let p = SIMD2<Float>(Float(center.x), Float(center.y))
                    let u = across * halfWidth
                    let v = along * halfLength
                    // Uneven facets soften the boundary while retaining a flat nib.
                    let vertices = [p - u - v * 0.7, p + u * 0.6 - v,
                                    p + u + v * 0.5, p - u * 0.7 + v]
                    bands[band].addPath(shape([vertices]))
                }
            }
        }
        for band in bands.indices {
            var layer = context
            layer.opacity *= [0.56, 0.76, 0.94][band % 3] * [0.30, 0.65, 1.0][band / 3]
            layer.fill(bands[band], with: .color(ink))
        }
    }

    private static func texture(_ stroke: Stroke, ink: SIMD4<Float>, in context: inout WatchDrawingContext) {
        let pastel = stroke.style.instrument == .crayon
        let radius = Double(stroke.style.width) / 2
        let points = BrushGeometry.spacedPoints(for: stroke, spacing: max(0.6, stroke.style.width * 0.13))
        var base = context
        base.opacity *= pastel ? 0.20 : 0.10
        base.stroke(centerline(stroke), with: .color(ink), style: StrokeStyle(
            lineWidth: CGFloat(stroke.style.width), lineCap: .round, lineJoin: .round))
        drawDotIfNeeded(stroke, ink: ink, in: &base)
        // A deterministic seed keeps grain stationary while adding points or redrawing.
        for band in 0..<3 {
            var grains = Path()
            for (index, position) in points.enumerated() {
                for grain in 0..<(pastel ? 10 : 6) {
                    let seed = index * 131 + grain * 17 + band * 7919
                    let angle = noise(seed) * 2 * Double.pi
                    let distance = sqrt(noise(seed + 3)) * radius
                    let size = pastel ? 0.45 + noise(seed + 7) * 0.9 : 0.18 + noise(seed + 7) * 0.45
                    let x = Double(position.x) + cos(angle) * distance
                    let y = Double(position.y) + sin(angle) * distance
                    grains.addEllipse(in: CGRect(x: x - size / 2, y: y - size / 2,
                                                 width: size, height: size))
                }
            }
            var layer = context
            layer.opacity *= pastel ? 0.20 + Double(band) * 0.08 : 0.16 + Double(band) * 0.07
            layer.fill(grains, with: .color(ink))
        }
    }

    private static func watercolor(_ stroke: Stroke, ink: SIMD4<Float>, in context: inout WatchDrawingContext) {
        let points = BrushGeometry.spacedPoints(for: stroke, spacing: max(0.5, stroke.style.width * 0.12))
        // Nested translucent washes produce a soft edge. Each wash is filled once;
        // separate strokes build color, without dark joints between input samples.
        for band in 0..<6 {
            var wash = Path()
            for (index, position) in points.enumerated() {
                let r = watercolorRadius(width: stroke.style.width, band: band, index: index)
                wash.addEllipse(in: CGRect(x: Double(position.x) - r, y: Double(position.y) - r,
                                           width: r * 2, height: r * 2))
            }
            var layer = context
            layer.blendMode = .multiply
            layer.opacity *= 1 - pow(1 - 0.7, 1.0 / 6)
            layer.fill(wash, with: .color(ink))
        }
    }

    static func watercolorRadius(width: Float, band: Int, index: Int) -> Double {
        Double(width) / 2 * (1 - Double(band) * 0.105) * (0.92 + noise(index * 13) * 0.08)
    }

    private static func noise(_ seed: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: seed) &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) & 0xffff) / 65535
    }

    private static func point(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }
}
