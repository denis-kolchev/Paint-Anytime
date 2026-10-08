//
//  WatchCanvasView.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 20.09.2026.
//

import SwiftUI
import WatchKit

enum CanvasToolbarControl: Hashable {
    case more, tools, clear, undo, redo, save, morph, contentMorph
}

struct WatchCanvasView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var controller: CanvasController
    @ObservedObject var tutorial = TutorialSession.inactive
    var rendersArtwork = true
    var acceptsInput = true
    var protectedControls: [CanvasToolbarControl: CGRect] = [:]
    @Binding var isMovingCanvas: Bool
    var isEyedropperActive = false
    var onSampleColor: (SIMD4<Float>) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @State private var samplingImage: CGImage?
    @State private var loupePoint: CGPoint?
    @State private var loupeImage: CGImage?
    var onCanvasInteraction: () -> Void = {}
    @State private var crownZoom = 1.0
    @State private var offset = CGSize.zero
    @State private var panOrigin: CGSize?
    @State private var acceptsCurrentGesture: Bool?
    @GestureState private var isDragging = false
    @State private var shapeHoldTask: Task<Void, Never>?
    @State private var shapeHoldAnchor: CGPoint?
    @Environment(\.scenePhase) private var scenePhase

    private var needsLayerRendering: Bool {
        controller.document.layers.count != 1 || controller.document.backgroundColor != SIMD4(1, 1, 1, 1)
        || !controller.selectedLayer.isVisible || controller.selectedLayer.opacity != 1
        || controller.selectedLayer.locksTransparency || controller.document.strokes.contains { $0.locksTransparency }
    }

    private var zoom: Double { abs(crownZoom - 1) <= 0.075 ? 1 : crownZoom }
    @FocusState private var crownFocused: Bool
    private var shouldFocusCrown: Bool {
        scenePhase == .active && acceptsInput && tutorial.allowsCanvasZoom
    }
    private struct CrownFocusRequest: Equatable {
        let enabled: Bool
        let step: TutorialStep
    }

    var body: some View {
        let _ = TutorialDebug.trace("canvas.body", "input=\(acceptsInput) controls=\(protectedControls.count) \(tutorial.debugState)")
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.16)
                // Hiding settings/gallery must not destroy the raster view's image and cache.
                // Keep its identity so returning to the canvas displays the last frame immediately.
                WatchRasterArtwork(document: needsLayerRendering ? controller.document : nil,
                    selectedLayerID: controller.selectedLayer.id, strokes: controller.document.strokes,
                    activeStroke: controller.activeStroke, documentID: ObjectIdentifier(controller),
                    documentRevision: controller.documentRevision,
                    activeStrokeRevision: controller.activeStrokeRevision,
                    activeStrokeID: controller.activeStrokeID, zoom: zoom)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay { Rectangle().strokeBorder(.gray.opacity(0.6), lineWidth: zoom < 1 ? 1 : 0) }
                    .scaleEffect(zoom)
                    .offset(offset)
                    .opacity(rendersArtwork ? 1 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay {
                if isEyedropperActive, let loupeImage, let loupePoint {
                    Image(decorative: loupeImage, scale: 1)
                        .resizable().interpolation(.none)
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                        .overlay {
                            Rectangle().stroke(.black, lineWidth: 3).frame(width: 8, height: 8)
                                .overlay { Rectangle().stroke(.white, lineWidth: 1).frame(width: 8, height: 8) }
                        }
                        .position(loupePoint)
                        .allowsHitTesting(false)
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
            .onChange(of: crownZoom) { _, _ in
                if isEyedropperActive { updateSample(at: loupePoint ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2), size: geometry.size) }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        guard acceptsInput && tutorial.acceptsActions else { return }
                        guard (isMovingCanvas ? tutorial.allowsCanvasPan : tutorial.allowsDrawing) else { return }
                        tutorial.activity()
                        if acceptsCurrentGesture == nil {
                            acceptsCurrentGesture = !isProtectedStart(value.startLocation,
                                canvasFrame: geometry.frame(in: .global))
                            if acceptsCurrentGesture == true { onCanvasInteraction() }
                        }
                        // Keep the initial decision even when controls hide or the finger moves away.
                        guard acceptsCurrentGesture == true else { return }
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
                        guard controller.pencilStyle.instrument != .fill else { return }
                        let start = canvasPoint(value.startLocation, size: geometry.size)
                        // Preserve off-canvas samples so a stroke can enter the paper naturally.
                        // The artwork view and exported bitmap clip ink to the canvas bounds.
                        if controller.activeStroke == nil {
                            controller.beginStroke(at: sample(at: start, time: value.time))
                        }
                        controller.continueStroke(at: sample(
                            at: canvasPoint(value.location, size: geometry.size), time: value.time))
                        scheduleShapeHold(at: value.location)
                    }
                    .onEnded { value in
                        cancelShapeHold()
                        defer { acceptsCurrentGesture = nil; panOrigin = nil }
                        guard acceptsInput && acceptsCurrentGesture == true else { return }
                        if isMovingCanvas {
                            panOrigin = nil
                            return
                        }
                        if controller.pencilStyle.instrument == .fill {
                            let point = canvasPoint(value.startLocation, size: geometry.size)
                            if controller.selectedLayer.isVisible,
                               let fill = WatchBitmapRenderer.floodFill(document: controller.document,
                                   size: geometry.size, point: point, style: controller.pencilStyle) {
                                controller.commitFill(fill)
                            }
                            return
                        }
                        guard controller.activeStroke != nil else { return }
                        let previousCount = controller.document.strokes.count
                        controller.endStroke(at: sample(
                            at: canvasPoint(value.location, size: geometry.size), time: value.time))
                        if controller.document.strokes.count > previousCount { tutorial.record(.stroke) }
                    },
                including: acceptsInput && tutorial.acceptsActions ? .all : .none
            )
        }
        // Keep the Crown target registered throughout the canvas exercise. The
        // binding below still rejects zoom until the lesson permits it.
        .focusable(acceptsInput)
        .focused($crownFocused)
        .digitalCrownRotation(detent: Binding(
            get: { crownZoom },
            set: { value in
                guard tutorial.allowsCanvasZoom else { return }
                guard acceptsInput && !isDragging && controller.activeStroke == nil else { return }
                guard value != crownZoom else { return }
                let previousZoom = zoom
                let wasSnapped = previousZoom == 1
                isMovingCanvas = true
                crownZoom = value
                // Keep the canvas point at the viewport center fixed, including
                // when entering or leaving the 100% zoom snap range.
                let ratio = zoom / previousZoom
                offset = CGSize(width: offset.width * ratio, height: offset.height * ratio)
                tutorial.changedZoom()
                if zoom == 1 && !wasSnapped { WKInterfaceDevice.current().play(.click) }
            }
        ), from: 0.25, through: 4, by: 0.05, sensitivity: .low,
           isContinuous: false, isHapticFeedbackEnabled: false,
           onChange: { [step = tutorial.step] event in
                tutorial.usedCrown(in: step, velocity: event.velocity)
            })
        .accessibilityLabel(isMovingCanvas ? L10n.text("Moving canvas") : L10n.text("Finger drawing canvas"))
        .accessibilityValue(L10n.format("Zoom %d percent", Int(zoom * 100)))
        .task(id: CrownFocusRequest(enabled: shouldFocusCrown, step: tutorial.step)) {
            crownFocused = false
            guard shouldFocusCrown else { return }
            // Zoom -> pan keeps zoom enabled, but replaces the lesson UI.
            // Reacquire focus after that transition too, not just false -> true.
            // watchOS 10 can discard focus requested in the same update that
            // enables a target. Wait for it to be installed in the focus tree.
            // Cancellation prevents a hidden canvas stealing focus from tools.
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                crownFocused = true
            } catch {}
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging {
                cancelShapeHold()
                // A normal onEnded already commits and clears the stroke.
                // A cancelled gesture has no onEnded and must not remain live.
                if controller.activeStroke != nil { controller.cancelStroke() }
                panOrigin = nil
                acceptsCurrentGesture = nil
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
            if !enabled { cancelShapeHold(); controller.cancelStroke() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelShapeHold(); controller.cancelStroke() }
        }
        .onDisappear {
            cancelShapeHold()
            controller.cancelStroke()
        }
    }

    private func prepareSampler(size: CGSize) {
        controller.cancelStroke()
        samplingImage = WatchBitmapRenderer.render(document: controller.document, size: size, scale: displayScale)
        updateSample(at: CGPoint(x: size.width / 2, y: size.height / 2), size: size)
    }

    private func updateSample(at location: CGPoint, size: CGSize) {
        guard let image = samplingImage else { return }
        let point = canvasPoint(location, size: size)
        let x = min(image.width - 1, max(0, Int(floor(point.x * displayScale))))
        let y = min(image.height - 1, max(0, Int(floor(point.y * displayScale))))
        // Place the lens over the actual pixel, including when dragging beyond the paper.
        loupePoint = CGPoint(x: ((CGFloat(x) + 0.5) / displayScale - size.width / 2) * zoom + size.width / 2 + offset.width,
                             y: ((CGFloat(y) + 0.5) / displayScale - size.height / 2) * zoom + size.height / 2 + offset.height)
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
        shapeHoldTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                guard controller.activeStroke?.id == gestureID, !isMovingCanvas,
                      tutorial.acceptsActions, tutorial.allowsDrawing else { return }
                if controller.recognizeActiveShape(adjustmentTolerance: tolerance) {
                    WKInterfaceDevice.current().play(.click)
                }
            } catch { }
        }
    }

    private func isProtectedStart(_ point: CGPoint, canvasFrame: CGRect) -> Bool {
        let screenPoint = CGPoint(x: canvasFrame.minX + point.x, y: canvasFrame.minY + point.y)
        for (control, frame) in protectedControls {
            guard !frame.isNull && !frame.isEmpty else { continue }
            // Include the button when the toolbar reports only its icon, without
            // adding a margin toward the canvas. Extend its rounded footprint
            // outward to the screen edges, never across the whole bottom row.
            let radiusX = max(44, frame.width) / 2
            let radiusY = max(44, frame.height) / 2
            // Follow the actual screen position, including right-to-left layouts.
            let outwardSideDistance = frame.midX < canvasFrame.midX
                ? max(0, screenPoint.x - frame.midX)
                : max(0, frame.midX - screenPoint.x)
            let dx: CGFloat
            let dy: CGFloat
            switch control {
            case .morph, .contentMorph:
                if frame.contains(screenPoint) { return true }
                continue
            case .more, .tools:
                dx = outwardSideDistance
                dy = max(0, screenPoint.y - frame.midY)
            case .clear, .save:
                dx = outwardSideDistance
                dy = max(0, frame.midY - screenPoint.y)
            case .undo, .redo:
                dx = abs(screenPoint.x - frame.midX)
                dy = max(0, frame.midY - screenPoint.y)
            }
            let normalizedX = dx / radiusX
            let normalizedY = dy / radiusY
            if normalizedX * normalizedX + normalizedY * normalizedY <= 1 { return true }
        }
        return false
    }

    private func canvasPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - offset.width - size.width / 2) / zoom + size.width / 2,
                y: (point.y - offset.height - size.height / 2) / zoom + size.height / 2)
    }

    private func sample(at point: CGPoint, time: Date) -> PointerSample {
        PointerSample(position: SIMD2(Float(point.x), Float(point.y)),
                      pressure: 1, timestamp: time.timeIntervalSinceReferenceDate)
    }
}
