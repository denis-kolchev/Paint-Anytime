import Foundation
import simd

// Input-dependent geometry shared independently of the display technology.
nonisolated enum BrushGeometry {
    // Refine the nib over a short opening distance, independent of event frequency.
    // Later turns keep this orientation, so the nib can still travel on its edge.
    static func markerOrientation(for stroke: Stroke) -> (direction: SIMD2<Float>?, settled: Bool) {
        guard let first = stroke.points.first else { return (nil, false) }
        let window = max(8, min(24, stroke.style.width * 1.25))
        var traveled: Float = 0
        var endpoint = first.position
        for (a, b) in zip(stroke.points, stroke.points.dropFirst()) {
            let delta = b.position - a.position
            let length = simd_length(delta)
            guard length > 0.000001 else { continue }
            let remaining = window - traveled
            endpoint = a.position + delta * min(1, remaining / length)
            traveled += min(remaining, length)
            if traveled >= window { break }
        }
        let delta = endpoint - first.position
        guard simd_length(delta) >= 0.5 else { return (nil, false) }
        // Rectangle orientation is periodic over pi; take the shortest rotation
        // from the horizontal resting footprint, easing in over the first 4 pt.
        var angle = atan2(delta.y, delta.x) - Float.pi / 2
        if angle > .pi / 2 { angle -= .pi }
        if angle < -.pi / 2 { angle += .pi }
        let progress = min(1, traveled / 4)
        let eased = progress * progress * (3 - 2 * progress)
        let rotation = Float.pi / 2 + angle * eased
        let direction = progress >= 1 ? simd_normalize(delta) : SIMD2(cos(rotation), sin(rotation))
        return (direction, traveled >= window)
    }

    static func markerDirection(for stroke: Stroke) -> SIMD2<Float>? {
        markerOrientation(for: stroke).direction
    }

    static func markerNib(at center: SIMD2<Float>, width: Float,
                          direction: SIMD2<Float>) -> [SIMD2<Float>] {
        let halfWidth = max(0.1, width) / 2
        let across = SIMD2(-direction.y, direction.x) * halfWidth
        let along = direction * halfWidth * 0.2
        return [center + across + along, center - across + along,
                center - across - along, center + across - along]
    }

    // Convex hull of the two nib footprints is the exact swept rectangle.
    static func markerSegment(from a: SIMD2<Float>, to b: SIMD2<Float>, width: Float,
                              direction: SIMD2<Float>) -> [SIMD2<Float>] {
        let points = (markerNib(at: a, width: width, direction: direction)
                    + markerNib(at: b, width: width, direction: direction)).sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }
        func half(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var hull: [SIMD2<Float>] = []
            for p in points {
                while hull.count >= 2 {
                    let u = hull[hull.count - 1] - hull[hull.count - 2]
                    let v = p - hull[hull.count - 1]
                    if u.x * v.y - u.y * v.x > 0 { break }
                    hull.removeLast()
                }
                hull.append(p)
            }
            return hull
        }
        return Array(half(points).dropLast()) + Array(half(points.reversed()).dropLast())
    }

    static func markerPolygons(for stroke: Stroke) -> [[SIMD2<Float>]] {
        guard let first = stroke.points.first else { return [] }
        guard let direction = markerDirection(for: stroke) else {
            return [markerNib(at: first.position, width: stroke.style.width, direction: SIMD2(0, 1))]
        }
        return zip(stroke.points, stroke.points.dropFirst()).map {
            markerSegment(from: $0.position, to: $1.position, width: stroke.style.width, direction: direction)
        }
    }

    // A pencil follows the local tangent: constant width through turns, flat
    // terminal cuts, and round joins only inside the stroke (never round caps).
    static func pencilPolygons(for stroke: Stroke) -> [[SIMD2<Float>]] {
        guard let first = stroke.points.first else { return [] }
        var points = [first.position]
        for sample in stroke.points.dropFirst() {
            if simd_distance(points[points.count - 1], sample.position) > 0.001 {
                points.append(sample.position)
            }
        }
        guard points.count > 1 else {
            let r = min(3, max(0.1, stroke.style.width)) / 2
            let p = first.position
            return [[p + SIMD2(-r, -r), p + SIMD2(r, -r),
                     p + SIMD2(r, r), p + SIMD2(-r, r)]]
        }
        let radius = max(0.1, stroke.style.width) / 2
        var polygons: [[SIMD2<Float>]] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let tangent = simd_normalize(b - a)
            let normal = SIMD2(-tangent.y, tangent.x) * radius
            polygons.append([a + normal, a - normal, b - normal, b + normal])
        }
        for index in 1..<(points.count - 1) {
            let center = points[index]
            let incoming = simd_normalize(center - points[index - 1])
            let outgoing = simd_normalize(points[index + 1] - center)
            let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
            let turn = atan2(cross, simd_dot(incoming, outgoing))
            guard abs(turn) > 0.0001 else { continue }
            let side: Float = turn > 0 ? -1 : 1
            let normal = SIMD2(-incoming.y, incoming.x) * side
            let startAngle = atan2(normal.y, normal.x)
            let steps = max(1, Int(ceil(abs(turn) / (.pi / 10))))
            // Fill only the outside corner. Full disks at nearby input samples
            // would protrude beyond the terminal cuts and round the ends again.
            var join = [center]
            for step in 0...steps {
                let angle = startAngle + turn * Float(step) / Float(steps)
                join.append(center + SIMD2(cos(angle), sin(angle)) * radius)
            }
            polygons.append(join)
        }
        return polygons
    }

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
