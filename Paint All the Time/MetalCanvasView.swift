//
//  CanvasView.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//

import AppKit
import MetalKit

final class MetalCanvasView: MTKView {
    weak var controller: CanvasController?

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.beginStroke(at: sample(from: event))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.continueStroke(at: sample(from: event))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.endStroke(at: sample(from: event))
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancelStroke()
    }

    private func sample(from event: NSEvent) -> PointerSample {
        let point = convert(event.locationInWindow, from: nil)

        return PointerSample(
            position: SIMD2<Float>(
                Float(point.x),
                Float(point.y)
            ),
            pressure: 1,
            timestamp: event.timestamp
        )
    }
}
