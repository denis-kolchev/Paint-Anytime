import SwiftUI

struct ToolStrokePreview: View {
    static let viewportShape = RoundedRectangle(cornerRadius: 16)
    static let paperWhite: CGFloat = 0.88
    /// Bitmap previews fill paper with `CGColor(gray:)`, a gamma 2.2 gray that lands on
    /// 230/255 in sRGB; `Color(white: 0.88)` would be 224/255 and read visibly darker.
    static let paperColor = Color(cgColor: CGColor(gray: paperWhite, alpha: 1))

    let style: PencilStyle
    let fillPreviewSize: CGSize
    /// Pencil and pastel styles a Crown step may switch to next. Their masks render
    /// off the main thread ahead of time, so the switch shows the current width at once.
    var upcomingTexturedStyles: [PencilStyle] = []
    @Environment(\.displayScale) private var displayScale
    @State private var lastMask: CGImage?
    /// Rendered grain coverage masks the body can tint synchronously.
    @State private var masks: [(request: ToolPreviewRequest, image: CGImage)] = []
    @State private var renderer = ToolPreviewRenderer()
    /// The direction of the last width change, so the next Crown step's mask comes first.
    @State private var widthDirection: Float = 1

    var body: some View {
        Group {
            if style.instrument == .fill {
                ToolFillPreview(style: style, size: fillPreviewSize)
            } else if style.instrument == .eraser && style.eraserMode == .objects {
                ToolObjectEraserPreview()
            } else if style.instrument == .pencil || style.instrument == .crayon {
                deferredPreview
            } else {
                Canvas { context, size in
                    let strokes = ToolPreviewStroke.make(style: style, size: size)
                    if let image = WatchBitmapRenderer.render(strokes: strokes, size: size,
                                                             scale: displayScale, paperWhite: Self.paperWhite) {
                        context.draw(Image(decorative: image, scale: displayScale),
                                     in: CGRect(origin: .zero, size: size))
                    }
                    if (style.instrument == .eraser && style.eraserMode == .pixels) || style.instrument == .blur,
                       let stroke = strokes.last, let endpoint = stroke.points.last?.position {
                        let diameter = CGFloat(stroke.style.width)
                        let ring = Path(ellipseIn: CGRect(
                            x: CGFloat(endpoint.x) - diameter / 2,
                            y: CGFloat(endpoint.y) - diameter / 2,
                            width: diameter, height: diameter))
                        context.stroke(ring, with: .color(.black.opacity(0.65)), lineWidth: 1.5)
                    }
                }
            }
        }
        // The settings viewport clips the paper, stroke and overlay together.
        .background(Self.paperColor)
        .background {
            GeometryReader { geometry in
                let plan = texturedPlan(size: geometry.size)
                Color.clear.task(id: plan) { await render(plan) }
            }
        }
        .onChange(of: style.width) { old, new in
            if new != old { widthDirection = new > old ? 1 : -1 }
        }
        .accessibilityLabel(L10n.text("Stroke preview"))
    }

    private var deferredPreview: some View {
        // Grain coverage depends only on the instrument, width and ink alpha; color and
        // opacity tint it linearly, exactly as the pixel path composites. So color and
        // opacity changes redraw in the same frame, and resizes stretch the nearest mask.
        Canvas { context, size in
            guard let choice = bestMask(for: size) else { return }
            let color = style.color
            let centerline = choice.clipsToWidth ? Self.centerline(of: style, size: size) : nil
            context.withCGContext { cg in
                let rect = CGRect(origin: .zero, size: size)
                cg.saveGState()
                // Grains first; a soft footprint then trims them (destination-in), all in
                // one transparency layer so nothing below the Canvas is touched.
                if centerline != nil { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
                // Core Graphics images draw bottom-up inside SwiftUI's top-down context.
                cg.saveGState()
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                cg.clip(to: rect, mask: choice.image)
                cg.setFillColor(CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y),
                                        blue: CGFloat(color.z), alpha: CGFloat(style.effectiveOpacity)))
                cg.fill(rect)
                cg.restoreGState()
                if let centerline {
                    // The footprint's strokes merge in their own layer first; that layer
                    // then applies as one alpha mask.
                    cg.setBlendMode(.destinationIn)
                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                    Self.drawSoftFootprint(centerline, width: CGFloat(style.width), in: cg)
                    cg.endTransparencyLayer()
                    cg.endTransparencyLayer()
                }
                cg.restoreGState()
            }
        }
    }

    /// The preview stroke's centerline, in top-down view coordinates.
    private static func centerline(of style: PencilStyle, size: CGSize) -> CGPath? {
        guard let points = ToolPreviewStroke.make(style: style, size: size).last?.points,
              let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: CGFloat(first.position.x), y: CGFloat(first.position.y)))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: CGFloat(point.position.x), y: CGFloat(point.position.y)))
        }
        return path
    }

    /// The footprint at `width` with an edge that fades linearly inward over the grain
    /// field's feather instead of a hard cut, so the clipped grains thin out toward the edge.
    /// Nested strokes from widest to narrowest, each at 1 / (strokes left), build a linear
    /// alpha ramp: no blur filter is needed on every Crown step.
    private static func drawSoftFootprint(_ centerline: CGPath, width: CGFloat, in cg: CGContext) {
        // Mirrors WatchDryGrainField's edge feather, widened to cover the grain reach.
        let fade = max(0.5, min(3.6, width * 0.3))
        let steps = 6
        // A new transparency layer starts in normal blending; set it in case it doesn't.
        cg.setBlendMode(.normal)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for step in 0..<steps {
            let progress = CGFloat(step) / CGFloat(steps - 1)
            // The fade lies inside the nominal width: real grains stop at the footprint
            // edge, so a ramp straddling it made the shape look wider than the render.
            let lineWidth = max(0.2, width - 2 * fade * progress)
            cg.setStrokeColor(CGColor(gray: 0, alpha: 1 / CGFloat(steps - step)))
            cg.setLineWidth(lineWidth)
            cg.addPath(centerline)
            cg.strokePath()
        }
    }

    /// The style whose mask covers every narrower width: grains sit in paper space and the
    /// footprint only selects them, so clipping this mask to a narrower outline closely
    /// matches that width's own render, until the exact mask arrives.
    private static func widestStyle(_ style: PencilStyle) -> PencilStyle {
        var widest = style
        widest.width = style.instrument.maximumWidth
        return widest
    }

    /// Exact mask first; then the widest mask clipped to the current width, so every
    /// Crown step changes the width in the same frame; then the nearest width and size.
    private func bestMask(for size: CGSize) -> (image: CGImage, clipsToWidth: Bool)? {
        let request = ToolPreviewRequest(style: style, size: size, scale: displayScale)
        if let exact = masks.first(where: { $0.request == request }) { return (exact.image, false) }
        func distance(_ other: ToolPreviewRequest, to target: ToolPreviewRequest) -> CGFloat {
            CGFloat(abs(other.style.width - target.style.width)) * 1000
                + CGFloat(abs(other.style.color.w - target.style.color.w)) * 100
                + abs(other.size.width - target.size.width) + abs(other.size.height - target.size.height)
        }
        let widest = ToolPreviewRequest(style: Self.widestStyle(style), size: size, scale: displayScale)
        if let base = masks.filter({ $0.request.style == widest.style && $0.request.scale == displayScale })
            .min(by: { distance($0.request, to: widest) < distance($1.request, to: widest) }) {
            return (base.image, true)
        }
        let candidates = masks.filter { $0.request.style.instrument == style.instrument
            && $0.request.scale == displayScale }
        if let nearest = candidates.min(by: { distance($0.request, to: request) < distance($1.request, to: request) }) {
            return (nearest.image, false)
        }
        return lastMask.map { ($0, false) }
    }

    nonisolated private static func isTextured(_ style: PencilStyle) -> Bool {
        style.instrument == .pencil || style.instrument == .crayon
    }

    /// Once the widest mask exists, width changes show at once through it, and every
    /// render waits until the Crown settles: rendering during a spin would compete with
    /// the main thread. Before that, only the visible mask renders at once.
    private func texturedPlan(size: CGSize) -> ToolPreviewPlan {
        func request(_ style: PencilStyle) -> ToolPreviewRequest {
            ToolPreviewRequest(style: style, size: size, scale: displayScale)
        }
        func neighbor(_ step: Float) -> PencilStyle? {
            var next = style
            next.width = min(style.instrument.maximumWidth, max(1, style.width + step))
            return next.width == style.width ? nil : next
        }
        guard Self.isTextured(style) else {
            let upcoming = upcomingTexturedStyles.filter(Self.isTextured).map(request)
            return ToolPreviewPlan(visible: nil, deferred: upcoming)
        }
        let widest = Self.widestStyle(style)
        let hasWidest = masks.contains { $0.request.style == request(widest).style }
        var later: [PencilStyle] = hasWidest ? [style, widest] : [widest]
        // The next width in the Crown's direction first, then the other neighbor.
        later += [neighbor(widthDirection), neighbor(-widthDirection)].compactMap { $0 }
        later += upcomingTexturedStyles.filter { Self.isTextured($0) && $0.instrument != style.instrument }
        var deferred: [ToolPreviewRequest] = []
        for next in later.map(request) where !deferred.contains(next) { deferred.append(next) }
        return ToolPreviewPlan(visible: hasWidest ? nil : request(style), deferred: deferred)
    }

    private func render(_ plan: ToolPreviewPlan) async {
        if let visible = plan.visible {
            guard let mask = await mask(for: visible) else { return }
            lastMask = mask
        }
        // A newer plan cancels this sleep, so a spinning Crown renders only what is shown.
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        for request in plan.deferred {
            guard await mask(for: request) != nil else { return }
        }
    }

    /// A cached mask, or a new one rendered off the main thread; nil once cancelled.
    private func mask(for request: ToolPreviewRequest) async -> CGImage? {
        if let cached = masks.first(where: { $0.request == request }) { return cached.image }
        guard let next = await renderer.render(request), !Task.isCancelled else { return nil }
        masks.removeAll { $0.request == request }
        masks.append((request, next))
        // Resize animations produce in-between sizes; keep two sizes per mask so they
        // don't evict the masks prepared for the next instrument or width.
        if let oldest = masks.firstIndex(where: { $0.request.style == request.style }),
           masks.filter({ $0.request.style == request.style }).count > 2 {
            masks.remove(at: oldest)
        }
        if masks.count > 10,
           let evicted = masks.firstIndex(where: { $0.request.style.width != $0.request.style.instrument.maximumWidth }) {
            // Keep the widest masks: they carry every in-between width.
            masks.remove(at: evicted)
        }
        return next
    }
}

nonisolated struct ToolPreviewPlan: Equatable {
    let visible: ToolPreviewRequest?
    let deferred: [ToolPreviewRequest]

    /// Order-insensitive: the direction update right after a width change reorders the
    /// deferred masks, and must not restart a visible render already in progress.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visible == rhs.visible && lhs.deferred.count == rhs.deferred.count
            && lhs.deferred.allSatisfy(rhs.deferred.contains)
    }
}

private struct ToolObjectEraserPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || scenePhase != .active)) { timeline in
            let elapsed = reduceMotion ? 2.2
                : max(0, timeline.date.timeIntervalSince(startedAt)).truncatingRemainder(dividingBy: 5.2)
            let progress = min(1, max(0, (elapsed - 0.6) / 3.2))
            // After the sweep, briefly hold the empty paper and restore the lines.
            let restoration = min(1, max(0, (elapsed - 4.4) / 0.8))
            let cursorOpacity = min(1, max(0, elapsed / 0.2))
                * min(1, max(0, (4.0 - elapsed) / 0.2))

            Canvas { context, size in
                let radius = min(9.0, size.height * 0.07)
                let center = CGPoint(
                    x: size.width * (0.5 + 0.16 * sin(progress * .pi * 2)),
                    y: size.height * (0.04 + 0.92 * progress))
                let blue = Color(.sRGB, red: 0.15, green: 0.35, blue: 0.95)
                for row in 1...7 {
                    let y = size.height * CGFloat(row) / 8
                    // Object erasing removes the entire stroke at first contact,
                    // rather than cutting a hole along the cursor's path.
                    let touched = elapsed >= 0.6 && center.y + radius >= y - 2.5
                    var lineContext = context
                    lineContext.opacity = touched ? restoration : 1
                    var line = Path()
                    line.move(to: CGPoint(x: size.width * 0.1, y: y))
                    line.addLine(to: CGPoint(x: size.width * 0.9, y: y))
                    lineContext.stroke(line, with: .color(blue),
                                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }

                let cursor = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2))
                var cursorContext = context
                cursorContext.opacity = cursorOpacity
                cursorContext.fill(cursor, with: .color(ToolStrokePreview.paperColor))
                cursorContext.stroke(cursor, with: .color(.black.opacity(0.65)), lineWidth: 1.5)
            }
        }
        .onAppear { startedAt = Date() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startedAt = Date() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Identifies a grain coverage mask: the style without its color and opacity, which
/// tint the mask at draw time.
nonisolated struct ToolPreviewRequest: Equatable {
    let style: PencilStyle
    let size: CGSize
    let scale: CGFloat

    init(style: PencilStyle, size: CGSize, scale: CGFloat) {
        var maskStyle = style
        maskStyle.color = SIMD4(1, 1, 1, style.color.w)
        maskStyle.opacity = 1
        maskStyle.blendingMode = .hybrid
        self.style = maskStyle
        self.size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
        self.scale = scale
    }
}

/// Textured pencil and crayon masks render outside layout/drawing callbacks.
actor ToolPreviewRenderer {
    private let strokeID = UUID()

    /// White ink on black paper, so each pixel's gray level is the stroke's coverage;
    /// returned as a gray image that `clip(to:mask:)` reads as alpha.
    func render(_ request: ToolPreviewRequest) -> CGImage? {
        assert(!Thread.isMainThread, "Tool preview must render off the main thread")
        guard !Task.isCancelled else { return nil }
        let size = request.size
        let strokes = ToolPreviewStroke.make(style: request.style, size: size, id: strokeID)
        // Pencil and pastel use the live drawing's pixel grain path; the CG replay remains
        // the fallback (Render debug switches off).
        let fast = strokes.count == 1
            ? WatchBitmapRenderer.renderDryPixel(strokes[0], size: size, scale: request.scale, paperWhite: 0)
            : nil
        guard !Task.isCancelled,
              let image = fast ?? WatchBitmapRenderer.render(strokes: strokes, size: size,
                  scale: request.scale, paperWhite: 0), !Task.isCancelled else { return nil }
        return Self.coverageMask(from: image)
    }

    /// Copies the red channel byte for byte, so no color conversion alters coverage.
    private static func coverageMask(from image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let rgba = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width * 4, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        rgba.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let source = rgba.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var gray = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) { gray[index] = source[index * 4] }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

nonisolated private enum ToolPreviewStroke {
    static func make(style: PencilStyle, size: CGSize, id: UUID = UUID()) -> [Stroke] {
        let a = SIMD2<Float>(Float(size.width * 0.15), Float(size.height * 0.7))
        let b = SIMD2<Float>(Float(size.width * 0.35), Float(size.height * 0.05))
        let c = SIMD2<Float>(Float(size.width * 0.65), Float(size.height * 0.95))
        let d = SIMD2<Float>(Float(size.width * 0.85), Float(size.height * 0.3))
        var samples = (0...40).map { index -> PointerSample in
            let t = Float(index) / 40
            let u = 1 - t
            let position = a * (u*u*u) + b * (3*u*u*t) + c * (3*u*t*t) + d * (t*t*t)
            return PointerSample(position: position, pressure: 1, timestamp: Double(t))
        }
        if style.instrument == .pen {
            // Pen width follows speed: retime the demo like a hand that starts slowly and
            // steadily speeds up, so the line tapers from the thickest to the thinnest
            // width in one smooth sweep. A geometric rise reads as an even taper.
            let slow: Float = 30, fast: Float = 900 // pt/s
            var time: Double = 0
            for index in samples.indices.dropFirst() {
                let t = (Float(index) - 0.5) / Float(samples.count - 1)
                let speed = slow * exp(log(fast / slow) * t)
                let delta = samples[index].position - samples[index - 1].position
                time += Double((delta * delta).sum().squareRoot() / speed)
                samples[index].timestamp = time
            }
        }
        var strokes: [Stroke] = []
        if style.instrument == .eraser || style.instrument == .blur {
            var demoStyle = PencilStyle.initial(for: .monoline)
            demoStyle.color = SIMD4(0.15, 0.35, 0.95, 1)
            demoStyle.width = 5
            let rowCount = 7
            for row in 1...rowCount {
                if style.instrument == .eraser && style.eraserMode == .objects && row == (rowCount + 1) / 2 { continue }
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
        ToolStrokePreview.paperColor
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
