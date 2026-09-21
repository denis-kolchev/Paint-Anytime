import Foundation
import simd

// A fixed elliptical calligraphy nib, swept along the stroke.
// This is our own approximation, not Apple's PencilKit ink engine.
enum FountainPenGeometry {
    static func polygons(for stroke: Stroke) -> [[SIMD2<Float>]] {
        let major = max(stroke.style.width, 0.1) / 2
        let minor = major * (stroke.style.instrument == .reed ? 0.12 : 0.24)
        let angle = stroke.style.instrument == .reed ? stroke.style.reedAngle * .pi / 180 : -.pi / 4
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        let cross = SIMD2<Float>(-axis.y, axis.x)
        let roundedNib = (0..<20).map { index -> SIMD2<Float> in
            let angle = Float(index) * 2 * .pi / 20
            return axis * (cos(angle) * major) + cross * (sin(angle) * minor)
        }
        let nib = stroke.style.instrument == .reed
            ? [axis * major + cross * minor, -axis * major + cross * minor,
               -axis * major - cross * minor, axis * major - cross * minor]
            : roundedNib
        var polygons = stroke.points.map { sample in
            nib.map { sample.position + $0 }
        }
        for (a, b) in zip(stroke.points, stroke.points.dropFirst()) {
            let delta = b.position - a.position
            guard simd_length(delta) > 0.001 else { continue }
            let normal = simd_normalize(SIMD2<Float>(-delta.y, delta.x))
            let u = simd_dot(normal, axis)
            let v = simd_dot(normal, cross)
            let denominator = sqrt(major * major * u * u + minor * minor * v * v)
            let offset: SIMD2<Float>
            if stroke.style.instrument == .reed {
                offset = axis * (u >= 0 ? major : -major) + cross * (v >= 0 ? minor : -minor)
            } else {
                offset = (axis * (major * major * u) + cross * (minor * minor * v)) / denominator
            }
            polygons.append([a.position + offset, a.position - offset,
                             b.position - offset, b.position + offset])
        }
        return polygons
    }
}
