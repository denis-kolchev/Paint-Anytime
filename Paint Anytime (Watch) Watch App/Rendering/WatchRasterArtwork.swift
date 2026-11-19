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
    /// The paper's on-screen scale at 100% zoom; see `WatchBitmapRenderer.rasterScale`.
    var fit: CGFloat = 1
    /// Lets the touch handler queue live frames directly (Direct submit).
    var liveSubmitter: LiveFrameSubmitter? = nil
    /// The live ink tip is drawn above every layer, so the caller allows it only when
    /// nothing covers or clips the live layer: topmost, fully opaque, not alpha-locked.
    var allowsInkTip = false
    /// A viewport region rendered instead of the whole canvas; see `Region`.
    var region: Region? = nil
    /// Whether a region may keep showing a frame of its previous place or resolution
    /// until the new one is ready. Only while that frame's document is current and no
    /// stroke is being drawn below it: otherwise it would hide newer ink.
    var showsStaleRegionFrame = true
    /// Renders at utility priority: tiles around the view, prepared for a pan, must not
    /// take the cores from the tiles on screen or from the live stroke.
    var rendersInBackground = false
    /// Pixel view (`CanvasPixelView`): the saved grid's scale, nil when off. Caps the
    /// raster at that scale; rasters on it are magnified without smoothing.
    var pixelGridScale: CGFloat? = nil
    /// Lasso: the view the selection textures cover and the resolution it shows; see
    /// `WatchBitmapRenderer.SelectionViewport`. Nil keeps whole-paper textures.
    var selectionViewport: WatchBitmapRenderer.SelectionViewport? = nil
    /// Whether this raster shows the moving selection (its textures or a replay of the
    /// gesture). Until then the canvas keeps the zoom tiles, sharp and in place, above it.
    var onSelectionShown: (Bool) -> Void = { _ in }
    /// The seed session whose textures are prepared (or could not be): a drag may start.
    var onSelectionPrepared: (UUID) -> Void = { _ in }
    /// After a lasso commit, keep the last textures (the committed result, sharp over the
    /// view) until the zoom tiles above have rendered it, instead of the paper's own
    /// screen-resolution frame.
    var holdsSelectionFrame = false
    @State private var rasterZoom: Double = 1

    /// Part of the canvas rendered at a resolution the full canvas could not afford.
    /// The view still spans the paper; the region's frame sits at its own place in it,
    /// and nothing is drawn where it has no frame yet.
    struct Region: Equatable {
        /// Canvas points on whole pixels of `scale`.
        let origin: CGPoint
        let size: CGSize
        let scale: CGFloat
    }

    private func key(paperSize: CGSize) -> WatchBitmapRenderer.CacheKey {
        if let region {
            return WatchBitmapRenderer.CacheKey(documentID: documentID, documentRevision: documentRevision,
                                                size: region.size, scale: region.scale, origin: region.origin,
                                                isRegion: true, paper: paperSize)
        }
        // Keep the previous resolution until Crown input settles.
        let scale = WatchBitmapRenderer.rasterScale(displayScale: displayScale, zoom: rasterZoom,
            fit: fit, canvasSize: paperSize, layerCount: document?.layers.count ?? 1)
        return WatchBitmapRenderer.CacheKey(documentID: documentID,
            documentRevision: documentRevision, size: paperSize,
            scale: pixelGridScale.map { min(scale, $0) } ?? scale)
    }
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = TutorialDebug.trace("raster.body")
        GeometryReader { geometry in
            let _ = TutorialDebug.trace("raster.geometry", "size=\(geometry.size)")
            RasterFrame(clearDocumentRevision: clearDocumentRevision, onFramePrepared: onFramePrepared, document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, selectionSeed: selectionSeed, strokes: strokes, activeStroke: activeStroke,
                        activeStrokeRevision: activeStrokeRevision, activeStrokeID: activeStrokeID,
                        key: key(paperSize: geometry.size), paperSize: geometry.size, isRegion: region != nil,
                        showsStaleFrame: showsStaleRegionFrame, rendersInBackground: rendersInBackground,
                        pixelGridScale: pixelGridScale, selectionViewport: selectionViewport,
                        onSelectionShown: onSelectionShown, onSelectionPrepared: onSelectionPrepared,
                        holdsSelectionFrame: holdsSelectionFrame,
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
        let paperSize: CGSize
        /// A region shows nothing until its first frame, letting the canvas below show.
        let isRegion: Bool
        let showsStaleFrame: Bool
        let rendersInBackground: Bool
        let pixelGridScale: CGFloat?
        let selectionViewport: WatchBitmapRenderer.SelectionViewport?
        var onSelectionShown: (Bool) -> Void
        var onSelectionPrepared: (UUID) -> Void
        let holdsSelectionFrame: Bool
        var liveSubmitter: LiveFrameSubmitter?
        var allowsInkTip: Bool

        @StateObject private var frames = CanvasFrameQueue()

        /// `key` without the raster scale: textures follow the viewport, not the paper's
        /// raster, so a scale change must not restart their preparation.
        private var sceneKey: WatchBitmapRenderer.CacheKey {
            WatchBitmapRenderer.CacheKey(documentID: key.documentID, documentRevision: key.documentRevision,
                                         size: key.size, scale: 0, origin: key.origin, isRegion: key.isRegion)
        }
        @State private var finishedTransform: CGAffineTransform?

        /// Textures of the same document state fit whatever raster scale they were
        /// prepared at: each image carries its own scale and place. Requiring the exact
        /// key hid them for every zoom step until they were prepared again, and the old
        /// frame (the selection still at its old place) showed meanwhile.
        private func fits(_ texture: WatchBitmapRenderer.SelectionTexture) -> Bool {
            WatchBitmapRenderer.SelectionRenderCache.sameScene(texture.key, key)
        }

        private var displayFrame: WatchBitmapRenderer.ScreenFrame? {
            if let preview = selectionPreview, let prepared = frames.preparedFrame,
               let texture = prepared.selection, texture.sessionID == preview.sessionID, fits(texture) {
                return prepared
            }
            if holdsSelectionFrame, selectionPreview == nil, let held = frames.heldSelection,
               held.revision == key.documentRevision {
                return held.frame
            }
            return frames.frame
        }

        private var hasSelectionTexture: Bool {
            guard let texture = displayFrame?.selection, let selectionPreview else { return false }
            return texture.sessionID == selectionPreview.sessionID && fits(texture)
        }

        /// The moving selection is on screen: its textures, or a published replay frame.
        private var showsSelection: Bool {
            guard let selectionPreview else { return false }
            return hasSelectionTexture || frames.frameSessionID == selectionPreview.sessionID
        }

        private func displayedTransform(_ texture: WatchBitmapRenderer.SelectionTexture) -> CGAffineTransform {
            if let selectionPreview, selectionPreview.sessionID == texture.sessionID {
                return selectionPreview.transform
            }
            // Hold the last interactive frame until the committed/cancelled frame
            // is ready, rather than snapping back while it is being rendered.
            return finishedTransform ?? texture.transform
        }

        /// A raster has `ceil(size × scale)` pixels. Shown over `size`, a fractional last
        /// column or row (scale 2.25 on a 205 pt canvas) stretched the whole image towards
        /// it: content drifted by up to a fraction of a pixel, which zoom magnifies into a
        /// visible jump against the sharp region and misplaced the pixel-exact live tiles.
        /// Each pixel spans exactly `1 / scale` points; the caller clips the overhang.
        private func isOnPixelGrid(_ scale: CGFloat) -> Bool {
            pixelGridScale.map { abs(scale - $0) < 0.01 } ?? false
        }

        private static func pointSize(of image: CGImage, key: WatchBitmapRenderer.CacheKey) -> CGSize {
            guard image.width == Int(ceil(key.size.width * key.scale)),
                  image.height == Int(ceil(key.size.height * key.scale)) else { return key.size }
            return CGSize(width: CGFloat(image.width) / key.scale, height: CGFloat(image.height) / key.scale)
        }

        // No stroke arrays or point comparisons in task identity.
        private struct Request: Equatable {
            let key: WatchBitmapRenderer.CacheKey
            let activeStrokeRevision: UInt64
            let sessionID: UUID?
            let transform: CGAffineTransform?
            var viewport: WatchBitmapRenderer.SelectionViewport? = nil
        }

        /// An image of `scale` pixels per point placed at `rect`'s corner, one pixel per
        /// `1 / scale` points (no stretch towards a fractional last column).
        private func placed(_ image: CGImage, at origin: CGPoint, scale: CGFloat) -> some View {
            Image(decorative: image, scale: scale)
                .pixelGrid(isOnPixelGrid(scale))
                .resizable()
                .frame(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                .offset(x: origin.x, y: origin.y)
                .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
        }

        /// The lasso preview: the static scene over `staticRect` (the low-resolution
        /// underlay elsewhere), the selected layer with the moving selection between
        /// its lower and upper strokes, then the layers above.
        private func selectionArtwork(_ frame: WatchBitmapRenderer.ScreenFrame,
                                      _ texture: WatchBitmapRenderer.SelectionTexture) -> some View {
            let area = texture.staticRect, scale = texture.staticScale
            let paper = CGRect(origin: .zero, size: key.size)
            return ZStack(alignment: .topLeading) {
                if let underlay = texture.underlay {
                    Image(decorative: underlay, scale: CGFloat(underlay.width) / max(1, key.size.width))
                        .resizable()
                        .frame(width: key.size.width, height: key.size.height)
                        .mask {
                            Path { path in
                                path.addRect(paper)
                                path.addRect(area)
                            }
                            .fill(style: FillStyle(eoFill: true))
                        }
                }
                placed(frame.background, at: area.origin, scale: scale)
                ZStack(alignment: .topLeading) {
                    if let image = texture.layerBelow {
                        placed(image, at: area.origin, scale: scale)
                    }
                    placed(texture.image, at: texture.rect.origin, scale: texture.scale)
                        .transformEffect(displayedTransform(texture))
                    if let image = texture.layerAbove {
                        placed(image, at: area.origin, scale: scale)
                    }
                }
                .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
                .clipped()
                .compositingGroup()
                .opacity(Double(texture.opacity))
                if let image = texture.upperLayers {
                    placed(image, at: area.origin, scale: scale)
                }
            }
            .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
            .clipped()
            .frame(width: paperSize.width, height: paperSize.height, alignment: .topLeading)
        }

        /// A region frame rendered for the current place and resolution always shows; it
        /// catches up with commits incrementally. An older one only on the conditions of
        /// `showsStaleRegionFrame`, and for the document revision on screen.
        private var showsRegionFrame: Bool {
            guard isRegion, let shown = frames.frameKey else { return true }
            if shown.origin == key.origin && shown.size == key.size && shown.scale == key.scale { return true }
            return showsStaleFrame && shown.documentRevision == key.documentRevision
        }

        @ViewBuilder
        private func artwork(_ frame: WatchBitmapRenderer.ScreenFrame) -> some View {
            if let texture = frame.selection {
                selectionArtwork(frame, texture)
            } else {
                documentArtwork(frame)
            }
        }

        private func documentArtwork(_ frame: WatchBitmapRenderer.ScreenFrame) -> some View {
            // A region frame keeps the place and size it was rendered for until its
            // successor arrives; panning must not move stale pixels to a new place.
            let shown = isRegion ? (frames.frameKey ?? key) : key
            let backgroundSize = Self.pointSize(of: frame.background, key: shown)
            return ZStack(alignment: .topLeading) {
                Image(decorative: frame.background, scale: shown.scale)
                    .pixelGrid(isOnPixelGrid(shown.scale))
                    .resizable()
                    .frame(width: backgroundSize.width, height: backgroundSize.height)
                ForEach(frame.tiles) { tile in
                    Image(decorative: tile.image, scale: shown.scale)
                        .pixelGrid(isOnPixelGrid(shown.scale))
                        .resizable()
                        .frame(width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            .frame(width: shown.size.width, height: shown.size.height, alignment: .topLeading)
            .clipped()
            .offset(x: shown.origin.x, y: shown.origin.y)
            .frame(width: paperSize.width, height: paperSize.height, alignment: .topLeading)
        }

        var body: some View {
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(frames.frame != nil)")
            let _ = RenderDiagnostics.bodyEvaluated()
            let _ = registerLiveSubmitter()
            Group {
                if let frame = displayFrame, showsRegionFrame {
                    artwork(frame)
                } else if isRegion {
                    Color.clear
                } else {
                    Color.white
                }
            }
            .overlay(alignment: .topLeading) {
                if allowsInkTip, RenderStageSwitches.isOn(.inkTip),
                   let stroke = frames.tipStroke(for: activeStroke) {
                    // Canvas points: the overlay spans the paper, also above a region.
                    InkTipOverlay(stroke: stroke, renderedPoints: frames.renderedPoints(of: stroke),
                                  raster: CGRect(origin: key.origin, size: key.size), rasterScale: key.scale,
                                  isRegion: isRegion)
                        .frame(width: paperSize.width, height: paperSize.height, alignment: .topLeading)
                }
            }
            .task(id: Request(key: key, activeStrokeRevision: activeStrokeRevision, sessionID: selectionPreview?.sessionID, transform: hasSelectionTexture ? nil : selectionPreview?.transform,
                              viewport: selectionPreview == nil ? nil : selectionViewport)) { @MainActor in
                if hasSelectionTexture { return }
                frames.submit(document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview,
                              selectionViewport: selectionViewport, strokes: strokes, activeStroke: activeStroke,
                              activeStrokeRevision: activeStrokeRevision, key: key, activeStrokeID: activeStrokeID,
                              animatesClear: activeStroke == nil && key.documentRevision == clearDocumentRevision,
                              priority: rendersInBackground ? .utility : nil)
            }
            .task(id: Request(key: selectionViewport == nil ? key : sceneKey, activeStrokeRevision: 0,
                              sessionID: selectionSeed?.sessionID, transform: nil, viewport: selectionViewport)) {
                await frames.prepareSelection(selectionSeed, key: key, viewport: selectionViewport,
                                              onReady: onSelectionPrepared)
            }
            .onChange(of: holdsSelectionFrame) { _, holds in
                if !holds { frames.releaseHeldSelection() }
            }
            .onChange(of: selectionSeed == nil) { _, closed in
                if closed, !holdsSelectionFrame { frames.releaseHeldSelection() }
            }
            .onChange(of: showsSelection, initial: true) { _, shown in onSelectionShown(shown) }
            .onChange(of: selectionPreview?.transform) { old, new in
                if new == nil, let old {
                    finishedTransform = old
                }
            }
            .onChange(of: selectionPreview?.sessionID) { old, new in
                if new == nil, let old {
                    frames.holdPreparedSelection(sessionID: old, revision: key.documentRevision)
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
            let target = ObjectIdentifier(frames)
            // A raster that stops drawing the live stroke must stop taking direct submits.
            if let registered = frames.liveRegistration, registered !== liveSubmitter {
                registered.targets[target] = nil
            }
            frames.liveRegistration = liveSubmitter
            guard let liveSubmitter else { return }
            guard selectionPreview == nil, !hasSelectionTexture else {
                liveSubmitter.targets[target] = nil
                return
            }
            let frames = frames, document = document, selectedLayerID = selectedLayerID
            let strokes = strokes, key = key
            liveSubmitter.targets[target] = { stroke, revision, strokeID in
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
    /// One closure per raster that draws the live stroke: the paper and each region tile
    /// it crosses. Keyed by the raster's frame queue.
    fileprivate var targets: [ObjectIdentifier: (Stroke, UInt64, UInt64) -> Void] = [:]

    func submitLive(_ stroke: Stroke?, revision: UInt64, strokeID: UInt64) {
        guard RenderStageSwitches.isOn(.directSubmit), let stroke else { return }
        // Object erasing edits the document mid-stroke; the captured one would be stale.
        if stroke.style.instrument == .eraser, stroke.style.eraserMode == .objects { return }
        for submit in targets.values { submit(stroke, revision, strokeID) }
    }
}

/// Live ink tip: the samples the displayed bitmap does not include yet, drawn with the
/// brush's own vector geometry in the touch's SwiftUI update.
/// Only opaque vector brushes qualify: drawn over the bitmap they match it exactly,
/// while textured or translucent brushes would differ or double their coverage.
private struct InkTipOverlay: View {
    let stroke: Stroke
    let renderedPoints: Int
    /// Canvas points of the raster below and its pixels per point.
    let raster: CGRect
    let rasterScale: CGFloat
    let isRegion: Bool
    @Environment(\.displayScale) private var displayScale

    /// Largest side of the tip's Canvas in pixels.
    private static let maximumPixelSide: CGFloat = 2048

    static func supports(_ style: PencilStyle) -> Bool {
        switch style.instrument {
        case .monoline, .pen, .fountainPen, .reed:
            return style.color.w * style.effectiveOpacity >= 0.999
        default:
            return false
        }
    }

    /// The canvas view magnifies everything by the zoom (`scaleEffect`), and a Canvas
    /// rasterizes at its own layout size: spanning the paper at the display scale, the
    /// tip was magnified up to ~600× at the zoom limit and showed a soft edge. The Canvas
    /// now covers only the tail, at the resolution of the raster below it (screen
    /// resolution in zoom tiles), and is shrunk back so the zoom restores its size.
    var body: some View {
        if let path = tailPath(), let area = area(of: path) {
            let k = magnification(for: area)
            let ink = stroke.style.color
            let color = Color(.sRGB, red: Double(ink.x), green: Double(ink.y), blue: Double(ink.z), opacity: 1)
            Canvas { context, _ in
                context.scaleBy(x: k, y: k)
                context.translateBy(x: -area.minX, y: -area.minY)
                switch path {
                case let .fill(shape):
                    context.fill(shape, with: .color(color))
                case let .stroke(line, style):
                    context.stroke(line, with: .color(color), style: style)
                }
            }
            .frame(width: area.width * k, height: area.height * k)
            .scaleEffect(1 / k, anchor: .topLeading)
            .offset(x: area.minX, y: area.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The tail's bounds within reach of the raster below. A tile's tip may run into
    /// neighbouring tiles that have not drawn the newest samples yet, so it reaches one
    /// tile size past its own.
    private func area(of path: TailPath) -> CGRect? {
        let bounds: CGRect
        switch path {
        case let .fill(shape): bounds = shape.boundingRect
        case let .stroke(line, style):
            bounds = line.boundingRect.insetBy(dx: -style.lineWidth / 2, dy: -style.lineWidth / 2)
        }
        let reach = isRegion ? raster.insetBy(dx: -raster.width, dy: -raster.height) : raster
        // One pixel of margin keeps the antialiased edge inside the Canvas.
        let pad = 1 / max(1, rasterScale)
        let area = bounds.insetBy(dx: -pad, dy: -pad).intersection(reach)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        return area
    }

    /// Canvas points per canvas point: the raster's resolution over the display's, never
    /// below the display's resolution unless that exceeds `maximumPixelSide`.
    private func magnification(for area: CGRect) -> CGFloat {
        let display = max(1, displayScale)
        let wanted = max(1, rasterScale / display)
        let side = max(1, max(area.width, area.height) * display)
        return min(wanted, max(0.25, Self.maximumPixelSide / side))
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
            return .fill(Path(BrushGeometry.roundPath(points: points, radii: radii)))
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
    /// The key `frame` was rendered for.
    private(set) var frameKey: WatchBitmapRenderer.CacheKey?
    /// The lasso session `frame` previews (textures or a replay), nil for a document frame.
    private(set) var frameSessionID: UUID?
    @Published private(set) var preparedFrame: WatchBitmapRenderer.ScreenFrame?
    private let renderer = WatchArtworkRenderer()
    private var preparationID = UUID()

    func prepareSelection(_ seed: WatchSelectionPreview?, key: WatchBitmapRenderer.CacheKey,
                          viewport: WatchBitmapRenderer.SelectionViewport? = nil,
                          onReady: (UUID) -> Void = { _ in }) async {
        let token = UUID()
        preparationID = token
        // Keep the previous interactive texture until its committed frame arrives.
        // A new seed is published as soon as the finger is released, and clearing
        // here could discard that texture before the view has a chance to hold it.
        guard let seed else { return }
        // Textures of this session exist: a new view or zoom prepares them again only once
        // it settles (the textures shown meanwhile still fit, stretched or with the underlay).
        if preparedFrame?.selection?.sessionID == seed.sessionID {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        RenderDiagnostics.setSelectionPath("preparing")
        let next = await renderer.prepareSelectionFrame(seed, key: key, viewport: viewport)
        guard !Task.isCancelled, preparationID == token else { return }
        guard next?.selection != nil else {
            // No textures could be made: the drag replays the document instead.
            onReady(seed.sessionID)
            return
        }
        preparedFrame = next
        onReady(seed.sessionID)
        // Second stage, after the textures are on screen: the scene outside their area.
        guard let full = await renderer.prepareSelectionUnderlay(seed, key: key, viewport: viewport),
              !Task.isCancelled, preparationID == token, full.selection?.sessionID == seed.sessionID else { return }
        preparedFrame = full
        if frame?.selection?.sessionID == seed.sessionID { frame = full }
    }

    /// The last textures of a committed gesture and the document revision they show.
    private(set) var heldSelection: (frame: WatchBitmapRenderer.ScreenFrame, revision: UInt64)?

    func releaseHeldSelection() { heldSelection = nil }

    func holdPreparedSelection(sessionID: UUID, revision: UInt64) {
        // Invalidate outstanding preview jobs so they cannot overwrite the held
        // final transform while the committed document is being rendered.
        if latest?.selectionPreview?.sessionID == sessionID {
            latest = nil
            pending = nil
        }
        if let preparedFrame, preparedFrame.selection?.sessionID == sessionID {
            frame = preparedFrame
            frameSessionID = sessionID
            heldSelection = (preparedFrame, revision)
        }
    }

    private struct Job {
        let document: CanvasDocument?
        let selectedLayerID: UUID?
        let selectionPreview: WatchSelectionPreview?
        let selectionViewport: WatchBitmapRenderer.SelectionViewport?
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

    func submit(document: CanvasDocument?, selectedLayerID: UUID?, selectionPreview: WatchSelectionPreview?,
                selectionViewport: WatchBitmapRenderer.SelectionViewport? = nil, strokes: [Stroke], activeStroke: Stroke?,
                activeStrokeRevision: UInt64 = 0, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64, animatesClear: Bool = false, priority: TaskPriority? = nil) {
        // Direct submit already queued this live sample; drop the `.task(id:)` duplicate.
        if let activeStroke, selectionPreview == nil, let latest,
           latest.selectionPreview == nil, latest.key == key,
           latest.activeStrokeID == activeStrokeID, latest.activeStroke?.id == activeStroke.id,
           latest.activeStrokeRevision == activeStrokeRevision { return }
        if !animatesClear, clearTransition != nil { clearTransition = nil }
        if pending != nil { RenderDiagnostics.frameCoalesced() }
        let job = Job(document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview,
                      selectionViewport: selectionViewport, strokes: strokes, activeStroke: activeStroke, key: key, activeStrokeID: activeStrokeID, animatesClear: animatesClear,
                      activeStrokeRevision: activeStrokeRevision,
                      submittedAt: RenderDiagnostics.begin(),
                      eventAt: RenderDiagnostics.frameSubmitted(live: activeStroke != nil))
        pending = job
        latest = job
        guard worker == nil else { return }
        let token = generation
        worker = Task(priority: priority) { [weak self] in
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
        let result: WatchBitmapRenderer.ScreenFrame?
        if let preview = job.selectionPreview {
            RenderDiagnostics.setPath("lasso")
            result = await renderer.selectionFrame(preview, key: job.key, viewport: job.selectionViewport)
        } else if let document = job.document {
            RenderDiagnostics.setPath("layers")
            result = await renderer.layeredFrame(document: document, activeStroke: job.activeStroke,
                selectedLayerID: job.selectedLayerID, key: job.key)
        } else {
            RenderDiagnostics.setPath("1-layer")
            result = await renderer.screenFrame(strokes: job.strokes, activeStroke: job.activeStroke,
                                                key: job.key, activeStrokeID: job.activeStrokeID)
        }
        // Renderer finished → this main-actor continuation runs: the wait for the main thread.
        RenderDiagnostics.resumedOnMain()
        return result
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
            // Plain property, set before the published frame that re-evaluates the body.
            frameKey = job.key
            frameSessionID = job.selectionPreview?.sessionID
            self.frame = next
            // Assign only on change: every @Published write re-evaluates the raster body.
            let result = PreparedResult(key: job.key, succeeded: true)
            if self.preparedResult != result { self.preparedResult = result }
            RenderDiagnostics.framePublished(live: job.activeStroke != nil, submittedAt: job.submittedAt,
                                             eventAt: job.eventAt, tiles: next.tiles.count)
            if let texture = next.selection, let pending = self.pending,
               WatchBitmapRenderer.SelectionRenderCache.sameScene(pending.key, texture.key),
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

    /// The submitter this queue takes direct live frames from; see `registerLiveSubmitter`.
    var liveRegistration: LiveFrameSubmitter?

    func stop() {
        liveRegistration?.targets[ObjectIdentifier(self)] = nil
        liveRegistration = nil
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
