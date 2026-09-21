//
//  StrokeMesher.swift
//  Paint All the Time
//
//  Created by Denis Kolchev on 18.09.2026.
//

import Foundation
import simd

struct StrokeVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

enum StrokeMesher {
    static func vertices(for stroke: Stroke) -> [StrokeVertex] {
        guard !stroke.points.isEmpty else {
            return []
        }

        if stroke.style.instrument == .fountainPen {
            return FountainPenGeometry.polygons(for: stroke).flatMap { polygon in
                guard polygon.count >= 3 else { return [StrokeVertex]() }
                return (1..<(polygon.count - 1)).flatMap { index in
                    [polygon[0], polygon[index], polygon[index + 1]].map {
                        StrokeVertex(position: $0, color: stroke.style.color)
                    }
                }
            }
        }

        let radius = max(stroke.style.width, 0.1) / 2
        let color = stroke.style.color

        var vertices: [StrokeVertex] = []

        func appendTriangle(
            _ a: SIMD2<Float>,
            _ b: SIMD2<Float>,
            _ c: SIMD2<Float>
        ) {
            vertices.append(StrokeVertex(position: a, color: color))
            vertices.append(StrokeVertex(position: b, color: color))
            vertices.append(StrokeVertex(position: c, color: color))
        }

        for (start, end) in zip(
            stroke.points,
            stroke.points.dropFirst()
        ) {
            let delta = end.position - start.position
            let length = simd_length(delta)

            guard length > 0.001 else {
                continue
            }

            let normal = SIMD2<Float>(-delta.y, delta.x)
                / length * radius

            let a = start.position + normal
            let b = start.position - normal
            let c = end.position + normal
            let d = end.position - normal

            appendTriangle(a, b, c)
            appendTriangle(c, b, d)
        }

        let segments = 20

        for point in stroke.points {
            for index in 0..<segments {
                let angleA = Float(index)
                    / Float(segments) * 2 * Float.pi

                let angleB = Float(index + 1)
                    / Float(segments) * 2 * Float.pi

                let a = point.position + SIMD2<Float>(
                    cos(angleA),
                    sin(angleA)
                ) * radius

                let b = point.position + SIMD2<Float>(
                    cos(angleB),
                    sin(angleB)
                ) * radius

                appendTriangle(point.position, a, b)
            }
        }

        return vertices
    }
}
