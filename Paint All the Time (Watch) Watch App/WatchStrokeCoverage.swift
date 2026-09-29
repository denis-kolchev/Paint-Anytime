import Accelerate
import SwiftUI
import simd

/// Append-only coverage for one gesture. Pigment is composited against the original
/// backdrop, never against the previous frame, so retracing does not darken a stroke.
nonisolated final class WatchStrokeCoverage {
    struct Geometry {
        var primitives: [(path: Path, band: Int)] = []
        var endCap: Path?
        var bounds: CGRect {
            primitives.reduce(endCap?.boundingRect ?? .null) { $0.union($1.path.boundingRect) }
        }
    }

    // Recording uses the exact same primitive generator as live coverage, but no raster work.
    private var recordedGeometry: Geometry?

    static func geometry(for stroke: Stroke) throws -> Geometry {
        let recorder = WatchStrokeCoverage(style: stroke.style, width: 1, height: 1, scale: 1)
        recorder.recordedGeometry = Geometry()
        _ = try recorder.append(stroke)
        return recorder.recordedGeometry!
    }

    func replay(_ geometry: Geometry) throws -> CGRect {
        var dirty = CGRect.null
        for primitive in geometry.primitives {
            dirty = dirty.union(try merge(primitive.path, band: primitive.band))
        }
        if let cap = geometry.endCap {
            endCap = try patch(cap)
            dirty = dirty.union(endCap?.rect ?? .null)
        }
        return dirty
    }

    enum RenderError: Error { case allocation }

    let style: PencilStyle
    let width: Int
    let height: Int
    private let scale: CGFloat
    private let masks: [UnsafeMutablePointer<Float>]
    private let scratch: UnsafeMutablePointer<Float>
    private var distanceToNext: Float
    private var stampIndex = 0
    private(set) var processedPointCount = 0
    private(set) var lastProcessedPoint: PointerSample?
    private var firstPoint: PointerSample?
    private var markerHasSegment = false
    private var endCap: Patch?
    private(set) var rasterizedPrimitiveCount = 0

    private struct Patch {
        let context: CGContext
        // Integer pixel coordinates in bitmap row order (top to bottom).
        let rect: CGRect
        var pixels: UnsafeMutablePointer<Float> { context.data!.assumingMemoryBound(to: Float.self) }
        var stride: Int { context.bytesPerRow / MemoryLayout<Float>.stride }
    }

    init(style: PencilStyle, width: Int, height: Int, scale: CGFloat) {
        self.style = style
        self.width = width
        self.height = height
        self.scale = scale
        distanceToNext = max(0.5, style.width * 0.12)
        masks = (0..<(style.instrument == .watercolor ? 6 : 1)).map { _ in
            let pixels = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
            pixels.initialize(repeating: 0, count: width * height)
            return pixels
        }
        scratch = .allocate(capacity: width * 5)
        scratch.initialize(repeating: 0, count: width * 5)
    }

    deinit {
        for mask in masks { mask.deallocate() }
        scratch.deallocate()
    }

    func canAppend(_ stroke: Stroke) -> Bool {
        guard stroke.style == style, stroke.points.count >= processedPointCount else { return false }
        guard processedPointCount > 0 else { return true }
        return stroke.points.first == firstPoint && stroke.points[processedPointCount - 1] == lastProcessedPoint
    }

    /// Returns only the changed rectangle. Event batches and full replay use the same
    /// primitive order, making live drawing, stroke completion, and export agree.
    func append(_ stroke: Stroke) throws -> CGRect {
        var dirty = CGRect.null
        guard stroke.points.count > processedPointCount else { return dirty }
        if processedPointCount == 0 { firstPoint = stroke.points.first }
        if style.instrument == .watercolor {
            if processedPointCount == 0, let first = stroke.points.first {
                dirty = dirty.union(try stamp(at: first.position))
            }
            for index in max(1, processedPointCount)..<stroke.points.count {
                let a = stroke.points[index - 1].position
                let delta = stroke.points[index].position - a
                let length = simd_length(delta)
                guard length > 0.001 else { continue }
                var distance = distanceToNext
                while distance <= length {
                    dirty = dirty.union(try stamp(at: a + delta * (distance / length)))
                    distance += max(0.5, style.width * 0.12)
                }
                distanceToNext = distance - length
            }
        } else {
            // A square endpoint moves as the gesture grows. Keep it separate from
            // permanent coverage so yesterday's cap never becomes a bulge at a bend.
            dirty = dirty.union(endCap?.rect ?? .null)
            for index in max(1, processedPointCount)..<stroke.points.count {
                let a = stroke.points[index - 1].position
                let b = stroke.points[index].position
                let delta = b - a
                guard simd_length(delta) > 0.001 else { continue }
                let direction = simd_normalize(delta)
                let radius = style.width / 2
                let normal = SIMD2(-direction.y, direction.x) * radius
                let start = markerHasSegment ? a : a - direction * radius
                var segment = Path()
                segment.move(to: point(start + normal))
                segment.addLine(to: point(start - normal))
                segment.addLine(to: point(b - normal))
                segment.addLine(to: point(b + normal))
                segment.closeSubpath()
                if markerHasSegment {
                    let joint = Path(ellipseIn: CGRect(x: CGFloat(a.x - radius), y: CGFloat(a.y - radius),
                                                       width: CGFloat(radius * 2), height: CGFloat(radius * 2)))
                    dirty = dirty.union(try merge(joint, band: 0))
                }
                dirty = dirty.union(try merge(segment, band: 0))
                markerHasSegment = true
                endCap = try patch(cap(at: b, direction: direction))
            }
            if !markerHasSegment, let first = stroke.points.first {
                let radius = CGFloat(style.width) / 2
                endCap = try patch(Path(CGRect(x: CGFloat(first.position.x) - radius,
                                              y: CGFloat(first.position.y) - radius,
                                              width: radius * 2, height: radius * 2)))
            }
            dirty = dirty.union(endCap?.rect ?? .null)
        }
        processedPointCount = stroke.points.count
        lastProcessedPoint = stroke.points.last
        return dirty
    }

    private func stamp(at position: SIMD2<Float>) throws -> CGRect {
        var dirty = CGRect.null
        for band in 0..<6 {
            let r = WatchStrokeDrawing.watercolorRadius(width: style.width, band: band, index: stampIndex)
            let shape = Path(ellipseIn: CGRect(x: Double(position.x) - r, y: Double(position.y) - r,
                                               width: r * 2, height: r * 2))
            dirty = dirty.union(try merge(shape, band: band))
        }
        stampIndex += 1
        return dirty
    }

    private func cap(at p: SIMD2<Float>, direction: SIMD2<Float>) -> Path {
        let radius = style.width / 2
        let normal = SIMD2(-direction.y, direction.x) * radius
        let start = p - direction * radius
        let end = p + direction * radius
        var path = Path()
        // Overlap the segment by half a width; abutting antialiased masks would
        // otherwise leave a faint seam at the moving endpoint.
        path.move(to: point(start + normal))
        path.addLine(to: point(start - normal))
        path.addLine(to: point(end - normal))
        path.addLine(to: point(end + normal))
        path.closeSubpath()
        return path
    }

    private func point(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }

    private func patch(_ path: Path) throws -> Patch? {
        if recordedGeometry != nil {
            recordedGeometry?.endCap = path
            return nil
        }
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: CGFloat(height))
        let bounds = path.boundingRect.applying(transform).insetBy(dx: -1, dy: -1).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !bounds.isNull, !bounds.isEmpty else { return nil }
        guard let context = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                                      bitsPerComponent: 32, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              context.data != nil else { throw RenderError.allocation }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(transform)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path.cgPath)
        context.fillPath()
        rasterizedPrimitiveCount += 1
        return Patch(context: context,
                     rect: CGRect(x: bounds.minX, y: CGFloat(height) - bounds.maxY,
                                  width: bounds.width, height: bounds.height))
    }

    private func merge(_ path: Path, band: Int) throws -> CGRect {
        if recordedGeometry != nil {
            recordedGeometry?.primitives.append((path, band))
            return .null
        }
        guard let patch = try patch(path) else { return .null }
        let rect = patch.rect
        for row in 0..<Int(rect.height) {
            let destination = masks[band] + (Int(rect.minY) + row) * width + Int(rect.minX)
            // Maximum coverage preserves opacity at intersections, including antialiased edges.
            vDSP_vmax(destination, 1, patch.pixels + row * patch.stride, 1,
                      destination, 1, vDSP_Length(rect.width))
        }
        return rect
    }

    /// Evaluate the hybrid formula directly in premultiplied RGBA. Native vector
    /// operations avoid unoptimized per-channel loops in Debug as well as Release.
    /// `base` may equal `output` during full replay; live frames use an immutable base.
    func composite(dirty rect: CGRect, over base: CGContext, into output: CGContext) {
        guard !rect.isNull, !rect.isEmpty, let baseData = base.data, let outputData = output.data else { return }
        let basePixels = baseData.assumingMemoryBound(to: Float.self)
        let outputPixels = outputData.assumingMemoryBound(to: Float.self)
        let baseStride = base.bytesPerRow / MemoryLayout<Float>.stride
        let outputStride = output.bytesPerRow / MemoryLayout<Float>.stride
        let count = Int(rect.width)
        let n = vDSP_Length(count)
        let alpha = scratch
        let temporary = scratch + width
        let sourceFactor = scratch + width * 2
        let coefficient = scratch + width * 3
        let transmission = scratch + width * 4
        var one: Float = 1
        var minusOne: Float = -1
        var minusK: Float = -0.8
        let bandOpacity = Float(1 - pow(1 - 0.7, 1.0 / 6))
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let x = Int(rect.minX)
            let offset = y * width + x
            if style.instrument == .watercolor {
                vDSP_vfill(&one, transmission, 1, n)
                var negativeOpacity = -bandOpacity
                for mask in masks {
                    vDSP_vsmsa(mask + offset, 1, &negativeOpacity, &one, temporary, 1, n)
                    vDSP_vmul(transmission, 1, temporary, 1, transmission, 1, n)
                }
                vDSP_vsmsa(transmission, 1, &minusOne, &one, alpha, 1, n)
            } else {
                alpha.update(from: masks[0] + offset, count: count)
                if let cap = endCap, y >= Int(cap.rect.minY), y < Int(cap.rect.maxY) {
                    let lo = max(x, Int(cap.rect.minX))
                    let hi = min(Int(rect.maxX), Int(cap.rect.maxX))
                    if hi > lo {
                        vDSP_vmax(alpha + lo - x, 1,
                                  cap.pixels + (y - Int(cap.rect.minY)) * cap.stride + lo - Int(cap.rect.minX), 1,
                                  alpha + lo - x, 1, vDSP_Length(hi - lo))
                    }
                }
                var opacity: Float = 0.7
                vDSP_vsmul(alpha, 1, &opacity, alpha, 1, n)
            }
            var inkAlpha = style.color.w
            vDSP_vsmul(alpha, 1, &inkAlpha, alpha, 1, n)
            let backdrop = basePixels + y * baseStride + x * 4
            let destination = outputPixels + y * outputStride + x * 4
            // For premultiplied D with alpha Ad:
            // C = D(1-a+akS) + aS(1-kAd); Ac = Ad + a(1-Ad).
            vDSP_vsmsa(backdrop + 3, 4, &minusK, &one, sourceFactor, 1, n)
            vDSP_vmul(alpha, 1, sourceFactor, 1, sourceFactor, 1, n)
            for channel in 0..<3 {
                var source = style.color[channel]
                var factor = 0.8 * source - 1
                vDSP_vsmsa(alpha, 1, &factor, &one, coefficient, 1, n)
                vDSP_vmul(backdrop + channel, 4, coefficient, 1, destination + channel, 4, n)
                vDSP_vsma(sourceFactor, 1, &source, destination + channel, 4, destination + channel, 4, n)
            }
            vDSP_vsmsa(backdrop + 3, 4, &minusOne, &one, coefficient, 1, n)
            vDSP_vmul(alpha, 1, coefficient, 1, coefficient, 1, n)
            vDSP_vadd(backdrop + 3, 4, coefficient, 1, destination + 3, 4, n)
        }
    }
}
