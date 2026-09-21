//
//  PaintView.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//
import MetalKit
import SwiftUI

struct CanvasView: NSViewRepresentable {
    let controller: CanvasController

    func makeCoordinator() -> CanvasRenderer {
        CanvasRenderer(controller: controller)
    }

    func makeNSView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView(
            frame: .zero,
            device: context.coordinator.device
        )

        view.controller = controller
        view.delegate = context.coordinator

        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1
        )

        view.isPaused = true
        view.enableSetNeedsDisplay = true

        controller.onNeedsDisplay = { [weak view] in
            view?.needsDisplay = true
        }

        view.needsDisplay = true

        return view
    }

    func updateNSView(
        _ nsView: MetalCanvasView,
        context: Context
    ) {}

    static func dismantleNSView(
        _ nsView: MetalCanvasView,
        coordinator: CanvasRenderer
    ) {
        nsView.controller?.cancelStroke()
        nsView.controller?.onNeedsDisplay = nil
        nsView.controller = nil
        nsView.delegate = nil
    }
}
