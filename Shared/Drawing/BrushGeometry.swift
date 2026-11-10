import Foundation
import CoreGraphics
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

    /// Largest change of the pen radius per point of travel (taper of about 11°).
    static let penRadiusSlope: Float = 0.2
    /// Pen width scale at rest and at high speed.
    static let penSlowScale: Float = 1, penFastScale: Float = 0.28
    /// Time span over which pen speed is averaged; longer than several input events,
    /// so uneven event spacing does not read as changes of speed.
    static let penSpeedWindow: TimeInterval = 0.08
    /// Width scale before any speed is known: a tap, or the first input event.
    static let penOpeningScale: Float = 0.55

    /// Once the stroke spans `penSpeedWindow`, its opening width is final and every
    /// radius depends only on earlier samples: drawn ink may be extended, not redrawn.
    static func penRadiiSettled(_ stroke: Stroke) -> Bool {
        guard let first = stroke.points.first, let last = stroke.points.last else { return false }
        return last.timestamp - first.timestamp >= penSpeedWindow
    }

    static func penScale(speed: Float) -> Float {
        penFastScale + (penSlowScale - penFastScale) / (1 + speed / 150)
    }

    static func radii(for stroke: Stroke) -> [Float] {
        let base = max(0.1, stroke.style.width) / 2
        let points = stroke.points
        guard stroke.style.instrument == .pen else {
            return Array(repeating: base, count: points.count)
        }
        guard !points.isEmpty else { return [] }
        // Cumulative travel, for windowed speed.
        var traveled = [Float](repeating: 0, count: points.count)
        for index in points.indices.dropFirst() {
            traveled[index] = traveled[index - 1]
                + simd_distance(points[index - 1].position, points[index].position)
        }
        // The width follows speed along the path, not in time: it changes only while
        // the pen travels, so slowing at corners, before lifting or while resting
        // cannot swell the line into a blob. A longer length also absorbs the
        // remaining speed jitter of a slow, steady hand.
        let smoothingLength = max(4, base * 1.5)
        // Start at the width of the opening speed: the average over the first
        // `penSpeedWindow` of the stroke (or all of it while younger). A quick stroke
        // starts thin and a slow one starts wide, with no growing or shrinking head.
        // Only this opening estimate looks ahead; it settles after the window, and
        // the active stroke is replayed whole, so live and committed ink agree.
        var scale = penOpeningScale
        let first = points[0]
        let opening = points.firstIndex { $0.timestamp - first.timestamp >= penSpeedWindow }
            ?? points.count - 1
        do {
            // Measure over the window's second half: the first touch is still
            // accelerating from rest and would read too slow, i.e. too wide.
            var from = points.firstIndex { $0.timestamp - first.timestamp >= penSpeedWindow / 2 } ?? 0
            if from >= opening { from = 0 }
            let span = points[opening].timestamp - points[from].timestamp
            let length = traveled[opening] - traveled[from]
            if span.isFinite && span > 0.0001 && length > 0 {
                scale = penScale(speed: length / Float(span))
            }
        }
        var radius = base * scale
        var result: [Float] = []
        result.reserveCapacity(points.count)
        var windowStart = 0
        for index in points.indices {
            if index > 0 {
                let distance = traveled[index] - traveled[index - 1]
                // Average speed over the last `penSpeedWindow` of input. Duplicate or
                // missing timestamps leave the target unchanged rather than spiking it.
                let now = points[index].timestamp
                while windowStart < index - 1, now - points[windowStart + 1].timestamp >= penSpeedWindow {
                    windowStart += 1
                }
                let span = now - points[windowStart].timestamp
                // Inside the opening window the running speed still includes the
                // start from rest; the opening width already stands for it.
                if index > opening && span.isFinite && span > 0.0001 && distance > 0 {
                    let speed = (traveled[index] - traveled[windowStart]) / Float(span)
                    scale += (penScale(speed: speed) - scale) * (1 - exp(-distance / smoothingLength))
                }
                // Safety bound on the taper; a slope below 1 keeps every disc inside
                // its neighbours' outline, leaving round ends only at the caps.
                // After the opening window earlier radii never change as the stroke
                // grows, so the live stroke, the ink tip, the committed stroke and
                // saved output agree.
                let step = distance * penRadiusSlope
                radius = min(radius + step, max(radius - step, base * scale))
            }
            result.append(radius)
        }
        return result
    }

    static func roundPath(for stroke: Stroke) -> CGPath {
        roundPath(points: stroke.points.map(\.position), radii: radii(for: stroke))
    }

    /// Discs at each point joined by quads. The live ink tip passes only the stroke's
    /// tail with radii computed over the whole stroke, so widths match the renderer.
    /// Discs are true arcs, as in a round line cap: a fixed polygon showed facets on
    /// wide pens. Discs and quads share one winding, so nonzero filling has no holes.
    /// `skipsFirstDisc`: the first point's disc is already drawn (an appended batch).
    static func roundPath(points: [SIMD2<Float>], radii: [Float], skipsFirstDisc: Bool = false) -> CGPath {
        func cg(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }
        let path = CGMutablePath()
        for index in points.indices {
            let center = points[index]
            let radius = radii[index]
            if !(skipsFirstDisc && index == points.startIndex) {
                path.move(to: cg(center + SIMD2(radius, 0)))
                path.addArc(center: cg(center), radius: CGFloat(radius),
                            startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                path.closeSubpath()
            }
            guard index > points.startIndex else { continue }
            let previous = points[index - 1]
            let delta = center - previous
            guard simd_length(delta) > 0.001 else { continue }
            let normal = simd_normalize(SIMD2<Float>(-delta.y, delta.x))
            path.addLines(between: [cg(previous + normal * radii[index - 1]),
                                    cg(previous - normal * radii[index - 1]),
                                    cg(center - normal * radius), cg(center + normal * radius)])
            path.closeSubpath()
        }
        return path
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
        if stroke.transform != .identity {
            let inverse = stroke.transform.affine.inverted()
            let p = CGPoint(x: CGFloat(a.x), y: CGFloat(a.y)).applying(inverse)
            let q = CGPoint(x: CGFloat(b.x), y: CGFloat(b.y)).applying(inverse)
            var source = stroke
            source.transform = .identity
            let reach = radius * Float(max(hypot(inverse.a, inverse.b), hypot(inverse.c, inverse.d)))
            return touches(source, from: SIMD2(Float(p.x), Float(p.y)), to: SIMD2(Float(q.x), Float(q.y)), radius: reach)
        }
        if let raster = stroke.raster {
            let area = raster.bounds.insetBy(dx: -CGFloat(radius), dy: -CGFloat(radius))
            let path = CGRect(x: CGFloat(min(a.x, b.x)), y: CGFloat(min(a.y, b.y)),
                              width: CGFloat(abs(b.x - a.x)) + 0.001, height: CGFloat(abs(b.y - a.y)) + 0.001)
            return area.intersects(path)
        }
        if stroke.style.instrument == .fill {
            return (stroke.fillRects ?? []).contains { rect in
                let lo = SIMD2(rect.x, rect.y), hi = lo + SIMD2(rect.z, rect.w)
                if a.x >= lo.x && a.x <= hi.x && a.y >= lo.y && a.y <= hi.y { return true }
                if b.x >= lo.x && b.x <= hi.x && b.y >= lo.y && b.y <= hi.y { return true }
                let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
                return (0..<4).contains {
                    segmentDistance(a, b, corners[$0], corners[($0 + 1) % 4]) <= radius
                }
            }
        }
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
