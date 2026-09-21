//
//  WatchCanvasView.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 20.09.2026.
//

import SwiftUI
import WatchKit

struct WatchCanvasView: View {
    @ObservedObject var controller: CanvasController
    var acceptsInput = true
    @Binding var isMovingCanvas: Bool
    @State private var crownZoom = 1.0
    @State private var offset = CGSize.zero
    @State private var panOrigin: CGSize?
    @GestureState private var isDragging = false
    private var zoom: Double { abs(crownZoom - 1) <= 0.075 ? 1 : crownZoom }
    @FocusState private var crownFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.16)
                WatchCanvasArtwork(strokes: controller.document.strokes + [controller.activeStroke].compactMap { $0 })
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay { Rectangle().strokeBorder(.gray.opacity(0.6), lineWidth: zoom < 1 ? 1 : 0) }
                    .scaleEffect(zoom)
                    .offset(offset)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        guard acceptsInput else { return }
                        if isMovingCanvas {
                            if panOrigin == nil { panOrigin = offset }
                            let origin = panOrigin ?? offset
                            let proposed = CGSize(width: origin.width + value.translation.width,
                                                  height: origin.height + value.translation.height)
                            let wasCentered = offset == .zero
                            // Use screen points so the magnet feels the same at every zoom.
                            // A wider release radius prevents repeated clicks near the boundary.
                            let radius: CGFloat = wasCentered ? 12 : 8
                            let isCentered = hypot(proposed.width, proposed.height) <= radius
                            offset = isCentered ? .zero : proposed
                            if isCentered && !wasCentered {
                                WKInterfaceDevice.current().play(.click)
                            }
                            return
                        }
                        let start = canvasPoint(value.startLocation, size: geometry.size)
                        guard CGRect(origin: .zero, size: geometry.size).contains(start) else { return }
                        if controller.activeStroke == nil {
                            controller.beginStroke(at: sample(at: start, time: value.time))
                        }
                        controller.continueStroke(at: sample(
                            at: canvasPoint(value.location, size: geometry.size), time: value.time))
                    }
                    .onEnded { value in
                        if isMovingCanvas { panOrigin = nil; return }
                        guard controller.activeStroke != nil else { return }
                        controller.endStroke(at: sample(
                            at: canvasPoint(value.location, size: geometry.size), time: value.time))
                    }
            )
        }
        .focusable(acceptsInput)
        .focused($crownFocused)
        .digitalCrownRotation(Binding(
            get: { crownZoom },
            set: { value in
                guard acceptsInput && !isDragging && controller.activeStroke == nil else { return }
                guard value != crownZoom else { return }
                let wasSnapped = zoom == 1
                isMovingCanvas = true
                crownZoom = value
                if zoom == 1 && !wasSnapped { WKInterfaceDevice.current().play(.click) }
            }
        ), from: 0.25, through: 4, by: 0.05, sensitivity: .low,
           isContinuous: false, isHapticFeedbackEnabled: false)
        .accessibilityLabel(isMovingCanvas ? "Перемещение холста" : "Холст для рисования пальцем")
        .accessibilityValue("Масштаб \(Int(zoom * 100)) процентов")
        .onAppear { crownFocused = acceptsInput }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { panOrigin = nil }
        }
        .onChange(of: isMovingCanvas) { _, moving in
            panOrigin = nil
            if !moving && zoom == 1 { crownZoom = 1 }
            crownFocused = acceptsInput
        }
        .onChange(of: acceptsInput) { _, enabled in
            crownFocused = enabled
            if !enabled { controller.cancelStroke() }
        }
        .onDisappear { controller.cancelStroke() }
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

// Shared by the live canvas and export; never includes controls or system chrome.
struct WatchCanvasArtwork: View {
    let strokes: [Stroke]

    var body: some View {
        Canvas { context, _ in
            context.drawLayer { layer in
                for stroke in strokes { WatchStrokeDrawing.draw(stroke, in: &layer) }
            }
        }
        .background(.white)
    }
}
