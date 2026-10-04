import SwiftUI

struct ToolStrokePreview: View {
    let style: PencilStyle
    @Environment(\.displayScale) private var displayScale
    @State private var bitmap: CGImage?
    @State private var renderer = ToolPreviewRenderer()

    var body: some View {
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
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(Color(white: 0.88), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel(L10n.text("Stroke preview"))
    }
}

nonisolated struct ToolPreviewRequest: Equatable {
    let style: PencilStyle
    let size: CGSize
    let scale: CGFloat
}

/// Preview rendering never executes inside SwiftUI's layout/drawing callbacks.
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
        let style = request.style
        let size = request.size
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
        strokes.append(Stroke(points: samples, style: style, id: strokeID))
        guard !Task.isCancelled,
              let image = WatchBitmapRenderer.render(strokes: strokes, size: size,
                  scale: request.scale, paperWhite: 0.88), !Task.isCancelled else { return nil }
        cache.append((request, image))
        if cache.count > 4 { cache.removeFirst() }
        return image
    }
}
