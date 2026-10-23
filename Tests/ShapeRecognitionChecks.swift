import Foundation
import simd

@main
struct ShapeRecognitionChecks {
    static func samples(_ points: [SIMD2<Float>]) -> [PointerSample] {
        points.enumerated().map { PointerSample(position: $0.element, pressure: 0.75, timestamp: Double($0.offset) / 60) }
    }
    static func polyline(_ vertices: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            for i in 0..<20 { points.append(a + (b - a) * (Float(i) / 20)) }
        }
        points.append(vertices.last!)
        return points
    }
    static func expect(_ points: [SIMD2<Float>], _ kind: ShapeRecognizer.Kind) {
        guard let result = ShapeRecognizer.recognize(samples(points)) else { fatalError("Missing \(kind)") }
        precondition(result.kind == kind, "Expected \(kind), got \(result.kind)")
        precondition(result.confidence >= 0.82)
    }
    @MainActor static func main() {
        let line = (0...60).map { SIMD2<Float>(Float($0) + 10, 30 + sin(Float($0)) * 0.7) }
        expect(line, .line)
        let circle = (0...90).map { i -> SIMD2<Float> in
            let t = Float(i) * 2 * .pi / 90
            let r: Float = 30 + sin(t * 7) * 0.6
            return SIMD2(60 + cos(t) * r, 60 + sin(t) * r)
        }
        expect(circle, .circle)
        let ellipse = (0...100).map { i -> SIMD2<Float> in
            let t = Float(i) * 2 * .pi / 100
            let x = cos(t) * 40, y = sin(t) * 20
            return SIMD2(60 + x * 0.8 - y * 0.6, 60 + x * 0.6 + y * 0.8)
        }
        expect(ellipse, .ellipse)
        let rectangle = polyline([SIMD2(20, 20), SIMD2(80, 20), SIMD2(80, 60), SIMD2(20, 60), SIMD2(20, 20)])
        expect(rectangle, .rectangle)
        let square = polyline([SIMD2(50, 10), SIMD2(90, 50), SIMD2(50, 90), SIMD2(10, 50), SIMD2(50, 10)])
        expect(square, .square)
        expect(polyline([SIMD2(20, 75), SIMD2(50, 15), SIMD2(80, 75), SIMD2(20, 75)]), .triangle)
        let arrow = polyline([SIMD2(10, 50), SIMD2(90, 50), SIMD2(70, 35), SIMD2(90, 50), SIMD2(70, 65)])
        expect(arrow, .arrow)
        expect(Array(circle.prefix(50)), .arc)
        expect(polyline([SIMD2(10,20), SIMD2(90,30), SIMD2(70,80), SIMD2(30,70), SIMD2(10,20)]), .quadrilateral)
        func loop(_ p: [SIMD2<Float>]) -> [SIMD2<Float>] { polyline(p + [p[0]]) }
        var additions: [(ShapeRecognizer.Kind, [SIMD2<Float>])] = []
        for n in 5...12 {
            let vertices = (0..<n).map { i -> SIMD2<Float> in
                let t = Float(i) * 2 * .pi / Float(n)
                return SIMD2(60 + 40*cos(t), 60 + 40*sin(t))
            }
            additions.append((n == 5 ? .pentagon : n == 6 ? .hexagon : .regularPolygon, loop(vertices)))
        }
        let star = (0..<10).map { i -> SIMD2<Float> in
            let t = Float(i) * .pi / 5
            let r: Float = i.isMultiple(of: 2) ? 40 : 20
            return SIMD2(60 + r*cos(t), 60 + r*sin(t))
        }
        additions.append((.star, loop(star)))
        let heart = (0...100).map { i -> SIMD2<Float> in
            let t = Float(i) * 2 * .pi / 100
            return SIMD2(60 + 40 * pow(sin(t), 3), 60 - 2.5 * (13*cos(t)-5*cos(2*t)-2*cos(3*t)-cos(4*t)))
        }
        additions.append((.heart, heart))
        let cloud = (0...120).map { i -> SIMD2<Float> in
            let t = Float(i) * 2 * .pi / 120
            let r: Float = 30 * (1 + 0.14*cos(6*t))
            return SIMD2(60 + 1.4*r*cos(t), 60 + r*sin(t))
        }
        additions.append((.cloud, cloud))
        additions.append((.blockArrow, loop([SIMD2(10,40), SIMD2(70,40), SIMD2(70,20), SIMD2(110,55), SIMD2(70,90), SIMD2(70,70), SIMD2(10,70)])))
        additions.append((.speechBubble, loop([SIMD2(10,10), SIMD2(110,10), SIMD2(110,70), SIMD2(70,70), SIMD2(35,95), SIMD2(40,70), SIMD2(10,70)])))
        let shaft = (0...60).map { i -> SIMD2<Float> in
            let t = Float(i) * .pi / 2 / 60
            return SIMD2(20 + 60*sin(t), 20 + 60*(1-cos(t)))
        }
        let curved = shaft + polyline([SIMD2(80,80), SIMD2(65,60), SIMD2(80,80), SIMD2(95,60)]).dropFirst()
        additions.append((.curvedArrow, Array(curved)))
        for (kind, points) in additions {
            expect(points, kind)
            if kind != .curvedArrow { expect(Array(points.reversed()), kind) }
            let transformed = points.enumerated().map { i, p -> SIMD2<Float> in
                let noise = sin(Float(i)*1.7) * 0.25
                return SIMD2(120 + 0.9*p.x - 0.6*p.y + noise, 40 + 0.6*p.x + 0.9*p.y - noise)
            }
            expect(transformed, kind)
        }
        let rejected = [
            [SIMD2<Float>(10, 10), SIMD2(10.2, 10), SIMD2(10.1, 10.1)],

            polyline([SIMD2(10, 10), SIMD2(80, 80), SIMD2(10, 80), SIMD2(80, 10), SIMD2(10, 10)]),
            polyline([SIMD2(10, 10), SIMD2(80, 10), SIMD2(10, 10), SIMD2(80, 10)]),
            [SIMD2<Float>(0, 0), SIMD2(.nan, 20), SIMD2(50, 50)]
        ]
        for points in rejected { precondition(ShapeRecognizer.recognize(samples(points)) == nil, "Unexpected snap") }

        var style = PencilStyle.initial(for: .monoline)
        style.width = 7; style.color = SIMD4(0.2, 0.4, 0.8, 1); style.opacity = 0.6
        let tool = PencilTool(), input = samples(line)
        tool.begin(at: input[0], style: style)
        input.dropFirst().forEach { tool.update(with: $0) }
        let original = tool.activeStroke!
        precondition(tool.recognizeShape())
        precondition(tool.shapeState == .snapped && tool.activeStroke!.style == style)
        precondition(tool.activeStroke!.id == original.id && tool.activeStroke!.inputStream == nil)
        precondition(tool.activeStroke!.geometryRevision != original.geometryRevision)
        let snapped = tool.activeStroke!
        tool.update(with: PointerSample(position: input.last!.position + SIMD2(0.3, 0.2), pressure: 1, timestamp: 3))
        precondition(tool.activeStroke == snapped, "Hold jitter must not adjust snapped geometry")
        let moved = PointerSample(position: SIMD2(95, 70), pressure: 1, timestamp: 4)
        tool.update(with: moved)
        precondition(tool.shapeState == .adjusting && tool.activeStroke!.points != snapped.points)
        let finished = tool.end(at: moved)!
        precondition(finished.style == style && finished.id == original.id)
        precondition(tool.activeStroke == nil && tool.shapeState == .drawing)
        tool.begin(at: input[0], style: style)
        tool.cancel()
        precondition(!tool.recognizeShape())
        style.instrument = .eraser
        tool.begin(at: input[0], style: style)
        input.dropFirst().forEach { tool.update(with: $0) }
        precondition(!tool.recognizeShape(), "Erasers must never snap")
        print("PASS: shape candidates, rejection, styling, hold jitter, adjustment and cancellation")
    }
}
