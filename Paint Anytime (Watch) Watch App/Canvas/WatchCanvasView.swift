//
//  WatchCanvasView.swift
//  Paint Anytime
//
//  Created by Denis Kolchev on 20.09.2026.
//

import SwiftUI
import WatchKit
import os

enum CanvasToolbarControl: Hashable {
    case custom(Int)
    case more, tools, clear, undo, redo, save, morph, contentMorph, canvasToolsMorph
    /// The reference thumbnail in the bottom-trailing corner.
    case reference
}

struct WatchCanvasView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    @ObservedObject var lasso = WatchLassoController()
    @ObservedObject var tutorial = TutorialSession.inactive
    var lassoToolbarInput: WatchLassoToolbarInput? = nil
    var onArtworkPrepared: (Bool) -> Void = { _ in }
    var rendersArtwork = true
    var acceptsInput = true
    var acceptsZoomOnlyInput = false
    var protectedControls: [CanvasToolbarControl: CGRect] = [:]
    // Resolve live menu bounds only at gesture start, without observing menu animation.
    var protectedControlsProvider: (() -> [CanvasToolbarControl: CGRect])? = nil
    @Binding var isMovingCanvas: Bool
    var isEyedropperActive = false
    var onSampleColor: (SIMD4<Float>) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @State private var fillWorker = WatchFillWorker()
    @State private var fillTask: Task<Void, Never>?
    @State private var fillRequestID: UUID?
    /// Tiles of the zoomed canvas at a resolution the whole paper could not afford; see
    /// `RegionTiling` and `tilePlan`. Tiles of `tileScale` and, until they are all ready
    /// over the view, those of `fallbackScale` (the previous resolution, shown below them).
    /// Ordered fallback first: later tiles draw above.
    @State private var tiles: [RegionTile] = []
    /// Tiles whose first frame is on screen.
    @State private var readyTiles: Set<RegionTile.ID> = []
    /// Tiles that became ready during the current stroke: hidden until lift, so a tile
    /// never shows a frame without the stroke over ink drawn in another raster.
    @State private var lateTiles: Set<RegionTile.ID> = []
    @State private var tileScale: CGFloat?
    /// The scale whose tiles over the view were all ready at once. Tiles of a new scale
    /// stay hidden until then and replace the previous resolution in one frame: shown one
    /// by one, each swap from a stretched old tile (or the paper) to a sharp one looked
    /// like the picture shifting under the zoom. Cells added by a pan at this scale show
    /// as soon as each is ready.
    @State private var completeScale: CGFloat?
    @State private var fallbackScale: CGFloat?
    /// Cells of `tileScale` over the view when the plan was applied.
    @State private var viewTileIDs: [RegionTile.ID] = []
    /// When the view's tiles were requested, for the time-to-ready log.
    @State private var tilesRequestedAt: UInt64?
    /// Per-layer reach of the strokes, for the tile memory budget.
    @State private var layerReach = LayerReachMemo()
    private static let regionLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PaintAnytime",
                                             category: "region")
    private struct TilePlan: Equatable {
        let scale: CGFloat
        /// Cells over the view, nearest to its centre first.
        let view: [RegionTile.ID]
        /// Cells of the margin around the view, rendered at background priority.
        let margin: [RegionTile.ID]
    }
    private struct TileRequest: Equatable {
        let plan: TilePlan?
        let isIdle: Bool
    }
    @State private var samplingImage: CGImage?
    /// Pixels per canvas point of `samplingImage`.
    @State private var samplingScale: CGFloat = 1
    @State private var samplerTask: Task<Void, Never>?
    /// The last requested sample point, applied once the sampler image is ready.
    @State private var sampleLocation: CGPoint?
    @State private var loupePoint: CGPoint?
    @State private var loupeImage: CGImage?
    var onCanvasInteraction: () -> Void = {}
    /// A short tap that landed on the canvas inside a protected control's zone. With the
    /// native bars hidden, taps on a drawn control sometimes reach the canvas under it
    /// instead of the control; the screen forwards them to that control.
    var onProtectedTap: (CanvasToolbarControl) -> Void = { _ in }
    /// Receives the zoom on every Crown change, for the status overlay.
    var zoomReadout: CanvasZoomReadout? = nil
    /// The protected control the current gesture started on.
    @State private var protectedStartControl: CanvasToolbarControl?
    @State private var crownZoom = 1.0
    /// The canvas viewport, for the Crown's zoom limit (the Crown modifier sits outside
    /// the GeometryReader).
    @State private var viewportSize = CGSize.zero
    @AppStorage(CanvasPixelView.storageKey) private var pixelMode = CanvasPixelView.Mode.smooth
    /// The tutorial's canvases keep the regular rendering. Auto follows the settled zoom
    /// (`zoom`, with the 100% snap), so it switches once per Crown detent at most.
    private var pixelGridScale: CGFloat? {
        guard !tutorial.isActive, viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let screenScale = displayScale * canvasFit(viewportSize) * CGFloat(zoom)
        return CanvasPixelView.activeGridScale(pixelMode, displayScale: displayScale, screenScale: screenScale)
    }
    @State private var offset = CGSize.zero
    @State private var panOrigin: CGSize?
    @State private var acceptsCurrentGesture: Bool?
    @State private var lassoGestureStartBounds: CGRect?
    @State private var blockedEraserLayerID: UUID?
    @GestureState private var isDragging = false
    @State private var shapeHoldTask: Task<Void, Never>?
    @State private var shapeHoldAnchor: CGPoint?
    @State private var failedCircleImage: CGImage?
    @State private var failedCircleOpacity = 1.0
    @State private var failedCircleKind: ShapeRecognizer.Kind?
    @ObservedObject var guides = PerspectiveGuides.shared
    @ObservedObject var renderDebug = RenderDebugSettings.shared
    /// Queues live frames straight from the touch handler (Direct submit).
    @State private var liveSubmitter = LiveFrameSubmitter()
    @State private var guideDrag: GuideDrag?
    // A stroke that starts on a guide waits for its direction before choosing a ruler.
    @State private var isRulerPending = false
    @Environment(\.scenePhase) private var scenePhase

    private enum GuideDrag {
        case rotate(startAngle: CGFloat, startRotation: Double, snappedQuarter: Int?)
        case move(startCenter: CGPoint, isCentered: Bool)
        /// One of two vanishing points; the other stays fixed and the horizon passes through both.
        case vanishingPoint(index: Int, fixed: CGPoint, startPoint: CGPoint, snappedQuarter: Int?)
    }

    private var showsGuides: Bool {
        guides.isEnabled && rendersArtwork && !lasso.isActive && tutorial.showsPerspectiveGuides
    }

    private var needsLayerRendering: Bool {
        controller.document.layers.count != 1 || controller.document.effectiveBackgroundColor != SIMD4(1, 1, 1, 1)
        || !controller.selectedLayer.isVisible || controller.selectedLayer.opacity != 1
        || controller.selectedLayer.locksTransparency || controller.containsTransparencyLockedStrokes
    }

    /// The ink tip draws above all layers; allow it only when nothing would cover,
    /// fade or clip the live stroke in the real frame.
    private var allowsInkTip: Bool {
        let layer = controller.selectedLayer
        return !lasso.isActive && layer.isVisible && layer.opacity >= 1 && !layer.locksTransparency
            && controller.document.layers.last(where: { $0.isVisible && $0.opacity > 0 })?.id == layer.id
    }

    private var zoom: Double { abs(crownZoom - 1) <= 0.075 ? 1 : crownZoom }

    /// Up to 12800%, stopping once one canvas point fills `maximumPointZoom` screen points
    /// (one saved pixel 32 points on a 2× display): a screen-sized canvas reaches 6400%,
    /// a 1024 pt one 12800%. Never below `minimumMaximumZoom`. Rounded down to a Crown
    /// stop (`CanvasZoomStops`), so the limit is a round percent too.
    static let maximumZoomLimit = 128.0
    static let maximumPointZoom = 64.0
    static let minimumMaximumZoom = 32.0

    private var maximumZoomIndex: Int {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return CanvasZoomStops.lastIndex(atMost: 8) }
        let fit = Double(canvasFit(viewportSize))
        guard fit.isFinite, fit > 0 else { return CanvasZoomStops.lastIndex(atMost: 8) }
        let limit = min(Self.maximumZoomLimit, max(Self.minimumMaximumZoom, Self.maximumPointZoom / fit))
        return CanvasZoomStops.lastIndex(atMost: limit)
    }
    private var maximumZoom: Double { CanvasZoomStops.all[maximumZoomIndex] }
    @FocusState private var crownFocused: Bool
    /// watchOS flashes the Crown indicator when the canvas takes Crown focus, for example
    /// as it appears after the welcome flow. The system can focus the canvas itself in the
    /// same update that makes it focusable, before any task runs, so the indicator is
    /// derived: hidden for every new focus request until this request has settled.
    @State private var crownIndicatorRequest: CrownFocusRequest?
    private var hidesCrownIndicator: Bool {
        crownIndicatorRequest != CrownFocusRequest(enabled: shouldFocusCrown, step: tutorial.step)
    }
    private var shouldFocusCrown: Bool {
        scenePhase == .active && (acceptsInput || acceptsZoomOnlyInput) && tutorial.allowsCanvasZoom
    }
    private struct CrownFocusRequest: Equatable {
        let enabled: Bool
        let step: TutorialStep
    }

    var body: some View {
        let _ = TutorialDebug.trace("canvas.body", "input=\(acceptsInput) controls=\(protectedControls.count) \(tutorial.debugState)")
        let _ = RenderDiagnostics.bodyEvaluated(.canvas)
        GeometryReader { geometry in
            let paperSize = controller.document.size(fallback: geometry.size)
            let fit = canvasFit(geometry.size)
            let useLayers = lasso.isActive || needsLayerRendering
            Color(white: 0.16)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    // Hiding settings/gallery must not destroy the raster view's image and cache.
                    // Keep its identity so returning to the canvas displays the last frame immediately.
                    // Live samples re-evaluate only this observer, not the canvas or its menus.
                    LiveStrokeObserver(changes: controller.liveStroke) {
                        let displayedDocument = controller.document
                        // Evaluated per live sample too. Shown tiles stay on screen and draw the
                        // live stroke where it reaches them, at their resolution. The paper
                        // below draws it too unless shown tiles of the current scale cover the
                        // view (cheap: the paper is at screen resolution).
                        let visibleRect = visibleCanvasRect(geometry.size)
                        // Padded by a few screen points, so a tile starts drawing the stroke
                        // before it arrives there.
                        let strokePad = 16 / max(0.01, CGFloat(zoom) * fit)
                        let strokeReach = controller.activeStroke.map {
                            WatchBitmapRenderer.reach(of: $0).insetBy(dx: -strokePad, dy: -strokePad)
                        } ?? .null
                        let shownTiles = lasso.isActive ? [] : tiles.filter {
                            readyTiles.contains($0.id) && !lateTiles.contains($0.id)
                                && ($0.id.scale != tileScale || completeScale == tileScale)
                        }
                        let shownIDs = Set(shownTiles.map(\.id))
                        let liveIDs = Set(shownTiles.filter {
                            $0.rect.intersects(strokeReach) && $0.rect.intersects(visibleRect)
                        }.map(\.id))
                        let tilesCoverView = tileScale.map { scale in
                            RegionTiling.cells(covering: visibleRect, scale: scale, paper: paperSize, nearest: .zero)
                                .allSatisfy { shownIDs.contains($0) }
                        } == true
                        let paperIsLive = !tilesCoverView
                        // The ink tip draws above its own raster only: the paper's while it is live,
                        // else the tile under the newest sample.
                        let tipTile: RegionTile.ID? = paperIsLive ? nil : controller.activeStroke?.points.last.flatMap { last in
                            let p = CGPoint(x: CGFloat(last.position.x), y: CGFloat(last.position.y))
                                .applying(controller.activeStroke?.transform.affine ?? .identity)
                            return shownTiles.last { liveIDs.contains($0.id) && $0.rect.contains(p) }?.id
                        }
                        ZStack(alignment: .topLeading) {
                            // Screen resolution of the whole paper: the region above sharpens the
                            // zoomed view within the memory budget. Lasso hides regions (selection
                            // textures span the paper), so then zoom raises the paper raster up to
                            // what every layer's ink fits in `LayerCache.inkByteLimit`.
                            WatchRasterArtwork(document: useLayers ? displayedDocument : nil,
                                selectedLayerID: controller.selectedLayer.id, selectionPreview: lasso.previewState, selectionSeed: lasso.selectionSeed,
                                strokes: useLayers ? [] : (displayedDocument.layers.first?.strokes ?? []),
                                activeStroke: paperIsLive ? controller.activeStroke : nil, documentID: ObjectIdentifier(controller),
                                documentRevision: controller.documentRevision,
                                clearDocumentRevision: controller.clearDocumentRevision,
                                activeStrokeRevision: paperIsLive ? controller.activeStrokeRevision : 0,
                                activeStrokeID: controller.activeStrokeID, onFramePrepared: onArtworkPrepared, zoom: lasso.isActive ? zoom : 1,
                                fit: fit, liveSubmitter: paperIsLive ? liveSubmitter : nil,
                                allowsInkTip: paperIsLive && allowsInkTip, pixelGridScale: pixelGridScale)
                            if !lasso.isActive {
                                ForEach(tiles) { tile in
                                    let live = liveIDs.contains(tile.id)
                                    WatchRasterArtwork(document: displayedDocument,
                                        selectedLayerID: controller.selectedLayer.id,
                                        strokes: [], activeStroke: live ? controller.activeStroke : nil,
                                        documentID: ObjectIdentifier(controller),
                                        documentRevision: controller.documentRevision,
                                        activeStrokeRevision: live ? controller.activeStrokeRevision : 0,
                                        activeStrokeID: controller.activeStrokeID,
                                        onFramePrepared: { succeeded in
                                            guard succeeded, tiles.contains(where: { $0.id == tile.id }) else { return }
                                            tileBecameReady(tile.id)
                                        },
                                        zoom: zoom, fit: fit, liveSubmitter: live ? liveSubmitter : nil,
                                        allowsInkTip: live && tile.id == tipTile && allowsInkTip, region: tile.region,
                                        rendersInBackground: !tile.rect.intersects(visibleRect),
                                        pixelGridScale: pixelGridScale)
                                        .opacity(shownIDs.contains(tile.id) ? 1 : 0)
                                }
                            }
                        }
                    }
                        .frame(width: paperSize.width, height: paperSize.height)
                        .overlay {
                            if let failedCircleImage {
                                Image(decorative: failedCircleImage, scale: displayScale)
                                    .resizable()
                                    .opacity(failedCircleOpacity)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .task {
                                        do {
                                            // Let the initial opaque frame appear before starting the fade.
                                            try await Task.sleep(for: .milliseconds(20))
                                            withAnimation(.easeOut(duration: 0.22)) { failedCircleOpacity = 0 }
                                            try await Task.sleep(for: .milliseconds(220))
                                            self.failedCircleImage = nil
                                            tutorial.isFadingCircleAttempt = false
                                            tutorial.finishedCircleAttempt(kind: failedCircleKind)
                                        } catch {
                                            self.failedCircleImage = nil
                                            tutorial.isFadingCircleAttempt = false
                                        }
                                    }
                            }
                        }
                        .background {
                            if controller.document.effectiveBackgroundColor.w < 1 {
                                TransparencyCheckerboard()
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .clipped()
                        .overlay { Rectangle().strokeBorder(.gray.opacity(0.6), lineWidth: zoom < 1 ? 1 : 0) }
                        .scaleEffect(zoom * fit)
                        // Constrain layout after scaling: the paper must not resize the viewport.
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(offset)
                        .opacity(rendersArtwork ? 1 : 0)
                }
            .clipped()
            .overlay {
                ZStack {
                    if showsGuides {
                        PerspectiveGuidesOverlay(layout: guides.layout(paperSize: paperSize),
                            canvasToScreen: canvasToScreen(geometry.size), activeRuler: guides.activeRuler,
                            showsHandles: acceptsInput && !isMovingCanvas && !isEyedropperActive
                                && controller.activeStroke == nil && !isRulerPending)
                            .clipped()
                            .transition(.opacity)
                    }
                }
                // The tour's guides fade out once their lesson ends, after the stroke along them.
                // Only that change animates; the editor shows and hides them as before.
                .animation(.easeInOut(duration: 0.6), value: tutorial.showsPerspectiveGuides)
            }
            .overlay {
                if lasso.isActive {
                    WatchLassoOverlay(lasso: lasso, canvasToScreen: canvasToScreen(geometry.size))
                }
            }
            .overlay {
                LiveStrokeObserver(changes: controller.liveStroke) {
                if rendersArtwork, acceptsInput, isDragging, acceptsCurrentGesture == true,
                   !isMovingCanvas, !isEyedropperActive, !lasso.isActive,
                   let stroke = controller.activeStroke,
                   (stroke.style.instrument == .eraser || stroke.style.instrument == .blur),
                   let point = stroke.points.last?.position {
                    // Match the actual erasing radius and follow the paper's
                    // zoom and pan, keeping the outline itself 1.5 screen points.
                    let scale = zoom * fit
                    let diameter = CGFloat(stroke.style.width) * scale
                    let center = CGPoint(
                        x: (CGFloat(point.x) - paperSize.width / 2) * scale
                            + geometry.size.width / 2 + offset.width,
                        y: (CGFloat(point.y) - paperSize.height / 2) * scale
                            + geometry.size.height / 2 + offset.height)
                    Canvas { context, _ in
                        let ring = Path(ellipseIn: CGRect(
                            x: center.x - diameter / 2, y: center.y - diameter / 2,
                            width: diameter, height: diameter))
                        context.stroke(ring, with: .color(.black.opacity(0.65)), lineWidth: 1.5)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                }
            }
            .overlay {
                if isEyedropperActive, let loupeImage, let loupePoint {
                    Image(decorative: loupeImage, scale: 1)
                        .resizable().interpolation(.none)
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 0)
                        .overlay {
                            Rectangle().stroke(.black, lineWidth: 3).frame(width: 8, height: 8)
                                .overlay { Rectangle().stroke(.white, lineWidth: 1).frame(width: 8, height: 8) }
                        }
                        .position(loupePoint)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if fillRequestID != nil { ProgressView().allowsHitTesting(false) }
            }
            .overlay(alignment: renderDebug.hudPosition.alignment) {
                if RenderDebug.isEnabled, renderDebug.showsHUD, rendersArtwork {
                    RenderDebugOverlay()
                        .padding(renderDebug.hudPosition.insets)
                }
            }
            .overlay {
                if rendersArtwork && acceptsInput {
                    WatchLassoModeNotice(lasso: lasso)
                    SketchAssistNotice()
                }
            }
            .onChange(of: isEyedropperActive) { _, active in
                if active { prepareSampler(size: geometry.size) }
                else {
                    samplerTask?.cancel()
                    samplerTask = nil
                    samplingImage = nil
                    loupeImage = nil
                    sampleLocation = nil
                }
            }
            .onAppear { if isEyedropperActive { prepareSampler(size: geometry.size) } }
            .task(id: TileRequest(plan: tilePlan(size: geometry.size, paper: paperSize, fit: fit),
                                  isIdle: controller.activeStroke == nil)) {
                // A stroke keeps the tiles it draws in; tiles still rendering go on, new
                // ones are requested after lift.
                guard controller.activeStroke == nil else { return }
                guard let plan = tilePlan(size: geometry.size, paper: paperSize, fit: fit) else {
                    tiles = []
                    readyTiles = []
                    tileScale = nil
                    completeScale = nil
                    fallbackScale = nil
                    viewTileIDs = []
                    return
                }
                let existing = Set(tiles.map(\.id))
                guard plan.scale != tileScale || (plan.view + plan.margin).contains(where: { !existing.contains($0) })
                else { return }
                // Render new tiles only once zoom and pan have settled. 150 ms: an abandoned
                // tile stops at its next stroke (`renderInk` checks cancellation).
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard controller.activeStroke == nil else { return }
                applyTilePlan(plan, paper: paperSize, visible: visibleCanvasRect(geometry.size))
            }
            .onChange(of: controller.activeStroke == nil) { _, idle in
                if idle {
                    lateTiles = []
                    dropCoveredFallback()
                }
            }
            .onChange(of: geometry.size) { _, size in
                if isEyedropperActive { prepareSampler(size: size) }
            }
            .onChange(of: geometry.size, initial: true) { _, size in viewportSize = size }
            .onChange(of: controller.documentRevision) { _, _ in
                if isEyedropperActive { prepareSampler(size: geometry.size) }
            }
            .onChange(of: crownZoom) { _, _ in
                if isEyedropperActive { updateSample(at: loupePoint ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2), size: geometry.size) }
            }
            .onChange(of: WatchLassoToolbarInput.Mapping(
                frame: geometry.frame(in: .global), paperSize: paperSize, offset: offset,
                zoomScale: zoom * fit, rasterScale: min(4, max(1, displayScale)),
                enabled: acceptsInput && tutorial.acceptsActions && (lasso.isActive ? tutorial.allowsLassoInput : tutorial.allowsDrawing)
                    && !tutorial.isFadingCircleAttempt && scenePhase == .active), initial: true) { _, mapping in
                lassoToolbarInput?.mapping = mapping
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        // Speed HUD: touch event age, then handler, stroke geometry, object erasing.
                        let inputStarted = RenderDiagnostics.inputBegan(eventTime: value.time)
                        defer { RenderDiagnostics.end(.input, inputStarted) }
                        guard fillRequestID == nil, acceptsInput && tutorial.acceptsActions && !tutorial.isFadingCircleAttempt && blockedEraserLayerID == nil else {
                            return
                        }
                        guard (lasso.isActive ? tutorial.allowsLassoInput : isMovingCanvas ? tutorial.allowsCanvasPan : tutorial.allowsDrawing) else {
                            return
                        }
                        tutorial.activity()
                        if acceptsCurrentGesture == nil {
                            let protected = protectedControl(at: value.startLocation,
                                canvasFrame: geometry.frame(in: .global))
                            acceptsCurrentGesture = protected == nil
                            protectedStartControl = protected
                            if acceptsCurrentGesture == true {
                                onCanvasInteraction()
                                if lasso.isActive {
                                    lassoGestureStartBounds = lasso.bounds
                                    lasso.begin(at: canvasPoint(value.startLocation, size: geometry.size),
                                        tolerance: WatchLassoGeometry.handleHitRadius / (zoom * fit),
                                        visibleRect: CGRect(origin: .zero, size: geometry.size)
                                            .applying(canvasToScreen(geometry.size).inverted()),
                                        controller: controller)
                                } else if showsGuides, !isMovingCanvas, !isEyedropperActive {
                                    guideDrag = guideDragStart(at: value.startLocation, size: geometry.size)
                                }
                            }
                        }
                        // Keep the initial decision even when controls hide or the finger moves away.
                        guard acceptsCurrentGesture == true else { return }
                        if lasso.isActive {
                            cancelShapeHold()
                            lasso.update(at: canvasPoint(value.location, size: geometry.size), pointSpacing: 1 / (zoom * fit))
                            return
                        }
                        if isMovingCanvas && isEyedropperActive {
                            updateSample(at: value.location, size: geometry.size)
                            return
                        }
                        if isMovingCanvas {
                            cancelShapeHold()
                            if panOrigin == nil { panOrigin = offset }
                            let origin = panOrigin ?? offset
                            let proposed = CGSize(width: origin.width + value.translation.width,
                                                  height: origin.height + value.translation.height)
                            let wasCentered = offset == .zero
                            // Use screen points so the magnet feels the same at every zoom.
                            // A wider release radius prevents repeated clicks near the boundary.
                            let radius: CGFloat = wasCentered ? 12 : 8
                            let isCentered = hypot(proposed.width, proposed.height) <= radius
                            let nextOffset: CGSize = isCentered ? .zero : proposed
                            if nextOffset != offset { tutorial.record(.panned) }
                            offset = nextOffset
                            if isCentered && !wasCentered {
                                WKInterfaceDevice.current().play(.click)
                            }
                            return
                        }
                        if let guideDrag {
                            cancelShapeHold()
                            updateGuideDrag(guideDrag, from: value.startLocation, to: value.location, size: geometry.size)
                            return
                        }
                        guard controller.pencilStyle.instrument != .fill else { return }
                        if controller.pencilStyle.instrument == .eraser,
                           controller.selectedLayer.isVisible,
                           controller.selectedLayer.locksTransparency {
                            // Reject the whole gesture; unlocking requires a fresh touch to erase.
                            acceptsCurrentGesture = false
                            cancelShapeHold()
                            blockedEraserLayerID = controller.selectedLayer.id
                            return
                        }
                        let start = canvasPoint(value.startLocation, size: geometry.size)
                        // Preserve off-canvas samples so a stroke can enter the paper naturally.
                        // The artwork view and exported bitmap clip ink to the canvas bounds.
                        if controller.activeStroke == nil {
                            let scale = zoom * fit
                            let tolerance = Self.rulerTolerance / scale
                            // With guides on every stroke follows one: a start between guides
                            // snaps to the nearest, so nothing can be drawn off them.
                            if !isRulerPending, guides.activeRuler == nil, showsGuides {
                                isRulerPending = true
                            }
                            if isRulerPending {
                                // Choose the ruler from the initial direction, measured on screen.
                                guard hypot(value.location.x - value.startLocation.x,
                                            value.location.y - value.startLocation.y) >= Self.rulerDecisionDistance
                                else { return }
                                isRulerPending = false
                                guides.activeRuler = guides.layout(paperSize: paperSize).ruler(from: start,
                                    toward: canvasPoint(value.location, size: geometry.size), tolerance: tolerance)
                            }
                            controller.beginStroke(at: sample(at: ruled(start), time: value.time))
                        }
                        controller.continueStroke(at: sample(
                            at: ruled(canvasPoint(value.location, size: geometry.size)), time: value.time))
                        RenderDiagnostics.sampleApplied()
                        liveSubmitter.submitLive(controller.activeStroke, revision: controller.activeStrokeRevision,
                                                 strokeID: controller.activeStrokeID)
                        // A ruled line is already exact; shape recognition would only distort it.
                        if guides.activeRuler == nil { scheduleShapeHold(at: value.location) }
                    }
                    .onEnded { value in
                        cancelShapeHold()
                        if acceptsCurrentGesture == false, let control = protectedStartControl,
                           hypot(value.translation.width, value.translation.height) < Self.protectedTapSlop {
                            // A tap, not a stroke: it belongs to the control it started on.
                            onProtectedTap(control)
                        }
                        defer { acceptsCurrentGesture = nil; protectedStartControl = nil; panOrigin = nil; lassoGestureStartBounds = nil; endGuideInteraction() }
                        guard acceptsInput && acceptsCurrentGesture == true else { return }
                        if guideDrag != nil { return }
                        if lasso.isActive {
                            let previousRevision = controller.documentRevision
                            lasso.end(at: canvasPoint(value.location, size: geometry.size), controller: controller,
                                size: paperSize, scale: min(4, max(1, displayScale))) { selected in
                                    tutorial.record(selected ? .selectedLasso : .failedLassoSelection)
                                }
                            if controller.documentRevision != previousRevision,
                               lassoGestureStartBounds != nil, lasso.bounds != lassoGestureStartBounds {
                                tutorial.record(.transformedLasso)
                            }
                            return
                        }
                        if isMovingCanvas {
                            panOrigin = nil
                            return
                        }
                        if controller.pencilStyle.instrument == .fill {
                            let point = canvasPoint(value.startLocation, size: geometry.size)
                            startFill(at: point, size: controller.document.size(fallback: geometry.size))
                            return
                        }
                        if isRulerPending && controller.activeStroke == nil {
                            // A tap leaves a dot on the nearest guide.
                            let tap = canvasPoint(value.startLocation, size: geometry.size)
                            controller.beginStroke(at: sample(
                                at: guides.layout(paperSize: paperSize).snappedPoint(tap), time: value.time))
                        }
                        guard controller.activeStroke != nil else { return }
                        let recognizedKind = controller.recognizedShapeKind
                        if tutorial.isActive, tutorial.step == .holdCircle, tutorial.acceptsActions,
                           recognizedKind != .circle, recognizedKind != .ellipse {
                            controller.continueStroke(at: sample(
                                at: ruled(canvasPoint(value.location, size: geometry.size)), time: value.time))
                            if let stroke = controller.activeStroke,
                               let image = WatchBitmapRenderer.layerThumbnail(strokes: [stroke], size: paperSize,
                                   scale: WatchBitmapRenderer.rasterScale(displayScale: displayScale, zoom: zoom)) {
                                failedCircleKind = recognizedKind
                                failedCircleOpacity = 1
                                failedCircleImage = image
                                tutorial.isFadingCircleAttempt = true
                                // Failed practice strokes never enter the artwork or undo history.
                                controller.cancelStroke()
                                return
                            }
                        }
                        let previousCount = controller.document.strokes.count
                        // Read before the gesture's cleanup clears the ruler.
                        let followedGuide = guides.activeRuler != nil
                        if controller.isShapeSnapped { RenderDiagnostics.shapeLifted() }
                        controller.endStroke(at: sample(
                            at: ruled(canvasPoint(value.location, size: geometry.size)), time: value.time))
                        if controller.document.strokes.count > previousCount {
                            tutorial.finishedCircleAttempt(kind: recognizedKind)
                            // Before .stroke, which counts a miss in the guide lesson.
                            if followedGuide { tutorial.record(.drewAlongGuide) }
                            if controller.pencilStyle.instrument == .eraser { tutorial.record(.erased) }
                            tutorial.record(.stroke)
                            tutorial.finishedStroke(in: controller.selectedLayer)
                        }
                    },
                including: acceptsInput && tutorial.acceptsActions && !tutorial.isFadingCircleAttempt ? .all : .none
            )
        }
        .ignoresSafeArea()
        .alert(L10n.text("Layer is locked"), isPresented: Binding(
            get: { blockedEraserLayerID != nil },
            set: { if !$0 { blockedEraserLayerID = nil } }
        ), presenting: blockedEraserLayerID) { layerID in
            Button(L10n.text("Unlock")) {
                controller.updateLayer(layerID) { $0.locksTransparency = false }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        // Keep the Crown target registered throughout the canvas exercise. The
        // binding below still rejects zoom until the lesson permits it.
        .focusable(acceptsInput || acceptsZoomOnlyInput)
        .focused($crownFocused)
        .digitalCrownRotation(detent: Binding(
            // The Crown turns through stop indices; each detent is one round percent.
            get: { Double(CanvasZoomStops.index(nearest: crownZoom)) },
            set: { position in
                guard tutorial.allowsCanvasZoom else { return }
                guard (acceptsInput || acceptsZoomOnlyInput) && !isDragging && controller.activeStroke == nil else { return }
                let index = min(maximumZoomIndex, max(0, Int(position.rounded())))
                let value = CanvasZoomStops.all[index]
                guard abs(value - crownZoom) > 0.000_1 else { return }
                let previousZoom = zoom
                let wasSnapped = previousZoom == 1
                if !lasso.isActive { isMovingCanvas = true }
                crownZoom = value
                zoomReadout?.show(zoom)
                // Keep the canvas point at the viewport center fixed, including
                // when entering or leaving the 100% zoom snap range.
                let ratio = zoom / previousZoom
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
                tutorial.changedZoom()
                if zoom == 1 && !wasSnapped { WKInterfaceDevice.current().play(.click) }
            }
        ), from: 0, through: Double(maximumZoomIndex), by: 1, sensitivity: .low,
           isContinuous: false, isHapticFeedbackEnabled: false,
           onChange: { [step = tutorial.step] event in
                tutorial.usedCrown(in: step, velocity: event.velocity)
            })
        .digitalCrownAccessory(hidesCrownIndicator ? .hidden : .automatic)
        .accessibilityLabel(lasso.isActive ? L10n.text(lasso.mode.title) : isMovingCanvas ? L10n.text("Moving canvas") : L10n.text("Finger drawing canvas"))
        .accessibilityValue(L10n.format("Zoom %d percent", Int((zoom * 100).rounded())))
        .task(id: CrownFocusRequest(enabled: shouldFocusCrown, step: tutorial.step)) {
            crownFocused = false
            guard shouldFocusCrown else { return }
            // Zoom -> pan keeps zoom enabled, but replaces the lesson UI.
            // Reacquire focus after that transition too, not just false -> true.
            // watchOS 10 can discard focus requested in the same update that
            // enables a target. Wait for it to be installed in the focus tree.
            // Cancellation prevents a hidden canvas stealing focus from tools.
            let request = CrownFocusRequest(enabled: shouldFocusCrown, step: tutorial.step)
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                crownFocused = true
                // Long enough for the focus flash; turning in the meantime still zooms.
                try await Task.sleep(for: .milliseconds(800))
                try Task.checkCancellation()
                crownIndicatorRequest = request
            } catch {}
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging {
                // After a normal onEnded the touch is already closed and this does nothing.
                cancelShapeHold()
                // A normal onEnded already commits and clears the stroke.
                // A cancelled gesture has no onEnded and must not remain live. watchOS cancels
                // strokes started at the screen edge once its edge gesture takes over: keep
                // what was drawn up to its last sample. The tutorial grades its own strokes.
                if let last = controller.activeStroke?.points.last, !tutorial.isActive {
                    controller.endStroke(at: last)
                } else if controller.activeStroke != nil {
                    controller.cancelStroke()
                }
                lasso.cancelGesture()
                panOrigin = nil
                acceptsCurrentGesture = nil
                protectedStartControl = nil
                endGuideInteraction()
            }
        }
        .onChange(of: isMovingCanvas) { _, moving in
            cancelShapeHold()
            if moving { controller.cancelStroke() }
            panOrigin = nil
            if !moving && zoom == 1 { crownZoom = 1 }
        }
        // A resized canvas or viewport can lower the limit below the current zoom.
        .onChange(of: maximumZoom) { _, limit in
            guard crownZoom > limit else { return }
            let ratio = limit / zoom
            crownZoom = limit
            offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
        }
        .onChange(of: acceptsInput) { _, enabled in
            TutorialDebug.trace("canvas.enabled.enter", "value=\(enabled)")
            defer { TutorialDebug.trace("canvas.enabled.exit", "focused=\(crownFocused)") }
            if !enabled { cancelFill(); cancelShapeHold(); controller.cancelStroke(); lasso.cancelGesture() }
        }
        .onChange(of: controller.documentRevision) { _, _ in cancelFill(); lasso.documentChanged(controller) }
        .onChange(of: controller.selectedLayerID) { _, _ in cancelFill(); lasso.documentChanged(controller) }
        .alert(L10n.text("Could not create selection"), isPresented: Binding(
            get: { lasso.errorMessage != nil }, set: { if !$0 { lasso.errorMessage = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { lasso.errorMessage = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelFill(); cancelShapeHold(); controller.cancelStroke(); lasso.cancelGesture() }
        }
        .onDisappear {
            cancelFill()
            cancelShapeHold()
            controller.cancelStroke()
            lasso.deactivate()
        }
    }

    private func cancelFill() {
        fillTask?.cancel()
        fillTask = nil
        fillRequestID = nil
    }

    private func startFill(at point: CGPoint, size: CGSize) {
        guard fillRequestID == nil, controller.selectedLayer.isVisible else { return }
        let layer = controller.selectedLayer
        let revision = controller.documentRevision
        let style = controller.pencilStyle
        let requestID = UUID()
        fillRequestID = requestID
        fillTask = Task { @MainActor in
            let result = await fillWorker.fill(layer: layer, size: size, point: point, style: style)
            guard fillRequestID == requestID else { return }
            fillTask = nil
            fillRequestID = nil
            guard !Task.isCancelled, controller.documentRevision == revision,
                  controller.selectedLayer.id == layer.id, let result else { return }
            controller.commitFill(result)
            tutorial.record(.filled)
        }
    }

    /// Renders the flattened document for the eyedropper in the background, so opening
    /// it never freezes the canvas. A full replay of a large drawing takes the same
    /// work as a save. The resolution is what the screen shows at the current zoom,
    /// capped at the display scale as before: a 1024 pt canvas fitted to the screen
    /// needs ~0.5 px per point, not 2 (16 MiB of output and 48–64 MiB float layers).
    private func prepareSampler(size: CGSize) {
        controller.cancelStroke()
        samplerTask?.cancel()
        let document = controller.document
        let paper = document.size(fallback: size)
        let shown = displayScale * canvasFit(size) * CGFloat(max(1, zoom))
        let scale = min(displayScale, max(0.25, (shown * 4).rounded(.up) / 4))
        let revision = controller.documentRevision
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        samplerTask = Task { @MainActor in
            let work = Task.detached(priority: .userInitiated) {
                WatchBitmapRenderer.render(document: document, size: paper, scale: scale)
            }
            let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, controller.documentRevision == revision, let image else { return }
            samplingImage = image
            samplingScale = scale
            samplerTask = nil
            updateSample(at: sampleLocation ?? center, size: size)
        }
    }

    private func updateSample(at location: CGPoint, size: CGSize) {
        sampleLocation = location
        guard let image = samplingImage else { return }
        let scale = samplingScale
        let point = canvasPoint(location, size: size)
        let x = min(image.width - 1, max(0, Int(floor(point.x * scale))))
        let y = min(image.height - 1, max(0, Int(floor(point.y * scale))))
        // Place the lens over the actual pixel, including when dragging beyond the paper.
        let paper = controller.document.size(fallback: size)
        let fit = canvasFit(size)
        loupePoint = CGPoint(x: ((CGFloat(x) + 0.5) / scale - paper.width / 2) * zoom * fit + size.width / 2 + offset.width,
                             y: ((CGFloat(y) + 0.5) / scale - paper.height / 2) * zoom * fit + size.height / 2 + offset.height)
        guard let pixel = image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)) else { return }
        var rgba = [UInt8](repeating: 0, count: 4)
        let sampled = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        if sampled { onSampleColor(SIMD4(Float(rgba[0]) / 255, Float(rgba[1]) / 255, Float(rgba[2]) / 255, 1)) }
        // A fixed 11 × 11 crop keeps the selected pixel exactly in the lens center.
        if let context = CGContext(data: nil, width: 11, height: 11, bitsPerComponent: 8,
            bytesPerRow: 44, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(gray: 0.16, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 11, height: 11))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: CGFloat(5 - x), y: CGFloat(5 - (image.height - 1 - y)), width: CGFloat(image.width), height: CGFloat(image.height)))
            loupeImage = context.makeImage()
        }
    }

    private func cancelShapeHold() {
        shapeHoldTask?.cancel()
        shapeHoldTask = nil
        shapeHoldAnchor = nil
    }

    private func scheduleShapeHold(at location: CGPoint) {
        guard let stroke = controller.activeStroke, stroke.style.instrument != .eraser,
              !controller.isShapeSnapped else { cancelShapeHold(); return }
        // Measure jitter on screen, keeping hold sensitivity stable under zoom.
        if let anchor = shapeHoldAnchor, hypot(location.x - anchor.x, location.y - anchor.y) < 2 { return }
        shapeHoldTask?.cancel()
        shapeHoldAnchor = location
        let gestureID = stroke.id
        let tolerance = Float(2 / zoom)
        let scheduledAt = RenderDiagnostics.begin()
        shapeHoldTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                guard controller.activeStroke?.id == gestureID, !isMovingCanvas,
                      tutorial.acceptsActions, tutorial.allowsDrawing else { return }
                let recognizeStarted = RenderDiagnostics.begin()
                let snapped = controller.recognizeActiveShape(adjustmentTolerance: tolerance)
                RenderDiagnostics.shapeRecognized(recognizeStarted, scheduledAt: scheduledAt,
                    kind: snapped ? controller.recognizedShapeKind.map { "\($0)" } : nil,
                    points: controller.activeStroke?.points.count ?? 0)
                if snapped {
                    WKInterfaceDevice.current().play(.click)
                    tutorial.finishedCircleAttempt(kind: controller.recognizedShapeKind, isStrokeComplete: false)
                }
            } catch { }
        }
    }

    private func protectedControl(at point: CGPoint, canvasFrame: CGRect) -> CanvasToolbarControl? {
        let screenPoint = CGPoint(x: canvasFrame.minX + point.x, y: canvasFrame.minY + point.y)
        for (control, frame) in protectedControlsProvider?() ?? protectedControls {
            guard !frame.isNull && !frame.isEmpty else { continue }
            // Only the button itself blocks drawing, so tapping it never leaves a dot.
            // There is no extra no-draw zone around it: the canvas is drawable up to it.
            switch control {
            case .morph, .contentMorph, .canvasToolsMorph, .custom:
                // A collapsed (square) control is a round button: protect only its circle,
                // as its hit shape does. Expanded panels tile their rows as rectangles.
                if abs(frame.width - frame.height) < 1 {
                    if hypot(screenPoint.x - frame.midX, screenPoint.y - frame.midY) <= frame.width / 2 { return control }
                } else if frame.contains(screenPoint) { return control }
            case .reference:
                if frame.contains(screenPoint) { return control }
            case .more, .tools, .clear, .save, .undo, .redo:
                // The toolbar reports only the icon bounds; test the round 44 pt button.
                let radius = max(44, max(frame.width, frame.height)) / 2
                if hypot(screenPoint.x - frame.midX, screenPoint.y - frame.midY) <= radius { return control }
            }
        }
        return nil
    }

    // Screen points, so guides feel the same at every zoom level.
    private static let rulerTolerance: CGFloat = 10
    private static let rulerDecisionDistance: CGFloat = 6
    /// A protected-zone touch that moved less than this is a tap for its control.
    private static let protectedTapSlop: CGFloat = 12
    private static let centerSnapRadius: CGFloat = 8
    private static let rotationSnap = (capture: 5 * Double.pi / 180, release: 8 * Double.pi / 180)

    private func ruled(_ point: CGPoint) -> CGPoint {
        guides.activeRuler?.project(point) ?? point
    }

    private func guideDragStart(at location: CGPoint, size: CGSize) -> GuideDrag? {
        let layout = guides.layout(paperSize: controller.document.size(fallback: size))
        let handles = layout.handles(canvasToScreen(size))
        let radius = PerspectiveGuideLayout.handleHitRadius
        if hypot(location.x - handles.rotate.x, location.y - handles.rotate.y) <= radius {
            let center = layout.center.applying(canvasToScreen(size))
            // An already aligned guide does not click again until it leaves the magnet.
            let quarter = Int((guides.rotation / (.pi / 2)).rounded())
            let isAligned = abs(guides.rotation - Double(quarter) * .pi / 2) < 0.0001
            return .rotate(startAngle: atan2(location.y - center.y, location.x - center.x),
                           startRotation: guides.rotation, snappedQuarter: isAligned ? (quarter % 4 + 4) % 4 : nil)
        }
        if hypot(location.x - handles.move.x, location.y - handles.move.y) <= radius {
            return .move(startCenter: guides.center, isCentered: guides.center == CGPoint(x: 0.5, y: 0.5))
        }
        let points = layout.vanishingPoints
        if layout.preset == .two, points.count == 2 {
            let transform = canvasToScreen(size)
            let distances = points.map { point -> CGFloat in
                let screen = point.applying(transform)
                return hypot(location.x - screen.x, location.y - screen.y)
            }
            let index = distances[0] <= distances[1] ? 0 : 1
            if distances[index] <= radius {
                let quarter = Int((guides.rotation / (.pi / 2)).rounded())
                let isAligned = abs(guides.rotation - Double(quarter) * .pi / 2) < 0.0001
                return .vanishingPoint(index: index, fixed: points[1 - index], startPoint: points[index],
                                       snappedQuarter: isAligned ? (quarter % 4 + 4) % 4 : nil)
            }
        }
        return nil
    }

    private func updateGuideDrag(_ drag: GuideDrag, from start: CGPoint, to location: CGPoint, size: CGSize) {
        let paper = controller.document.size(fallback: size)
        switch drag {
        case let .rotate(startAngle, startRotation, snappedQuarter):
            let center = guides.layout(paperSize: paper).center.applying(canvasToScreen(size))
            let angle = atan2(location.y - center.y, location.x - center.x)
            let proposed = PerspectiveGuides.normalizedRotation(startRotation + Double(angle - startAngle))
            // Magnetize horizontal and vertical orientations; a wider release radius prevents repeated clicks.
            let quarter = Int((proposed / (.pi / 2)).rounded())
            // Compare quadrants so crossing ±180° does not count as a new orientation.
            let quadrant = (quarter % 4 + 4) % 4
            let deviation = abs(proposed - Double(quarter) * .pi / 2)
            let snapped = deviation <= (snappedQuarter == quadrant ? Self.rotationSnap.release : Self.rotationSnap.capture)
            guides.rotation = snapped ? PerspectiveGuides.normalizedRotation(Double(quarter) * .pi / 2) : proposed
            if snapped && snappedQuarter != quadrant { WKInterfaceDevice.current().play(.click) }
            guideDrag = .rotate(startAngle: startAngle, startRotation: startRotation,
                                snappedQuarter: snapped ? quadrant : nil)
        case let .move(startCenter, wasCentered):
            let scale = zoom * canvasFit(size)
            var point = CGPoint(x: startCenter.x * paper.width + (location.x - start.x) / scale,
                                y: startCenter.y * paper.height + (location.y - start.y) / scale)
            // A vanishing point may lie off the paper. One paper size of margin keeps the
            // handles reachable: at the 25% minimum zoom the viewport spans that far.
            point.x = min(2 * paper.width, max(-paper.width, point.x))
            point.y = min(2 * paper.height, max(-paper.height, point.y))
            let radius = (wasCentered ? 1.5 : 1) * Self.centerSnapRadius / scale
            let isCentered = hypot(point.x - paper.width / 2, point.y - paper.height / 2) <= radius
            if isCentered { point = CGPoint(x: paper.width / 2, y: paper.height / 2) }
            guides.center = CGPoint(x: point.x / max(paper.width, 1), y: point.y / max(paper.height, 1))
            if isCentered && !wasCentered { WKInterfaceDevice.current().play(.click) }
            guideDrag = .move(startCenter: startCenter, isCentered: isCentered)
        case let .vanishingPoint(index, fixed, startPoint, snappedQuarter):
            let scale = zoom * canvasFit(size)
            var point = CGPoint(x: startPoint.x + (location.x - start.x) / scale,
                                y: startPoint.y + (location.y - start.y) / scale)
            // The same reachable margin as the guide center.
            point.x = min(2 * paper.width, max(-paper.width, point.x))
            point.y = min(2 * paper.height, max(-paper.height, point.y))
            // The horizon runs from the first point to the second.
            let delta = index == 1 ? CGPoint(x: point.x - fixed.x, y: point.y - fixed.y)
                                   : CGPoint(x: fixed.x - point.x, y: fixed.y - point.y)
            guard hypot(delta.x, delta.y) * scale >= 1 else { return }
            let proposed = Double(atan2(delta.y, delta.x))
            // Keep a level horizon easy to hit, like the rotation handle.
            let quarter = Int((proposed / (.pi / 2)).rounded())
            let quadrant = (quarter % 4 + 4) % 4
            let deviation = abs(proposed - Double(quarter) * .pi / 2)
            let snapped = deviation <= (snappedQuarter == quadrant ? Self.rotationSnap.release : Self.rotationSnap.capture)
            let rotation = snapped ? PerspectiveGuides.normalizedRotation(Double(quarter) * .pi / 2) : proposed
            let axis = CGPoint(x: cos(rotation), y: sin(rotation))
            // Half the distance between the points maps to the view angle; the angle range limits it.
            let along = abs(delta.x * axis.x + delta.y * axis.y)
            let half = max(paper.width, paper.height) / 2
            let range = PerspectiveGuides.viewAngleRange
            let angle = min(range.upperBound, max(range.lowerBound,
                Double(2 * atan(half / max(along / 2, 0.001))) * 180 / .pi))
            let distance = half / CGFloat(tan(angle * .pi / 360))
            let sign: CGFloat = index == 1 ? 1 : -1
            let center = CGPoint(x: fixed.x + sign * axis.x * distance, y: fixed.y + sign * axis.y * distance)
            guides.rotation = rotation
            guides.viewAngle = angle
            guides.center = CGPoint(x: center.x / max(paper.width, 1), y: center.y / max(paper.height, 1))
            if snapped && snappedQuarter != quadrant { WKInterfaceDevice.current().play(.click) }
            guideDrag = .vanishingPoint(index: index, fixed: fixed, startPoint: startPoint,
                                        snappedQuarter: snapped ? quadrant : nil)
        }
    }

    private func endGuideInteraction() {
        if guideDrag != nil { guides.savePlacement() }
        guideDrag = nil
        isRulerPending = false
        if guides.activeRuler != nil { guides.activeRuler = nil }
    }

    private func canvasToScreen(_ size: CGSize) -> CGAffineTransform {
        let paper = controller.document.size(fallback: size)
        let scale = zoom * canvasFit(size)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: size.width / 2 + offset.width - paper.width * scale / 2,
                                 ty: size.height / 2 + offset.height - paper.height * scale / 2)
    }

    /// Screen points of canvas rendered around the view, so short pans and the ink of
    /// strokes near the edge stay sharp without new tiles.
    private static let regionMargin: CGFloat = 32

    /// The tiles to render above the paper raster, or nil when the paper raster already
    /// has every pixel the screen shows. The paper keeps all layers at screen resolution
    /// for the whole canvas; zooming in multiplies the pixels needed, which only fit in
    /// memory for the visible part.
    private func tilePlan(size: CGSize, paper: CGSize, fit: CGFloat) -> TilePlan? {
        guard !lasso.isActive, zoom > 1, fit.isFinite, fit > 0 else { return nil }
        let layers = controller.document.layers.count
        let screenBase = WatchBitmapRenderer.rasterScale(displayScale: displayScale, zoom: 1, fit: fit,
                                                         canvasSize: paper, layerCount: layers)
        let grid = pixelGridScale
        let base = grid.map { min(screenBase, $0) } ?? screenBase
        // Steps of √2: zooming within a step keeps the tiles, and the step at or above the
        // screen's need keeps them sharp; ×2 steps would cost up to 4× the pixels.
        let shown = displayScale * fit * CGFloat(zoom)
        // Pixel view: never finer than the saved grid; past it the grid's tiles are magnified.
        let needed = min(grid ?? WatchBitmapRenderer.maximumRegionScale,
                         pow(2, (log2(shown) * 2 - 0.001).rounded(.up) / 2))
        guard needed > base + 0.01 else { return nil }
        let bounds = CGRect(origin: .zero, size: paper)
        let visible = visibleCanvasRect(size).intersection(bounds)
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let margin = Self.regionMargin / (CGFloat(zoom) * fit)
        let rect = visible.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        // Each layer with ink in a tile keeps a float ink of it (the others a 1×1 one).
        // The current and the fallback scale may coexist: each gets half the budget.
        let touched = layerReach.bounds(for: controller.document, revision: controller.documentRevision)
            .filter { $0.intersects(rect) }.count
        let budget = CGFloat(WatchBitmapRenderer.LayerCache.inkByteLimit) / 2 / (16 * CGFloat(max(1, touched)))
        func fits(_ scale: CGFloat) -> Bool {
            RegionTiling.pixels(covering: rect, scale: scale, paper: paper) <= budget
        }
        var scale = RegionTiling.ladderScale(needed)
        // Keep the current scale up to one step above the need: zooming out by a step
        // or panning reuses its tiles and only renders the new cells.
        if let current = tileScale, current >= scale - 0.01,
           current <= scale * 2.squareRoot() + 0.01, fits(current) {
            scale = current
        } else {
            while !fits(scale) {
                scale = RegionTiling.ladderScale(scale / 2.squareRoot())
                guard scale > base + 0.01 else { return nil }
            }
        }
        guard scale > base + 0.01 else { return nil }
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let view = RegionTiling.cells(covering: visible, scale: scale, paper: paper, nearest: center)
        let viewSet = Set(view)
        let around = RegionTiling.cells(covering: rect, scale: scale, paper: paper, nearest: center)
            .filter { !viewSet.contains($0) }
        return TilePlan(scale: scale, view: view, margin: around)
    }

    /// Adds the plan's missing tiles nearest the view's centre first, keeps tiles of the
    /// previous scale over the view as a fallback, and drops everything else.
    private func applyTilePlan(_ plan: TilePlan, paper: CGSize, visible: CGRect) {
        let wanted = plan.view + plan.margin
        let wantedSet = Set(wanted)
        if plan.scale != tileScale {
            // Only one fallback resolution: the scale on screen until now. A scale that never
            // completed was never shown; the fallback below it stays.
            if let old = tileScale, completeScale == old { fallbackScale = old }
            tileScale = plan.scale
        }
        let fallback = tiles.filter {
            $0.id.scale == fallbackScale && $0.id.scale != plan.scale
                && readyTiles.contains($0.id) && $0.rect.intersects(visible)
        }
        let kept = Dictionary(uniqueKeysWithValues: tiles.filter { wantedSet.contains($0.id) }.map { ($0.id, $0) })
        let current = wanted.compactMap { kept[$0] ?? RegionTiling.tile($0, paper: paper) }
        if current.contains(where: { kept[$0.id] == nil }) {
            tilesRequestedAt = DispatchTime.now().uptimeNanoseconds
        }
        tiles = fallback + current
        let alive = Set(tiles.map(\.id))
        readyTiles = readyTiles.intersection(alive)
        viewTileIDs = plan.view
        if fallback.isEmpty { fallbackScale = nil }
        dropCoveredFallback()
    }

    private func tileBecameReady(_ id: RegionTile.ID) {
        guard readyTiles.insert(id).inserted else { return }
        if controller.activeStroke != nil { lateTiles.insert(id) }
        if completeScale != tileScale, !viewTileIDs.isEmpty, viewTileIDs.allSatisfy(readyTiles.contains) {
            completeScale = tileScale
        }
        if let start = tilesRequestedAt, !viewTileIDs.isEmpty, viewTileIDs.allSatisfy(readyTiles.contains) {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            Self.regionLogger.notice("""
                view tiles ready \(elapsed, format: .fixed(precision: 0), privacy: .public) ms \
                tiles=\(viewTileIDs.count, privacy: .public) \
                scale=\(Double(tileScale ?? 0), format: .fixed(precision: 2), privacy: .public) \
                zoom=\(Double(zoom), format: .fixed(precision: 2), privacy: .public)
                """)
            tilesRequestedAt = nil
        }
        dropCoveredFallback()
    }

    /// The previous resolution leaves once every tile over the view is ready, and never
    /// under a stroke: it may be drawing the stroke where the new tiles still hide.
    private func dropCoveredFallback() {
        guard controller.activeStroke == nil, fallbackScale != nil, completeScale == tileScale,
              viewTileIDs.allSatisfy(readyTiles.contains) else { return }
        tiles.removeAll { $0.id.scale != tileScale }
        readyTiles = readyTiles.filter { $0.scale == tileScale }
        fallbackScale = nil
    }

    /// Canvas points shown in a viewport of `size`, possibly beyond the paper.
    private func visibleCanvasRect(_ size: CGSize) -> CGRect {
        let a = canvasPoint(.zero, size: size)
        let b = canvasPoint(CGPoint(x: size.width, y: size.height), size: size)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func canvasFit(_ size: CGSize) -> CGFloat {
        let paper = controller.document.size(fallback: size)
        return min(size.width / paper.width, size.height / paper.height)
    }

    private func canvasPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        let paper = controller.document.size(fallback: size)
        let scale = zoom * canvasFit(size)
        return CGPoint(x: (point.x - offset.width - size.width / 2) / scale + paper.width / 2,
                       y: (point.y - offset.height - size.height / 2) / scale + paper.height / 2)
    }

    private func sample(at point: CGPoint, time: Date) -> PointerSample {
        PointerSample(position: SIMD2(Float(point.x), Float(point.y)),
                      pressure: 1, timestamp: time.timeIntervalSinceReferenceDate)
    }
}

/// Re-evaluates only its content for each live-stroke sample. The content closure is
/// rebuilt by the parent on structural changes and reads live values from the controller.
private struct LiveStrokeObserver<Content: View>: View {
    @ObservedObject var changes: LiveStrokeChanges
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// Display-only transparency backing shared by the canvas and layer previews.
struct TransparencyCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            for y in 0..<Int(ceil(size.height / 8)) {
                for x in 0..<Int(ceil(size.width / 8)) {
                    let rect = CGRect(x: CGFloat(x) * 8, y: CGFloat(y) * 8, width: 8, height: 8)
                    context.fill(Path(rect), with: .color((x + y).isMultiple(of: 2) ? .white : Color(white: 0.78)))
                }
            }
        }
    }
}
