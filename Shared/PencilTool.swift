//
//  PencilTool.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//

// Description:
// The pencil accepts input samples and assembles the current stroke.

import simd

final class PencilTool {
    private(set) var activeStroke: Stroke?
    enum ShapeState: Equatable { case drawing, snapped, adjusting }
    private(set) var shapeState: ShapeState = .drawing
    private var recognizedShape: ShapeRecognizer.Result?
    private var shapeSamples: [PointerSample] = []
    private var holdPosition = SIMD2<Float>.zero
    private var adjustmentTolerance: Float = 2

    func begin(at sample: PointerSample, style: PencilStyle) {
        resetShape()
        activeStroke = Stroke(
            points: [sample],
            style: style
        )
        activeStroke?.beginInputStream()
    }

    func update(with sample: PointerSample) {
        if let shape = recognizedShape {
            adjust(shape, to: sample.position)
            return
        }
        guard let lastPoint = activeStroke?.points.last else {
            return
        }

        guard simd_distance(lastPoint.position, sample.position) > 0.001 else {
            return
        }

        activeStroke?.appendInputSample(sample)
    }

    func end(at sample: PointerSample) -> Stroke? {
        update(with: sample)

        let completedStroke = activeStroke
        activeStroke = nil
        resetShape()

        return completedStroke
    }

    func cancel() {
        activeStroke = nil
        resetShape()
    }

    @discardableResult
    func recognizeShape(adjustmentTolerance: Float = 2) -> Bool {
        guard recognizedShape == nil, var stroke = activeStroke,
              stroke.style.instrument != .eraser, let last = stroke.points.last,
              let result = ShapeRecognizer.recognize(stroke.points) else { return false }
        holdPosition = last.position
        self.adjustmentTolerance = adjustmentTolerance
        let first = stroke.points[0]
        let duration = max(0.001, last.timestamp - first.timestamp)
        shapeSamples = result.points.enumerated().map { index, point in
            PointerSample(position: point, pressure: first.pressure,
                          timestamp: first.timestamp + duration * Double(index) / Double(max(1, result.points.count - 1)))
        }
        // Editing the points invalidates the append-only render stream while
        // retaining the gesture's ID, color, width, opacity and undo transaction.
        stroke.points = shapeSamples
        activeStroke = stroke
        recognizedShape = result
        shapeState = .snapped
        return true
    }

    private func adjust(_ shape: ShapeRecognizer.Result, to pointer: SIMD2<Float>) {
        guard simd_distance(pointer, holdPosition) > adjustmentTolerance || shapeState == .adjusting else { return }
        let reference = holdPosition - shape.anchor, current = pointer - shape.anchor
        let length = simd_length(reference)
        guard length > 1 else { return }
        let scale = min(4, max(0.25, simd_length(current) / length))
        let angle = atan2(reference.x * current.y - reference.y * current.x, simd_dot(reference, current))
        let c = cos(angle), s = sin(angle)
        activeStroke?.points = shapeSamples.map { sample in
            let p = (sample.position - shape.anchor) * scale
            return PointerSample(position: shape.anchor + SIMD2(p.x * c - p.y * s, p.x * s + p.y * c),
                                 pressure: sample.pressure, timestamp: sample.timestamp)
        }
        shapeState = .adjusting
    }

    private func resetShape() {
        shapeState = .drawing
        recognizedShape = nil
        shapeSamples.removeAll(keepingCapacity: true)
    }
}
