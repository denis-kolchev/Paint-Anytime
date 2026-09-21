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

    func begin(at sample: PointerSample, style: PencilStyle) {
        activeStroke = Stroke(
            points: [sample],
            style: style
        )
    }

    func update(with sample: PointerSample) {
        guard let lastPoint = activeStroke?.points.last else {
            return
        }

        guard simd_distance(lastPoint.position, sample.position) > 0.001 else {
            return
        }

        activeStroke?.points.append(sample)
    }

    func end(at sample: PointerSample) -> Stroke? {
        update(with: sample)

        let completedStroke = activeStroke
        activeStroke = nil

        return completedStroke
    }

    func cancel() {
        activeStroke = nil
    }
}
