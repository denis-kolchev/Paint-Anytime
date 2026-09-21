import Foundation
import simd

// Input-dependent geometry shared independently of the display technology.
enum BrushGeometry {
    static func radii(for stroke: Stroke) -> [Float] {
        let base = max(0.1, stroke.style.width) / 2
        guard stroke.style.instrument == .pen else {
            return Array(repeating: base, count: stroke.points.count)
        }
        var result: [Float] = []
        var smoothedScale: Float = 0.85
        for index in stroke.points.indices {
            if index > 0 {
                let previous = stroke.points[index - 1]
                let current = stroke.points[index]
                let elapsed = current.timestamp - previous.timestamp
                // Ignore duplicate timestamps rather than introducing artificial speed spikes.
                if elapsed.isFinite && elapsed > 0.0001 {
                    let speed = simd_distance(previous.position, current.position) / Float(elapsed)
                    let target = 0.28 + 0.72 / (1 + speed / 150)
                    let blend = Float(1 - exp(-min(elapsed, 0.1) / 0.035))
                    smoothedScale += (target - smoothedScale) * blend
                }
            }
            result.append(base * smoothedScale)
        }
        return result
    }

    static func roundPolygons(for stroke: Stroke) -> [[SIMD2<Float>]] {
        let radii = radii(for: stroke)
        var result: [[SIMD2<Float>]] = []
        for index in stroke.points.indices {
            let center = stroke.points[index].position
            let radius = radii[index]
            result.append((0..<16).map {
                let angle = Float($0) * 2 * .pi / 16
                return center + SIMD2(cos(angle), sin(angle)) * radius
            })
            guard index > 0 else { continue }
            let previous = stroke.points[index - 1].position
            let delta = center - previous
            guard simd_length(delta) > 0.001 else { continue }
            let normal = simd_normalize(SIMD2<Float>(-delta.y, delta.x))
            result.append([previous + normal * radii[index - 1],
                           previous - normal * radii[index - 1],
                           center - normal * radius, center + normal * radius])
        }
        return result
    }

    // Fixed-distance samples: texture density does not depend on event frequency.
    static func spacedPoints(for stroke: Stroke, spacing: Float) -> [SIMD2<Float>] {
        guard let first = stroke.points.first else { return [] }
        let step = max(0.5, spacing)
        var result = [first.position]
        var toNext = step
        for (a, b) in zip(stroke.points, stroke.points.dropFirst()) {
            let delta = b.position - a.position
            let length = simd_length(delta)
            guard length > 0.001 else { continue }
            var distance = toNext
            while distance <= length {
                result.append(a.position + delta * (distance / length))
                distance += step
            }
            toNext = distance - length
        }
        return result
    }

    static func touches(_ stroke: Stroke, from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float) -> Bool {
        guard let first = stroke.points.first else { return false }
        let reach = radius + stroke.style.width / 2
        if distance(first.position, toSegmentFrom: a, to: b) <= reach { return true }
        for (p, q) in zip(stroke.points, stroke.points.dropFirst()) {
            if segmentDistance(a, b, p.position, q.position) <= reach { return true }
        }
        return false
    }

    private static func distance(_ p: SIMD2<Float>, toSegmentFrom a: SIMD2<Float>, to b: SIMD2<Float>) -> Float {
        let d = b - a
        let lengthSquared = simd_length_squared(d)
        guard lengthSquared > 0.000001 else { return simd_distance(p, a) }
        let t = min(1, max(0, simd_dot(p - a, d) / lengthSquared))
        return simd_distance(p, a + d * t)
    }

    private static func segmentDistance(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Float {
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let ab = b - a, cd = d - c
        let denominator = cross(ab, cd)
        if abs(denominator) > 0.000001 {
            let t = cross(c - a, cd) / denominator
            let u = cross(c - a, ab) / denominator
            if (0...1).contains(t) && (0...1).contains(u) { return 0 }
        }
        return min(min(distance(a, toSegmentFrom: c, to: d), distance(b, toSegmentFrom: c, to: d)),
                   min(distance(c, toSegmentFrom: a, to: b), distance(d, toSegmentFrom: a, to: b)))
    }
}
