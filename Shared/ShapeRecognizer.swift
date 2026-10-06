import Foundation
import simd

/// Geometry-only recognition; does not depend on brush width, color or rendering.
nonisolated enum ShapeRecognizer {
    enum Kind: String { case line, arc, circle, ellipse, rectangle, square, triangle, quadrilateral
        case pentagon, hexagon, regularPolygon, arrow, curvedArrow, blockArrow, cloud, star, heart, speechBubble }
    struct Result {
        let kind: Kind
        let confidence: Float
        let points: [SIMD2<Float>]
        let anchor: SIMD2<Float>
    }
    private struct Candidate {
        let kind: Kind
        let error: Float
        let points: [SIMD2<Float>]
        let anchor: SIMD2<Float>
    }

    static func recognize(_ samples: [PointerSample]) -> Result? {
        guard samples.count >= 3, samples.allSatisfy({ $0.position.x.isFinite && $0.position.y.isFinite }) else { return nil }
        var raw: [SIMD2<Float>] = []
        for sample in samples where raw.last.map({ simd_distance($0, sample.position) > 0.2 }) ?? true {
            raw.append(sample.position)
        }
        guard raw.count >= 3 else { return nil }
        let length = pathLength(raw)
        let minP = raw.reduce(raw[0]) { simd_min($0, $1) }, maxP = raw.reduce(raw[0]) { simd_max($0, $1) }
        let size = maxP - minP, diagonal = simd_length(size)
        guard diagonal >= 12, length >= 16, length < diagonal * 7 else { return nil }
        let points = resample(raw, count: 80)
        let start = raw[0], end = raw[raw.count - 1]
        let closed = simd_distance(start, end) <= max(3, diagonal * 0.18) && length > diagonal * 2
        var candidates: [Candidate] = []

        if !closed {
            let span = simd_distance(start, end)
            if span > diagonal * 0.75, length / max(1, span) < 1.15 {
                let error = rms(points.map { distance($0, start, end) }) / diagonal
                let worst = points.map { distance($0, start, end) }.max() ?? 0
                if error < 0.035, worst < max(2, diagonal * 0.085) {
                    candidates.append(Candidate(kind: .line, error: error, points: [start, end], anchor: start))
                }
            }
            if let arc = arc(points, diagonal: diagonal) { candidates.append(arc) }
            if let curved = curvedArrow(raw, diagonal: diagonal) { candidates.append(curved) }
            if let arrow = arrow(raw.count > 256 ? resample(raw, count: 256) : raw, diagonal: diagonal) { candidates.append(arrow) }
        } else {
            // Explicit closure removes a small hand-drawn seam for polygon fitting.
            var ring = points
            ring[ring.count - 1] = ring[0]
            if let polygon = polygon(ring, diagonal: diagonal) { candidates.append(polygon) }
            if let ellipse = ellipse(points, diagonal: diagonal) { candidates.append(ellipse) }
            candidates += templateCandidates(raw + (raw.last! == raw[0] ? [] : [raw[0]]), diagonal: diagonal)
        }
        let sorted = candidates.sorted { $0.error < $1.error }
        guard let best = sorted.first, best.error < 0.045 else { return nil }
        // Ambiguous curves are preferable to an incorrect snap.
        if let other = sorted.dropFirst().first(where: { $0.kind != best.kind }),
           other.error - best.error < 0.002 { return nil }
        return Result(kind: best.kind, confidence: max(0, 1 - best.error * 4),
                      points: best.points, anchor: best.anchor)
    }

    private static func ellipse(_ p: [SIMD2<Float>], diagonal: Float) -> Candidate? {
        let mean = p.reduce(SIMD2<Float>.zero, +) / Float(p.count)
        var xx: Float = 0, yy: Float = 0, xy: Float = 0
        for point in p { let d = point - mean; xx += d.x * d.x; yy += d.y * d.y; xy += d.x * d.y }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let u = SIMD2<Float>(cos(angle), sin(angle)), v = SIMD2<Float>(-u.y, u.x)
        let local = p.map { SIMD2(simd_dot($0 - mean, u), simd_dot($0 - mean, v)) }
        let low = local.reduce(local[0]) { simd_min($0, $1) }, high = local.reduce(local[0]) { simd_max($0, $1) }
        var radius = (high - low) / 2
        guard min(radius.x, radius.y) >= 5, max(radius.x, radius.y) / min(radius.x, radius.y) < 5 else { return nil }
        let centerLocal = (low + high) / 2
        let center = mean + u * centerLocal.x + v * centerLocal.y
        let isCircle = max(radius.x, radius.y) / min(radius.x, radius.y) < 1.12
        if isCircle { radius = SIMD2(repeating: (radius.x + radius.y) / 2) }
        let radial = p.map { point -> SIMD2<Float> in
            let d = point - center
            return SIMD2(simd_dot(d, u) / radius.x, simd_dot(d, v) / radius.y)
        }
        let errors = radial.map { abs(simd_length($0) - 1) * min(radius.x, radius.y) }
        guard (errors.max() ?? 0) < diagonal * 0.1 else { return nil }
        var winding: Float = 0, absoluteTurn: Float = 0
        for (a, b) in zip(radial, radial.dropFirst()) {
            let turn = atan2(a.x * b.y - a.y * b.x, simd_dot(a, b))
            winding += turn; absoluteTurn += abs(turn)
        }
        guard abs(winding) > 5.2, abs(winding) < 7.2, absoluteTurn < 8 else { return nil }
        let initial = atan2(radial[0].y, radial[0].x)
        let direction: Float = winding >= 0 ? 1 : -1
        let count = min(240, max(48, Int(diagonal * 2)))
        var ideal = (0..<count).map { index -> SIMD2<Float> in
            let t = initial + direction * 2 * .pi * Float(index) / Float(count)
            return center + u * (cos(t) * radius.x) + v * (sin(t) * radius.y)
        }
        ideal.append(ideal[0])
        return Candidate(kind: isCircle ? .circle : .ellipse, error: rms(errors) / diagonal,
                         points: ideal, anchor: center)
    }

    private static func polygon(_ ring: [SIMD2<Float>], diagonal: Float) -> Candidate? {
        // Split the loop at its farthest point before RDP, avoiding identical
        // endpoints. Merge the arbitrary start if it lies in a straight side.
        let split = ring.indices.max { simd_distance(ring[$0], ring[0]) < simd_distance(ring[$1], ring[0]) } ?? 0
        guard split > 0, split < ring.count - 1 else { return nil }
        let tolerance = max(1.2, diagonal * 0.045)
        var corners = Array(simplify(Array(ring[0...split]), tolerance: tolerance).dropLast())
            + Array(simplify(Array(ring[split...]), tolerance: tolerance).dropLast())
        var changed = true
        while changed && corners.count > 3 {
            changed = false
            for i in corners.indices {
                let before = corners[(i + corners.count - 1) % corners.count]
                let after = corners[(i + 1) % corners.count]
                if distance(corners[i], before, after) < tolerance {
                    corners.remove(at: i); changed = true; break
                }
            }
        }
        guard corners.count == 3 || corners.count == 4 else { return nil }
        var crossSign: Float = 0
        for i in corners.indices {
            let a = corners[(i + 1) % corners.count] - corners[i]
            let b = corners[(i + 2) % corners.count] - corners[(i + 1) % corners.count]
            guard simd_length(a) > diagonal * 0.15 else { return nil }
            let cross = a.x * b.y - a.y * b.x
            if crossSign == 0 { crossSign = cross }
            guard cross * crossSign > 0 else { return nil }
        }
        let center = corners.reduce(SIMD2<Float>.zero, +) / Float(corners.count)
        var kind: Kind = .triangle
        if corners.count == 4 {
            let rectangular = corners.indices.allSatisfy { i in
                let a = simd_normalize(corners[(i + 1) % 4] - corners[i])
                let b = simd_normalize(corners[(i + 2) % 4] - corners[(i + 1) % 4])
                return abs(simd_dot(a, b)) < 0.3
            }
            if rectangular {
            let axis = simd_normalize((corners[1] - corners[0]) + (corners[2] - corners[3]))
            let normal = SIMD2<Float>(-axis.y, axis.x)
            let local = corners.map { SIMD2(simd_dot($0 - center, axis), simd_dot($0 - center, normal)) }
            let low = local.reduce(local[0]) { simd_min($0, $1) }, high = local.reduce(local[0]) { simd_max($0, $1) }
            var radius = (high - low) / 2
            let square = max(radius.x, radius.y) / min(radius.x, radius.y) < 1.12
            if square { radius = SIMD2(repeating: (radius.x + radius.y) / 2) }
            corners = local.map { center + axis * ($0.x >= 0 ? radius.x : -radius.x)
                                        + normal * ($0.y >= 0 ? radius.y : -radius.y) }
            kind = square ? .square : .rectangle
            } else { kind = .quadrilateral }
        }
        let ideal = corners + [corners[0]]
        let error = fitError(ring, polyline: ideal)
        guard error.maximum < diagonal * 0.09,
              pathLength(ring) / max(1, pathLength(ideal)) < 1.2 else { return nil }
        return Candidate(kind: kind, error: error.rms / diagonal, points: ideal, anchor: center)
    }

    /// Single-gesture arrows: shaft -> tip -> wing -> tip -> opposite wing.
    private static func arrow(_ points: [SIMD2<Float>], diagonal: Float) -> Candidate? {
        let vertices = simplify(points, tolerance: max(1, diagonal * 0.025))
        guard vertices.count == 5 else { return nil }
        let start = vertices[0], tip = vertices[1]
        let length = simd_distance(start, tip)
        guard length > diagonal * 0.65 else { return nil }
        let axis = (tip - start) / length, normal = SIMD2<Float>(-axis.y, axis.x)
        let wing1 = vertices[2], wing2 = vertices[vertices.count - 1]
        if simd_distance(vertices[3], tip) > length * 0.12 { return nil }
        let a = wing1 - tip, b = wing2 - tip
        let back1 = -simd_dot(a, axis), back2 = -simd_dot(b, axis)
        let side1 = simd_dot(a, normal), side2 = simd_dot(b, normal)
        guard back1 > length * 0.1, back2 > length * 0.1,
              back1 < length * 0.5, back2 < length * 0.5,
              side1 * side2 < 0, min(abs(side1), abs(side2)) > length * 0.06,
              max(abs(side1), abs(side2)) < length * 0.4,
              abs(back1 - back2) < length * 0.15 else { return nil }
        let back = (back1 + back2) / 2, side = (abs(side1) + abs(side2)) / 2
        let sign: Float = side1 > 0 ? 1 : -1
        let firstWing = tip - axis * back + normal * side * sign
        let secondWing = tip - axis * back - normal * side * sign
        let ideal = [start, tip, firstWing, tip, secondWing]
        let error = fitError(points, polyline: ideal)
        guard error.maximum < diagonal * 0.09 else { return nil }
        return Candidate(kind: .arrow, error: error.rms / diagonal, points: ideal, anchor: start)
    }


    /// Fit an open circular arc, preserving direction and rejecting reversals.
    private static func arc(_ p: [SIMD2<Float>], diagonal: Float) -> Candidate? {
        let a = p[0], b = p[p.count / 2], c = p[p.count - 1]
        let u = b - a, v = c - a
        let determinant = 2 * (u.x * v.y - u.y * v.x)
        guard abs(determinant) > diagonal * diagonal * 0.04 else { return nil }
        let uu = simd_length_squared(u), vv = simd_length_squared(v)
        let center = a + SIMD2((v.y * uu - u.y * vv) / determinant,
                              (u.x * vv - v.x * uu) / determinant)
        let radius = simd_distance(a, center)
        let errors = p.map { abs(simd_distance($0, center) - radius) }
        var sweep: Float = 0, total: Float = 0
        for (a, b) in zip(p, p.dropFirst()) {
            let x = a - center, y = b - center
            let turn = atan2(x.x * y.y - x.y * y.x, simd_dot(x, y))
            sweep += turn; total += abs(turn)
        }
        guard abs(sweep) > 0.45, abs(sweep) < 5.5, total < abs(sweep) + 0.2,
              (errors.max() ?? 0) < diagonal * 0.065,
              rms(errors) < diagonal * 0.025 else { return nil }
        let initial = atan2(a.y - center.y, a.x - center.x)
        let ideal = (0...80).map { i -> SIMD2<Float> in
            let t = initial + sweep * Float(i) / 80
            return center + SIMD2(cos(t), sin(t)) * radius
        }
        return Candidate(kind: .arc, error: rms(errors) / diagonal, points: ideal, anchor: a)
    }

    private static func curvedArrow(_ p: [SIMD2<Float>], diagonal: Float) -> Candidate? {
        let vertices = simplify(p, tolerance: max(1, diagonal * 0.025))
        guard vertices.count >= 6 else { return nil }
        let tip = vertices[vertices.count - 4]
        guard let index = p.indices.first(where: { simd_distance(p[$0], tip) < 0.01 }), index >= 3,
              let shaft = arc(resample(Array(p[...index]), count: 80), diagonal: diagonal) else { return nil }
        let tangent = simd_normalize(shaft.points.last! - shaft.points[shaft.points.count - 3])
        let length = pathLength(shaft.points)
        let fakeStart = tip - tangent * length
        let head = [fakeStart] + Array(vertices.suffix(4))
        guard let fitted = arrow(head, diagonal: length) else { return nil }
        let ideal = shaft.points + fitted.points.dropFirst(2)
        let error = fitError(p, polyline: Array(ideal))
        guard error.maximum < diagonal * 0.075 else { return nil }
        return Candidate(kind: .curvedArrow, error: error.rms / diagonal,
                         points: Array(ideal), anchor: p[0])
    }

    /// Closed outlines are matched in stroke order, in both directions and at
    /// every seam. A similarity fit allows translation, rotation and uniform scale.
    /// Ordered distance prevents a scribble crossing a template from snapping.
    private static func templateCandidates(_ ring: [SIMD2<Float>], diagonal: Float) -> [Candidate] {
        let count = 64
        let input = Array(resample(ring, count: count + 1).dropLast())
        let center = input.reduce(.zero, +) / Float(count)
        let centered = input.map { $0 - center }
        var results: [Candidate] = []
        let split = ring.indices.max { simd_distance(ring[$0], ring[0]) < simd_distance(ring[$1], ring[0]) } ?? 0
        var vertices = Array(simplify(Array(ring[...split]), tolerance: diagonal * 0.009).dropLast())
            + Array(simplify(Array(ring[split...]), tolerance: diagonal * 0.009).dropLast())
        var removed = true
        while removed && vertices.count > 3 {
            removed = false
            for i in vertices.indices {
                let previous = vertices[(i + vertices.count - 1) % vertices.count]
                let next = vertices[(i + 1) % vertices.count]
                if distance(vertices[i], previous, next) < diagonal * 0.009 {
                    vertices.remove(at: i)
                    removed = true
                    break
                }
            }
        }
        for (kind, outline) in outlines {
            if [.pentagon, .hexagon, .regularPolygon].contains(kind), vertices.count != outline.count - 1 { continue }
            let template = Array(resample(outline, count: count + 1).dropLast())
            let mean = template.reduce(SIMD2<Float>.zero, +) / Float(count)
            let base = template.map { $0 - mean }
            let energy = base.reduce(Float(0)) { $0 + simd_length_squared($1) }
            var best: Candidate?
            for direction in [-1, 1] {
                for offset in 0..<count {
                    let ordered = (0..<count).map { base[(offset + direction * $0 + count) % count] }
                    var dot: Float = 0, cross: Float = 0
                    for (a, b) in zip(ordered, centered) {
                        dot += simd_dot(a, b); cross += a.x * b.y - a.y * b.x
                    }
                    let x = dot / energy, y = cross / energy
                    var ideal = ordered.map { center + SIMD2(x * $0.x - y * $0.y, y * $0.x + x * $0.y) }
                    let errors = zip(input, ideal).map { simd_distance($0, $1) }
                    let error = rms(errors) / diagonal
                    guard error < 0.035, (errors.max() ?? 0) < diagonal * 0.085,
                          best == nil || error < best!.error else { continue }
                    ideal.append(ideal[0])
                    best = Candidate(kind: kind, error: error, points: ideal, anchor: center)
                }
            }
            if let best { results.append(best) }
        }
        return results
    }

    private static let outlines: [(Kind, [SIMD2<Float>])] = {
        var result: [(Kind, [SIMD2<Float>])] = []
        func closed(_ kind: Kind, _ p: [SIMD2<Float>]) { result.append((kind, p + [p[0]])) }
        // Beyond twelve sides small watch strokes are indistinguishable from circles.
        for n in 5...12 {
            let p = (0..<n).map { i -> SIMD2<Float> in
                let t = Float(i) * 2 * .pi / Float(n)
                return SIMD2(cos(t), sin(t))
            }
            closed(n == 5 ? .pentagon : n == 6 ? .hexagon : .regularPolygon, p)
        }
        for inner: Float in [0.4, 0.5, 0.6] {
            closed(.star, (0..<10).map { i in
                let t = Float(i) * .pi / 5 - .pi / 2
                return SIMD2(cos(t), sin(t)) * (i.isMultiple(of: 2) ? 1 : inner)
            })
        }
        closed(.heart, (0..<128).map { i in
            let t = Float(i) * 2 * .pi / 128
            let x = 16 * pow(sin(t), 3)
            let y = -(13 * cos(t) - 5 * cos(2*t) - 2 * cos(3*t) - cos(4*t))
            return SIMD2(x / 16, y / 16)
        })
        for lobes in [5, 6, 7, 8] {
            closed(.cloud, (0..<160).map { i in
                let t = Float(i) * 2 * .pi / 160
                let r: Float = 1 + 0.14 * cos(Float(lobes) * t)
                return SIMD2(cos(t) * r * 1.4, sin(t) * r)
            })
        }
        closed(.blockArrow, [SIMD2(-1,-0.3), SIMD2(0.2,-0.3), SIMD2(0.2,-0.7),
                             SIMD2(1,0), SIMD2(0.2,0.7), SIMD2(0.2,0.3), SIMD2(-1,0.3)])
        closed(.speechBubble, [SIMD2(-1,-0.7), SIMD2(1,-0.7), SIMD2(1,0.5),
                               SIMD2(0.2,0.5), SIMD2(-0.5,1), SIMD2(-0.4,0.5), SIMD2(-1,0.5)])
        var bubble = (0...100).map { i -> SIMD2<Float> in
            let t = Float(i) * (2 * .pi - 0.4) / 100 + 1.1
            return SIMD2(cos(t) * 1.4, sin(t))
        }
        bubble.append(SIMD2(0.1,1.65))
        closed(.speechBubble, bubble)
        return result
    }()

    private static func fitError(_ p: [SIMD2<Float>], polyline: [SIMD2<Float>]) -> (rms: Float, maximum: Float) {
        let errors = p.map { point in
            zip(polyline, polyline.dropFirst()).map { distance(point, $0.0, $0.1) }.min() ?? .infinity
        }
        return (rms(errors), errors.max() ?? .infinity)
    }
    private static func rms(_ values: [Float]) -> Float { sqrt(values.reduce(0) { $0 + $1 * $1 } / Float(max(1, values.count))) }
    private static func pathLength(_ p: [SIMD2<Float>]) -> Float { zip(p, p.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
    private static func distance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = b - a, length = simd_length_squared(d)
        guard length > 0.000001 else { return simd_distance(p, a) }
        return simd_distance(p, a + d * min(1, max(0, simd_dot(p - a, d) / length)))
    }
    private static func simplify(_ p: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
        guard p.count > 2 else { return p }
        var best: Float = 0, index = 0
        for i in 1..<(p.count - 1) {
            let error = distance(p[i], p[0], p[p.count - 1])
            if error > best { best = error; index = i }
        }
        guard best > tolerance else { return [p[0], p[p.count - 1]] }
        return Array(simplify(Array(p[0...index]), tolerance: tolerance).dropLast())
            + simplify(Array(p[index...]), tolerance: tolerance)
    }
    private static func resample(_ points: [SIMD2<Float>], count: Int) -> [SIMD2<Float>] {
        let step = pathLength(points) / Float(count - 1)
        guard step > 0 else { return points }
        var result = [points[0]], remaining = step
        for (a, b) in zip(points, points.dropFirst()) {
            let delta = b - a, length = simd_length(delta)
            guard length > 0 else { continue }
            var consumed: Float = 0
            while remaining <= length - consumed, result.count < count - 1 {
                consumed += remaining
                result.append(a + delta * (consumed / length))
                remaining = step
            }
            remaining -= length - consumed
        }
        result.append(points[points.count - 1])
        return result
    }
}
