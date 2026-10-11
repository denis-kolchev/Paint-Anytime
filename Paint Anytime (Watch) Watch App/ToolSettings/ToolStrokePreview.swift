import SwiftUI

struct ToolStrokePreview: View {
    static let viewportShape = RoundedRectangle(cornerRadius: 16)

    let style: PencilStyle
    var synchronizesOpacity = true
    let fillPreviewSize: CGSize
    let fillFocusRequest: Int
    let applyFillSensitivity: (Float) -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var bitmap: CGImage?
    @State private var renderer = ToolPreviewRenderer()

    var body: some View {
        Group {
            if style.instrument == .fill {
                ToolFillPreview(style: style, synchronizesOpacity: synchronizesOpacity,
                                size: fillPreviewSize, focusRequest: fillFocusRequest,
                                applySensitivity: applyFillSensitivity)
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
            for row in 1...3 {
                if style.eraserMode == .objects && row == 2 { continue }
                let y = Float(size.height) * Float(row) / 4
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
    let synchronizesOpacity: Bool
    let size: CGSize
    let focusRequest: Int
    let applySensitivity: (Float) -> Void
    @State private var renderer = ToolFillPreviewRenderer()
    @State private var bitmap: CGImage?

    private var request: ToolFillPreviewRequest {
        ToolFillPreviewRequest(style: style,
            size: CGSize(width: max(1, size.width.rounded()),
                         height: max(1, size.height.rounded())),
            synchronizesOpacity: synchronizesOpacity)
    }

    var body: some View {
        // Render on a stable canvas shared by all settings pages. Layout only
        // moves its center; the viewport clips it without stretching the ink.
        Color.white
            .overlay {
                if let bitmap {
                    Image(decorative: bitmap, scale: 2)
                        .frame(width: CGFloat(bitmap.width) / 2,
                               height: CGFloat(bitmap.height) / 2)
                        .allowsHitTesting(false)
                }
            }
            .task(id: request) {
                do {
                    try await Task.sleep(for: .milliseconds(30))
                    let result = await renderer.render(request)
                    try Task.checkCancellation()
                    if let result { bitmap = result.image }
                } catch {}
            }
            .task(id: focusRequest) {
                guard focusRequest > 0 else { return }
                // A tap always requests a calculation, even during Crown updates.
                // With no containing threshold, use the minimum sensitivity.
                let result = await renderer.render(request)
                guard !Task.isCancelled, let result else { return }
                applySensitivity(result.safeSensitivity ?? 0)
            }
    }
}

nonisolated private struct ToolFillPreviewRequest: Equatable {
    let style: PencilStyle
    let size: CGSize
    let synchronizesOpacity: Bool
}

private actor ToolFillPreviewRenderer {
    struct Result {
        let image: CGImage
        let safeSensitivity: Float?
    }

    private var boundaryRequest: ToolFillPreviewRequest?
    private var boundaryImage: CGImage?
    private var boundaryStroke: Stroke?
    private var safeSensitivity: Float?

    func render(_ request: ToolFillPreviewRequest) -> Result? {
        let size = request.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var keyStyle = request.style
        keyStyle.fillSensitivity = 0
        let key = ToolFillPreviewRequest(style: keyStyle, size: size,
                                        synchronizesOpacity: request.synchronizesOpacity)
        if boundaryRequest != key {
            var pen = PencilStyle.initial(for: .pen)
            pen.color = request.style.color
            pen.opacity = request.synchronizesOpacity ? request.style.effectiveOpacity : 1
            pen.width = 4
            let radius = max(1, min(max(1, size.width - 48), size.height) * 0.34)
            // This reference contour has constant nib width. Equal timestamps
            // keep Pen's speed smoothing from widening its starting point,
            // which would otherwise leave a bump where the circle closes.
            let points = (0...128).map { index in
                let angle = Double(index % 128) * 2 * Double.pi / 128
                return PointerSample(position: SIMD2(Float(center.x + radius * cos(angle)),
                                                     Float(center.y + radius * sin(angle))),
                                     pressure: 1, timestamp: 0)
            }
            let outline = Stroke(points: points, style: pen)
            guard let image = WatchBitmapRenderer.render(strokes: [outline], size: size, scale: 2)
                else { return nil }
            func escapes(_ percent: Int) -> Bool {
                var fill = request.style
                fill.fillSensitivity = Float(percent) / 100
                guard let stroke = WatchBitmapRenderer.floodFill(image: image, scale: 2,
                    point: center, style: fill) else { return true }
                return stroke.fillRects?.contains { rect in
                    rect.x <= 0 || rect.y <= 0 || rect.x + rect.z >= Float(image.width) / 2
                        || rect.y + rect.w >= Float(image.height) / 2
                } ?? true
            }
            // Connectivity grows monotonically with tolerance. Find the first
            // leaking integer percentage, then use the preceding percentage.
            var safe: Float?
            if !escapes(0) {
                var low = 0
                var high = 100
                while high - low > 1 {
                    guard !Task.isCancelled else { return nil }
                    let middle = (low + high) / 2
                    if escapes(middle) { high = middle } else { low = middle }
                }
                safe = Float(low) / 100
            }
            boundaryRequest = key
            boundaryImage = image
            boundaryStroke = outline
            safeSensitivity = safe
        }
        guard !Task.isCancelled, let boundaryImage, let boundaryStroke,
              let fill = WatchBitmapRenderer.floodFill(image: boundaryImage, scale: 2,
                  point: center, style: request.style),
              let image = WatchBitmapRenderer.render(strokes: [boundaryStroke, fill], size: size, scale: 2)
            else { return nil }
        return Result(image: image, safeSensitivity: safeSensitivity)
    }
}
