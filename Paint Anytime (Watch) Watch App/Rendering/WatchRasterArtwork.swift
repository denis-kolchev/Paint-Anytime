import SwiftUI
import Combine
import simd

/// Present a fully materialized Core Graphics bitmap, using the same brush
/// geometry as export without SwiftUI's Canvas/ImageRenderer preparation path.
struct WatchRasterArtwork: View {
    var document: CanvasDocument? = nil
    var selectedLayerID: UUID? = nil
    var selectionPreview: WatchSelectionPreview? = nil
    var selectionSeed: WatchSelectionPreview? = nil
    let strokes: [Stroke]
    let activeStroke: Stroke?
    let documentID: ObjectIdentifier
    let documentRevision: UInt64
    var clearDocumentRevision: UInt64? = nil
    let activeStrokeRevision: UInt64
    let activeStrokeID: UInt64
    var onFramePrepared: (Bool) -> Void = { _ in }
    let zoom: Double
    /// Lets the touch handler queue live frames directly (Direct submit).
    var liveSubmitter: LiveFrameSubmitter? = nil
    /// The live ink tip is drawn above every layer, so the caller allows it only when
    /// nothing covers or clips the live layer: topmost, fully opaque, not alpha-locked.
    var allowsInkTip = false
    @State private var rasterZoom: Double = 1
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = TutorialDebug.trace("raster.body")
        GeometryReader { geometry in
            let _ = TutorialDebug.trace("raster.geometry", "size=\(geometry.size)")
            RasterFrame(clearDocumentRevision: clearDocumentRevision, onFramePrepared: onFramePrepared, document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, selectionSeed: selectionSeed, strokes: strokes, activeStroke: activeStroke,
                        activeStrokeRevision: activeStrokeRevision, activeStrokeID: activeStrokeID,
                        key: WatchBitmapRenderer.CacheKey(documentID: documentID,
                            documentRevision: documentRevision, size: geometry.size,
                            // Keep the previous resolution until Crown input settles.
                            scale: WatchBitmapRenderer.rasterScale(displayScale: displayScale, zoom: rasterZoom)),
                        liveSubmitter: liveSubmitter, allowsInkTip: allowsInkTip && selectionPreview == nil)
        }
        .task(id: zoom) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                rasterZoom = max(1, zoom)
            } catch {
                // A new zoom value restarts the quiet period.
            }
        }
    }

    private struct RasterFrame: View {
        var clearDocumentRevision: UInt64?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var clearOpacity = 1.0
        var onFramePrepared: (Bool) -> Void
        let document: CanvasDocument?
        let selectedLayerID: UUID?
        let selectionPreview: WatchSelectionPreview?
        let selectionSeed: WatchSelectionPreview?
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let activeStrokeRevision: UInt64
        let activeStrokeID: UInt64
        let key: WatchBitmapRenderer.CacheKey
        var liveSubmitter: LiveFrameSubmitter?
        var allowsInkTip: Bool

        @StateObject private var frames = CanvasFrameQueue()
        @State private var finishedTransform: CGAffineTransform?

        private var displayFrame: WatchBitmapRenderer.ScreenFrame? {
            if let preview = selectionPreview, let prepared = frames.preparedFrame,
               prepared.selection?.sessionID == preview.sessionID, prepared.selection?.key == key {
                return prepared
            }
            return frames.frame
        }

        private var hasSelectionTexture: Bool {
            guard let texture = displayFrame?.selection, let selectionPreview else { return false }
            return texture.sessionID == selectionPreview.sessionID && texture.key == key
        }

        private func displayedTransform(_ texture: WatchBitmapRenderer.SelectionTexture) -> CGAffineTransform {
            if let selectionPreview, selectionPreview.sessionID == texture.sessionID {
                return selectionPreview.transform
            }
            // Hold the last interactive frame until the committed/cancelled frame
            // is ready, rather than snapping back while it is being rendered.
            return finishedTransform ?? texture.transform
        }

        private func staticTexture(_ image: CGImage) -> some View {
            Image(decorative: image, scale: key.scale)
                .resizable()
                .frame(width: key.size.width, height: key.size.height)
        }

        // No stroke arrays or point comparisons in task identity.
        private struct Request: Equatable {
            let key: WatchBitmapRenderer.CacheKey
            let activeStrokeRevision: UInt64
            let sessionID: UUID?
            let transform: CGAffineTransform?
        }

        private func artwork(_ frame: WatchBitmapRenderer.ScreenFrame) -> some View {
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.background, scale: key.scale)
                    .resizable()
                    .frame(width: key.size.width, height: key.size.height)
                if let texture = frame.selection {
                    ZStack(alignment: .topLeading) {
                        if let image = texture.layerBelow {
                            staticTexture(image)
                        }
                        Image(decorative: texture.image, scale: texture.key.scale)
                            .resizable()
                            .frame(width: texture.rect.width, height: texture.rect.height)
                            .offset(x: texture.rect.minX, y: texture.rect.minY)
                            .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
                            .transformEffect(displayedTransform(texture))
                        if let image = texture.layerAbove {
                            staticTexture(image)
                        }
                    }
                    .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
                    .clipped()
                    .compositingGroup()
                    .opacity(Double(texture.opacity))
                    if let image = texture.upperLayers {
                        staticTexture(image)
                    }
                }
                ForEach(frame.tiles) { tile in
                    Image(decorative: tile.image, scale: key.scale)
                        .resizable()
                        .frame(width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
            .clipped()
        }

        var body: some View {
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(frames.frame != nil)")
            let _ = RenderDiagnostics.bodyEvaluated()
            let _ = registerLiveSubmitter()
            Group {
                if let frame = displayFrame {
                    artwork(frame)
                } else {
                    Color.white
                }
            }
            .overlay(alignment: .topLeading) {
                if allowsInkTip, RenderStageSwitches.isOn(.inkTip),
                   let stroke = frames.tipStroke(for: activeStroke) {
                    InkTipOverlay(stroke: stroke, renderedPoints: frames.renderedPoints(of: stroke))
                        .frame(width: key.size.width, height: key.size.height)
                }
            }
            .task(id: Request(key: key, activeStrokeRevision: activeStrokeRevision, sessionID: selectionPreview?.sessionID, transform: hasSelectionTexture ? nil : selectionPreview?.transform)) { @MainActor in
                if hasSelectionTexture { return }
                frames.submit(document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, strokes: strokes, activeStroke: activeStroke,
                              activeStrokeRevision: activeStrokeRevision, key: key, activeStrokeID: activeStrokeID,
                              animatesClear: activeStroke == nil && key.documentRevision == clearDocumentRevision)
            }
            .task(id: Request(key: key, activeStrokeRevision: 0, sessionID: selectionSeed?.sessionID, transform: nil)) {
                await frames.prepareSelection(selectionSeed, key: key)
            }
            .onChange(of: selectionPreview?.transform) { old, new in
                if new == nil, let old {
                    finishedTransform = old
                }
            }
            .onChange(of: selectionPreview?.sessionID) { old, new in
                if new == nil, let old {
                    frames.holdPreparedSelection(sessionID: old)
                }
            }
            .transaction { $0.animation = nil }
            .overlay {
                if let transition = frames.clearTransition {
                    artwork(transition.frame)
                        .compositingGroup()
                        .opacity(clearOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: frames.clearTransition?.id) {
                guard let transition = frames.clearTransition else { return }
                clearOpacity = 1
                await Task.yield()
                guard !Task.isCancelled else { return }
                let duration = reduceMotion ? 0.15 : 0.3
                withAnimation(.easeInOut(duration: duration)) { clearOpacity = 0 }
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                if frames.clearTransition?.id == transition.id { frames.clearTransition = nil }
            }
            .onChange(of: frames.preparedResult) { _, result in
                guard let result, result.key == key else { return }
                onFramePrepared(result.succeeded)
            }
            .onDisappear { frames.stop() }
        }

        /// Hand the touch handler a closure with this body's layout and document, so a
        /// live frame can be queued without waiting for the `.task(id:)` hop. Assigning a
        /// plain property during body publishes nothing and invalidates no view.
        private func registerLiveSubmitter() {
            guard let liveSubmitter else { return }
            guard selectionPreview == nil, !hasSelectionTexture else {
                liveSubmitter.submit = nil
                return
            }
            let frames = frames, document = document, selectedLayerID = selectedLayerID
            let strokes = strokes, key = key
            liveSubmitter.submit = { stroke, revision, strokeID in
                frames.submit(document: document, selectedLayerID: selectedLayerID, selectionPreview: nil,
                              strokes: strokes, activeStroke: stroke, activeStrokeRevision: revision,
                              key: key, activeStrokeID: strokeID)
            }
        }
    }
}

/// Direct submit: the touch handler queues the live frame in the same run-loop
/// pass that applied the sample. The raster view re-registers `submit` on every body
/// evaluation; the later `.task(id:)` submit of the same revision is then dropped.
@MainActor
final class LiveFrameSubmitter {
    fileprivate var submit: ((Stroke, UInt64, UInt64) -> Void)?

    func submitLive(_ stroke: Stroke?, revision: UInt64, strokeID: UInt64) {
        guard RenderStageSwitches.isOn(.directSubmit), let stroke else { return }
        // Object erasing edits the document mid-stroke; the captured one would be stale.
        if stroke.style.instrument == .eraser, stroke.style.eraserMode == .objects { return }
        submit?(stroke, revision, strokeID)
    }
}

/// Live ink tip: the samples the displayed bitmap does not include yet, drawn with the
/// brush's own vector geometry in the touch's SwiftUI update.
/// Only opaque vector brushes qualify: drawn over the bitmap they match it exactly,
/// while textured or translucent brushes would differ or double their coverage.
private struct InkTipOverlay: View {
    let stroke: Stroke
    let renderedPoints: Int

    static func supports(_ style: PencilStyle) -> Bool {
        switch style.instrument {
        case .monoline, .pen, .fountainPen, .reed:
            return style.color.w * style.effectiveOpacity >= 0.999
        default:
            return false
        }
    }

    var body: some View {
        Canvas { context, _ in
            guard let path = tailPath() else { return }
            let ink = stroke.style.color
            let color = Color(.sRGB, red: Double(ink.x), green: Double(ink.y), blue: Double(ink.z), opacity: 1)
            switch path {
            case let .fill(shape):
                context.fill(shape, with: .color(color))
            case let .stroke(line, style):
                context.stroke(line, with: .color(color), style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private enum TailPath {
        case fill(Path)
        case stroke(Path, StrokeStyle)
    }

    /// The same geometry `WatchStrokeDrawing` uses for these brushes, for the tail only.
    private func tailPath() -> TailPath? {
        let samples = stroke.points
        guard Self.supports(stroke.style), !samples.isEmpty else { return nil }
        // Overlap the last rendered sample so the tail joins the bitmap without a gap.
        let start = min(samples.count - 1, max(0, renderedPoints - 1))
        let points = samples[start...].map(\.position)
        guard points.count > 1 || renderedPoints == 0 else { return nil }
        let width = max(0.1, stroke.style.width)
        switch stroke.style.instrument {
        case .monoline:
            if points.count == 1 {
                let r = CGFloat(width) / 2, p = points[0]
                return .fill(Path(ellipseIn: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r,
                                                    width: r * 2, height: r * 2)))
            }
            var line = Path()
            line.addLines(points.map { Self.point($0) })
            return .stroke(line, StrokeStyle(lineWidth: CGFloat(width), lineCap: .round, lineJoin: .round))
        case .pen:
            // Speed-dependent radii are smoothed from the stroke's start: take them
            // from the whole stroke, then build discs only for the tail.
            let radii = Array(BrushGeometry.radii(for: stroke)[start...])
            return .fill(Self.shape(BrushGeometry.roundPolygons(points: points, radii: radii)))
        case .fountainPen, .reed:
            // The nib is swept segment by segment, so the tail alone matches exactly.
            var tail = stroke
            tail.points = Array(samples[start...])
            return .fill(Self.shape(FountainPenGeometry.polygons(for: tail)))
        default:
            return nil
        }
    }

    private static func point(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }

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
}

/// Finish the in-flight frame, replacing only the pending request. Continuous
/// input therefore cannot starve publication by cancelling every render.
@MainActor
private final class CanvasFrameQueue: ObservableObject {
    struct ClearTransition {
        let id = UUID()
        let frame: WatchBitmapRenderer.ScreenFrame
    }
    @Published var clearTransition: ClearTransition?
    struct PreparedResult: Equatable {
        let key: WatchBitmapRenderer.CacheKey
        let succeeded: Bool
    }
    @Published private(set) var preparedResult: PreparedResult?
    @Published private(set) var frame: WatchBitmapRenderer.ScreenFrame?
    @Published private(set) var preparedFrame: WatchBitmapRenderer.ScreenFrame?
    private let renderer = WatchArtworkRenderer()
    private var preparationID = UUID()

    func prepareSelection(_ seed: WatchSelectionPreview?, key: WatchBitmapRenderer.CacheKey) async {
        let token = UUID()
        preparationID = token
        // Keep the previous interactive texture until its committed frame arrives.
        // A new seed is published as soon as the finger is released, and clearing
        // here could discard that texture before the view has a chance to hold it.
        guard let seed else { return }
        let next = await renderer.prepareSelectionFrame(seed, key: key)
        guard !Task.isCancelled, preparationID == token, next?.selection != nil else { return }
        preparedFrame = next
    }

    func holdPreparedSelection(sessionID: UUID) {
        // Invalidate outstanding preview jobs so they cannot overwrite the held
        // final transform while the committed document is being rendered.
        if latest?.selectionPreview?.sessionID == sessionID {
            latest = nil
            pending = nil
        }
        if let preparedFrame, preparedFrame.selection?.sessionID == sessionID {
            frame = preparedFrame
        }
    }

    private struct Job {
        let document: CanvasDocument?
        let selectedLayerID: UUID?
        let selectionPreview: WatchSelectionPreview?
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let key: WatchBitmapRenderer.CacheKey
        let activeStrokeID: UInt64
        let animatesClear: Bool
        let activeStrokeRevision: UInt64
        /// Diagnostics clock at submission; 0 when render debugging is compiled out.
        let submittedAt: UInt64
        /// Touch event this live frame answers, for the end-to-end figure; 0 otherwise.
        let eventAt: UInt64
    }
    private var pending: Job?
    private var latest: Job?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func submit(document: CanvasDocument?, selectedLayerID: UUID?, selectionPreview: WatchSelectionPreview?, strokes: [Stroke], activeStroke: Stroke?,
                activeStrokeRevision: UInt64 = 0, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64, animatesClear: Bool = false) {
        // Direct submit already queued this live sample; drop the `.task(id:)` duplicate.
        if let activeStroke, selectionPreview == nil, let latest,
           latest.selectionPreview == nil, latest.key == key,
           latest.activeStrokeID == activeStrokeID, latest.activeStroke?.id == activeStroke.id,
           latest.activeStrokeRevision == activeStrokeRevision { return }
        if !animatesClear, clearTransition != nil { clearTransition = nil }
        if pending != nil { RenderDiagnostics.frameCoalesced() }
        let job = Job(document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, strokes: strokes, activeStroke: activeStroke, key: key, activeStrokeID: activeStrokeID, animatesClear: animatesClear,
                      activeStrokeRevision: activeStrokeRevision,
                      submittedAt: RenderDiagnostics.begin(),
                      eventAt: RenderDiagnostics.frameSubmitted(live: activeStroke != nil))
        pending = job
        latest = job
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.pending, !Task.isCancelled {
                self.pending = nil
                let next = await self.render(job)
                guard !Task.isCancelled, self.generation == token else { return }
                self.publish(next, for: job)
            }
            if self.generation == token { self.worker = nil }
        }
    }

    /// Render stage: lasso preview, layer compositor or the single-layer cache.
    private func render(_ job: Job) async -> WatchBitmapRenderer.ScreenFrame? {
        RenderDiagnostics.end(.queue, job.submittedAt)
        let started = RenderDiagnostics.begin()
        defer { RenderDiagnostics.end(.render, started) }
        if let preview = job.selectionPreview {
            RenderDiagnostics.setPath("lasso")
            return await renderer.selectionFrame(preview, key: job.key)
        } else if let document = job.document {
            RenderDiagnostics.setPath("layers")
            return await renderer.layeredFrame(document: document, activeStroke: job.activeStroke,
                selectedLayerID: job.selectedLayerID, key: job.key)
        } else {
            RenderDiagnostics.setPath("1-layer")
            return await renderer.screenFrame(strokes: job.strokes, activeStroke: job.activeStroke,
                                              key: job.key, activeStrokeID: job.activeStrokeID)
        }
    }

    /// Publish stage: hand a still-current frame to SwiftUI.
    private func publish(_ next: WatchBitmapRenderer.ScreenFrame?, for job: Job) {
        // An older prefix of this gesture is useful. An old document,
        // cancelled gesture or viewport must never replace the new one.
        if let latest = self.latest,
           ((latest.key == job.key && latest.selectionPreview?.sessionID == job.selectionPreview?.sessionID) || Self.sameSelectionDrag(latest, job)),
           latest.activeStrokeID == job.activeStrokeID,
           latest.activeStroke?.id == job.activeStroke?.id, let next {
            if job.animatesClear, self.preparedResult?.key.documentRevision != job.key.documentRevision, let previous = self.frame {
                self.clearTransition = ClearTransition(frame: previous)
            }
            // Ink tip bookkeeping: which samples the displayed bitmap already contains.
            displayedStrokeID = job.activeStroke?.id
            displayedPointCount = job.activeStroke?.points.count ?? 0
            if job.activeStroke == nil { heldTipStroke = nil }
            self.frame = next
            // Assign only on change: every @Published write re-evaluates the raster body.
            let result = PreparedResult(key: job.key, succeeded: true)
            if self.preparedResult != result { self.preparedResult = result }
            RenderDiagnostics.framePublished(live: job.activeStroke != nil, submittedAt: job.submittedAt,
                                             eventAt: job.eventAt)
            if let texture = next.selection, let pending = self.pending,
               pending.key == texture.key,
               pending.selectionPreview?.sessionID == texture.sessionID {
                self.pending = nil
            }
        } else if next == nil, self.latest?.key == job.key {
            self.preparedResult = PreparedResult(key: job.key, succeeded: false)
        }
    }

    // MARK: Live ink tip

    private var displayedStrokeID: UUID?
    private var displayedPointCount = 0
    /// The lifted stroke, kept until its committed frame is published so the tip
    /// does not vanish for the frame between lift and commit.
    private var heldTipStroke: Stroke?

    /// Called from body; writes only plain properties, never a published one.
    func tipStroke(for active: Stroke?) -> Stroke? {
        if let active {
            heldTipStroke = active
            return active
        }
        return heldTipStroke
    }

    func renderedPoints(of stroke: Stroke) -> Int {
        displayedStrokeID == stroke.id ? displayedPointCount : 0
    }

    private static func sameSelectionDrag(_ latest: Job, _ rendered: Job) -> Bool {
        // A slower frame from the current drag is still useful while the finger
        // moves. Never publish it after commit, cancellation, or another drag.
        latest.selectionPreview != nil && latest.selectionPreview?.sessionID == rendered.selectionPreview?.sessionID
            && latest.key.documentID == rendered.key.documentID
            && latest.key.size == rendered.key.size && latest.key.scale == rendered.key.scale
    }

    func stop() {
        generation &+= 1
        preparationID = UUID()
        preparedFrame = nil
        worker?.cancel()
        worker = nil
        pending = nil
        latest = nil
        heldTipStroke = nil
    }
}
