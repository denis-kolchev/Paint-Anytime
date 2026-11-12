//
//  WatchCanvasView.swift
//  Paint Anytime
//
//  Created by Denis Kolchev on 20.09.2026.
//

import SwiftUI
import WatchKit

enum CanvasToolbarControl: Hashable {
    case custom(Int)
    case more, tools, clear, undo, redo, save, morph, contentMorph, canvasToolsMorph
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
    @State private var samplingImage: CGImage?
    @State private var loupePoint: CGPoint?
    @State private var loupeImage: CGImage?
    var onCanvasInteraction: () -> Void = {}
    /// A short tap that landed on the canvas inside a protected control's zone. With the
    /// native bars hidden, taps on a drawn control sometimes reach the canvas under it
    /// instead of the control; the screen forwards them to that control.
    var onProtectedTap: (CanvasToolbarControl) -> Void = { _ in }
    /// The protected control the current gesture started on.
    @State private var protectedStartControl: CanvasToolbarControl?
    @State private var crownZoom = 1.0
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
    }

    private var showsGuides: Bool {
        guides.isEnabled && rendersArtwork && !lasso.isActive && !tutorial.isActive
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
                        WatchRasterArtwork(document: useLayers ? displayedDocument : nil,
                            selectedLayerID: controller.selectedLayer.id, selectionPreview: lasso.previewState, selectionSeed: lasso.selectionSeed,
                            strokes: useLayers ? [] : (displayedDocument.layers.first?.strokes ?? []),
                            activeStroke: controller.activeStroke, documentID: ObjectIdentifier(controller),
                            documentRevision: controller.documentRevision,
                            clearDocumentRevision: controller.clearDocumentRevision,
                            activeStrokeRevision: controller.activeStrokeRevision,
                            activeStrokeID: controller.activeStrokeID, onFramePrepared: onArtworkPrepared, zoom: zoom,
                            liveSubmitter: liveSubmitter, allowsInkTip: allowsInkTip)
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
                if showsGuides {
                    PerspectiveGuidesOverlay(layout: guides.layout(paperSize: paperSize),
                        canvasToScreen: canvasToScreen(geometry.size), activeRuler: guides.activeRuler,
                        showsHandles: acceptsInput && !isMovingCanvas && !isEyedropperActive
                            && controller.activeStroke == nil && !isRulerPending)
                        .clipped()
                }
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
                else { samplingImage = nil; loupeImage = nil }
            }
            .onAppear { if isEyedropperActive { prepareSampler(size: geometry.size) } }
            .onChange(of: geometry.size) { _, size in
                if isEyedropperActive { prepareSampler(size: size) }
            }
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
                                        tolerance: WatchLassoGeometry.handleHitRadius / (zoom * fit), controller: controller)
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
                            if !isRulerPending, guides.activeRuler == nil, showsGuides,
                               guides.layout(paperSize: paperSize).isNearGuide(start, tolerance: tolerance) {
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
                            // A tap on a guide still leaves a dot.
                            controller.beginStroke(at: sample(
                                at: canvasPoint(value.startLocation, size: geometry.size), time: value.time))
                        }
                        guard controller.activeStroke != nil else { return }
                        let recognizedKind = controller.recognizedShapeKind
                        if tutorial.isActive, tutorial.step == .holdCircle, tutorial.acceptsActions,
                           recognizedKind != .circle, recognizedKind != .ellipse {
                            controller.continueStroke(at: sample(
                                at: canvasPoint(value.location, size: geometry.size), time: value.time))
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
                        if controller.isShapeSnapped { RenderDiagnostics.shapeLifted() }
                        controller.endStroke(at: sample(
                            at: ruled(canvasPoint(value.location, size: geometry.size)), time: value.time))
                        if controller.document.strokes.count > previousCount {
                            tutorial.finishedCircleAttempt(kind: recognizedKind)
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
            get: { crownZoom },
            set: { value in
                guard tutorial.allowsCanvasZoom else { return }
                guard (acceptsInput || acceptsZoomOnlyInput) && !isDragging && controller.activeStroke == nil else { return }
                guard value != crownZoom else { return }
                let previousZoom = zoom
                let wasSnapped = previousZoom == 1
                if !lasso.isActive { isMovingCanvas = true }
                crownZoom = value
                // Keep the canvas point at the viewport center fixed, including
                // when entering or leaving the 100% zoom snap range.
                let ratio = zoom / previousZoom
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
                tutorial.changedZoom()
                if zoom == 1 && !wasSnapped { WKInterfaceDevice.current().play(.click) }
            }
        ), from: 0.25, through: 8, by: 0.05, sensitivity: .low,
           isContinuous: false, isHapticFeedbackEnabled: false,
           onChange: { [step = tutorial.step] event in
                tutorial.usedCrown(in: step, velocity: event.velocity)
            })
        .digitalCrownAccessory(hidesCrownIndicator ? .hidden : .automatic)
        .accessibilityLabel(lasso.isActive ? L10n.text(lasso.mode.title) : isMovingCanvas ? L10n.text("Moving canvas") : L10n.text("Finger drawing canvas"))
        .accessibilityValue(L10n.format("Zoom %d percent", Int(zoom * 100)))
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

    private func prepareSampler(size: CGSize) {
        controller.cancelStroke()
        samplingImage = WatchBitmapRenderer.render(document: controller.document, size: controller.document.size(fallback: size), scale: displayScale)
        updateSample(at: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
    }

    private func updateSample(at location: CGPoint, size: CGSize) {
        guard let image = samplingImage else { return }
        let point = canvasPoint(location, size: size)
        let x = min(image.width - 1, max(0, Int(floor(point.x * displayScale))))
        let y = min(image.height - 1, max(0, Int(floor(point.y * displayScale))))
        // Place the lens over the actual pixel, including when dragging beyond the paper.
        let paper = controller.document.size(fallback: size)
        let fit = canvasFit(size)
        loupePoint = CGPoint(x: ((CGFloat(x) + 0.5) / displayScale - paper.width / 2) * zoom * fit + size.width / 2 + offset.width,
                             y: ((CGFloat(y) + 0.5) / displayScale - paper.height / 2) * zoom * fit + size.height / 2 + offset.height)
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
