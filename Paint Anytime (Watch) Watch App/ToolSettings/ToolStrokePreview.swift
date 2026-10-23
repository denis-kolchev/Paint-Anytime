import SwiftUI

struct ToolStrokePreview: View {
    static let viewportShape = RoundedRectangle(cornerRadius: 16)

    let style: PencilStyle
    let fillPreviewSize: CGSize
    @Environment(\.displayScale) private var displayScale
    @State private var bitmap: CGImage?
    @State private var renderer = ToolPreviewRenderer()

    var body: some View {
        Group {
            if style.instrument == .fill {
                ToolFillPreview(style: style, size: fillPreviewSize)
            } else if style.instrument == .pencil || style.instrument == .crayon {
                deferredPreview
            } else {
                Canvas { context, size in
                    let strokes = ToolPreviewStroke.make(style: style, size: size)
                    if let image = WatchBitmapRenderer.render(strokes: strokes, size: size,
                                                             scale: displayScale, paperWhite: 0.88) {
                        context.draw(Image(decorative: image, scale: displayScale),
                                     in: CGRect(origin: .zero, size: size))
                    }
                }
            }
        }
        // The settings viewport clips the paper, stroke and overlay together.
        .background(Color(white: 0.88))
        .accessibilityLabel(L10n.text("Stroke preview"))
    }

    private var deferredPreview: some View {
        GeometryReader { geometry in
            let request = ToolPreviewRequest(style: style,
                size: CGSize(width: max(1, geometry.size.width.rounded()),
                             height: max(1, geometry.size.height.rounded())),
                scale: displayScale)
            ZStack {
                Color(white: 0.88)
                if let bitmap {
                    Image(decorative: bitmap, scale: displayScale)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .task(id: request) {
                do {
                    // Keep displaying the existing bitmap while layout animates
                    // or the Crown emits a burst of width changes.
                    try await Task.sleep(for: .milliseconds(60))
                    try Task.checkCancellation()
                    let next = await renderer.render(request)
                    try Task.checkCancellation()
                    if let next { bitmap = next }
                } catch {
                    // A newer request owns the next update; keep the last frame.
                }
            }
        }
    }
}

nonisolated struct ToolPreviewRequest: Equatable {
    let style: PencilStyle
    let size: CGSize
    let scale: CGFloat
}

/// Textured pencil and crayon previews render outside layout/drawing callbacks.
/// A small cache also makes returning to a recent settings layout inexpensive.
actor ToolPreviewRenderer {
    private let strokeID = UUID()
    private var cache: [(request: ToolPreviewRequest, image: CGImage)] = []

    func render(_ request: ToolPreviewRequest) -> CGImage? {
        assert(!Thread.isMainThread, "Tool preview must render off the main thread")
        guard !Task.isCancelled else { return nil }
        if let index = cache.firstIndex(where: { $0.request == request }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.image
        }
        let size = request.size
        let strokes = ToolPreviewStroke.make(style: request.style, size: size, id: strokeID)
        guard !Task.isCancelled,
              let image = WatchBitmapRenderer.render(strokes: strokes, size: size,
                  scale: request.scale, paperWhite: 0.88), !Task.isCancelled else { return nil }
        cache.append((request, image))
        if cache.count > 4 { cache.removeFirst() }
        return image
    }
}

nonisolated private enum ToolPreviewStroke {
    static func make(style: PencilStyle, size: CGSize, id: UUID = UUID()) -> [Stroke] {
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
            let rowCount = 7
            for row in 1...rowCount {
                if style.eraserMode == .objects && row == (rowCount + 1) / 2 { continue }
                let y = Float(size.height) * Float(row) / Float(rowCount + 1)
                let line = [PointerSample(position: SIMD2(Float(size.width) * 0.1, y), pressure: 1, timestamp: 0),
                            PointerSample(position: SIMD2(Float(size.width) * 0.9, y), pressure: 1, timestamp: 1)]
                strokes.append(Stroke(points: line, style: demoStyle))
            }
        }
        strokes.append(Stroke(points: samples, style: style, id: id))
        return strokes
    }
}


private struct ToolFillPreview: View {
    let style: PencilStyle
    let size: CGSize

    var body: some View {
        // Keep the organic outline stable and center its visible bounds in the viewport.
        Color(white: 0.88)
            .overlay {
                Canvas { context, canvasSize in
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    let radius = max(1, min(max(1, size.width - 48), size.height) * 0.34)
                    let blot = Path { path in
                        for index in 0..<160 {
                            let angle = Double(index) / 160 * 2 * Double.pi
                            let reach = radius * (1 + 0.13 * sin(3 * angle + 0.6)
                                                     + 0.08 * cos(5 * angle - 0.4))
                            let point = CGPoint(x: reach * cos(angle),
                                                y: reach * sin(angle) * 1.16)
                            if index == 0 { path.move(to: point) }
                            else { path.addLine(to: point) }
                        }
                        path.closeSubpath()
                    }
                    let bounds = blot.boundingRect
                    let scale = min(1, canvasSize.width * 0.84 / bounds.width,
                                    canvasSize.height * 0.84 / bounds.height)
                    let centeredBlot = blot.applying(CGAffineTransform(
                        a: scale, b: 0, c: 0, d: scale,
                        tx: center.x - bounds.midX * scale,
                        ty: center.y - bounds.midY * scale))
                    let color = Color(.sRGB, red: Double(style.color.x),
                                      green: Double(style.color.y), blue: Double(style.color.z),
                                      opacity: Double(style.color.w * style.effectiveOpacity))
                    context.fill(centeredBlot, with: .color(color))
                }
                .allowsHitTesting(false)
            }
    }
}
