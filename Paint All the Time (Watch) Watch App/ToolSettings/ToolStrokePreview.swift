import SwiftUI

struct ToolStrokePreview: View {
    let style: PencilStyle
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let a = SIMD2<Float>(Float(size.width * 0.15), Float(size.height * 0.7))
            let b = SIMD2<Float>(Float(size.width * 0.35), Float(size.height * 0.05))
            let c = SIMD2<Float>(Float(size.width * 0.65), Float(size.height * 0.95))
            let d = SIMD2<Float>(Float(size.width * 0.85), Float(size.height * 0.3))
            let samples = (0...40).map { index -> PointerSample in
                let t = Float(index) / 40
                let u = 1 - t
                let position = a * (u*u*u) + b * (3*u*u*t) + c * (3*u*t*t) + d * (t*t*t)
                return PointerSample(position: position, pressure: 1, timestamp: Double(t))
            }
            var strokes: [Stroke] = []
            if style.instrument == .eraser {
                var demoStyle = PencilStyle.initial(for: .monoline)
                demoStyle.color = SIMD4(0.15, 0.35, 0.95, 1)
                demoStyle.width = 5
                for row in 1...3 {
                    if style.eraserMode == .objects && row == 2 { continue }
                    let y = Float(size.height) * Float(row) / 4
                    let line = [PointerSample(position: SIMD2(Float(size.width) * 0.1, y), pressure: 1, timestamp: 0),
                                PointerSample(position: SIMD2(Float(size.width) * 0.9, y), pressure: 1, timestamp: 1)]
                    strokes.append(Stroke(points: line, style: demoStyle))
                }
            }
            strokes.append(Stroke(points: samples, style: style))
            if let bitmap = WatchBitmapRenderer.render(strokes: strokes, size: size, scale: displayScale, paperWhite: 0.88) {
                context.draw(Image(decorative: bitmap, scale: displayScale),
                             in: CGRect(origin: .zero, size: size))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(Color(white: 0.88), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel(L10n.text("Stroke preview"))
    }
}
