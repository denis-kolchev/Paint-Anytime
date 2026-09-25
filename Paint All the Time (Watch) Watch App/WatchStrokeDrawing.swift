import SwiftUI

// Procedural watchOS brushes. Apple Pencil pressure/tilt and PencilKit's
// proprietary ink textures are not available to this finger-driven canvas.
enum WatchStrokeDrawing {
    static func commands(for stroke: Stroke) -> [WatchDrawingCommand] {
        var context = WatchDrawingContext()
        draw(stroke, in: &context)
        return context.storage.commands
    }

    static func draw(_ stroke: Stroke, in context: inout GraphicsContext) {
        for command in commands(for: stroke) {
            var paint = context
            paint.opacity *= command.opacity
            if command.blendMode != .normal { paint.blendMode = command.blendMode }
            let c = command.rgba
            let color = Color(.sRGB, red: Double(c.x), green: Double(c.y),
                              blue: Double(c.z), opacity: Double(c.w))
            switch command.shape {
            case let .fill(path): paint.fill(path, with: .color(color))
            case let .stroke(path, style): paint.stroke(path, with: .color(color), style: style)
            }
        }
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
            // Apply opacity to a whole stroke so adjoining segments don't make dark seams.
            paint.opacity *= 0.38
            paint.blendMode = .multiply
            paint.stroke(centerline(stroke), with: .color(ink), style: StrokeStyle(
                lineWidth: CGFloat(stroke.style.width), lineCap: .square, lineJoin: .round))
            if stroke.points.count == 1, let point = stroke.points.first {
                let width = CGFloat(stroke.style.width)
                paint.fill(Path(CGRect(x: CGFloat(point.position.x) - width / 2,
                                       y: CGFloat(point.position.y) - width / 2,
                                       width: width, height: width)), with: .color(ink))
            }
        case .pencil, .crayon:
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
        let radius = Double(stroke.style.width) / 2
        let points = BrushGeometry.spacedPoints(for: stroke, spacing: max(0.5, stroke.style.width * 0.12))
        // Nested translucent washes produce a soft edge. Each wash is filled once;
        // separate strokes build color, without dark joints between input samples.
        for band in 0..<6 {
            var wash = Path()
            let scale = 1 - Double(band) * 0.105
            for (index, position) in points.enumerated() {
                let r = radius * scale * (0.92 + noise(index * 13) * 0.08)
                wash.addEllipse(in: CGRect(x: Double(position.x) - r, y: Double(position.y) - r,
                                           width: r * 2, height: r * 2))
            }
            var layer = context
            layer.blendMode = .multiply
            layer.opacity *= 0.055
            layer.fill(wash, with: .color(ink))
        }
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
