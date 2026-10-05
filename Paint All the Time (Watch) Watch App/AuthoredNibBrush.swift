import Foundation
import CoreGraphics
import ImageIO
import simd

/// A continuous swept path reveals an authored bitmap field. No texture stamping.
nonisolated enum AuthoredNibBrush {
    struct Sweep: Equatable {
        let start: SIMD2<Double>
        let startAngle: Double
        let startSource: SIMD2<Double>
        let center: SIMD2<Double>
        let angle: Double
        let width: Double
        let length: Double
        let source: SIMD2<Double>
        let textureScale: Double
        var bounds: CGRect {
            let radius = width / 2
            return CGRect(x: min(start.x, center.x) - radius,
                          y: min(start.y, center.y) - radius,
                          width: abs(center.x - start.x) + radius * 2,
                          height: abs(center.y - start.y) + radius * 2)
        }
    }

    struct Mask: Sendable {
        let width: Int
        let height: Int
        let coverage: [UInt8]

        init?(name: String) {
            var url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "BrushMasks")
            #if os(macOS)
            // Standalone renderer checks have no application resource bundle.
            if url == nil {
                url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .appendingPathComponent("BrushMasks/\(name).png")
            }
            #endif
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            width = image.width; height = image.height
            guard let bitmap = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            bitmap.translateBy(x: 0, y: CGFloat(height))
            bitmap.scaleBy(x: 1, y: -1)
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var alpha = [UInt8](repeating: 0, count: width * height)
            for i in alpha.indices {
                let j = i * 4
                // Authored black pigment: alpha × (1 - luminance). RGB already
                // contains premultiplication, so transparent edges remain intact.
                let light = (Int(pixels[j]) * 54 + Int(pixels[j + 1]) * 183 + Int(pixels[j + 2]) * 19) / 256
                alpha[i] = UInt8(clamping: Int(pixels[j + 3]) - light)
            }
            coverage = alpha
        }

        func field(at source: SIMD2<Double>, crayon: Bool) -> Double {
            // Mirror the interior of the authored image, avoiding transparent
            // canvas margins and wrap seams. No generated noise is added.
            func mirror(_ value: Double) -> Double {
                let t = value - floor(value / 2) * 2
                return t <= 1 ? t : 2 - t
            }
            let u = 0.18 + mirror(source.x) * 0.64
            let v = crayon ? 0.32 + mirror(source.y) * 0.36 : 0.18 + mirror(source.y) * 0.64
            return sample(u: u, v: v)
        }

        func sample(u: Double, v: Double) -> Double {
            guard u >= 0, v >= 0, u <= 1, v <= 1 else { return 0 }
            let x = u * Double(width - 1), y = v * Double(height - 1)
            let ix = Int(x), iy = Int(y)
            let nx = min(width - 1, ix + 1), ny = min(height - 1, iy + 1)
            let fx = x - Double(ix), fy = y - Double(iy)
            let a = Double(coverage[iy * width + ix]), b = Double(coverage[iy * width + nx])
            let c = Double(coverage[ny * width + ix]), d = Double(coverage[ny * width + nx])
            return ((a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy) / 255
        }
    }

    static let pencilMask = Mask(name: "PencilNib")
    static let crayonMask = Mask(name: "CrayonNib")

    struct Material {
        let crayon: Bool
        let sweeps: [Sweep]
        var bounds: CGRect { sweeps.reduce(.null) { $0.union($1.bounds) } }

        func draw(in context: CGContext, color: SIMD4<Float>) {
            guard let mask = crayon ? crayonMask : pencilMask else {
                assertionFailure("Missing authored brush mask in application resources")
                return
            }
            let scale = max(0.1, hypot(context.ctm.a, context.ctm.b))
            let visible = bounds.intersection(context.boundingBoxOfClipPath)
            guard !visible.isNull, !visible.isEmpty else { return }
            let minX = Int(floor(visible.minX * scale / 32)) * 32
            let minY = Int(floor(visible.minY * scale / 32)) * 32
            let maxX = Int(ceil(visible.maxX * scale)), maxY = Int(ceil(visible.maxY * scale))
            for y0 in stride(from: minY, to: maxY, by: 32) {
                guard !Task.isCancelled else { return }
                for x0 in stride(from: minX, to: maxX, by: 32) {
                    let rect = CGRect(x: Double(x0) / scale, y: Double(y0) / scale,
                                      width: 32 / scale, height: 32 / scale)
                    let local = sweeps.filter { $0.bounds.intersects(rect) }
                    guard !local.isEmpty else { continue }
                    var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
                    for y in 0..<32 {
                        for x in 0..<32 {
                            var coverage = 0.0
                            // Four subpixel samples integrate the authored detail
                            // at screen resolution, without enlarging the bitmap.
                            for offset in [SIMD2(0.25, 0.25), SIMD2(0.75, 0.25), SIMD2(0.25, 0.75), SIMD2(0.75, 0.75)] {
                                let p = SIMD2((Double(x0 + x) + offset.x) / scale,
                                              (Double(y0 + y) + offset.y) / scale)
                                var nearestDistance = Double.infinity
                                var source: SIMD2<Double>?
                                for segment in local {
                                    let delta = segment.center - segment.start
                                    let squaredLength = simd_length_squared(delta)
                                    let t = squaredLength > 0.000001
                                        ? min(1, max(0, simd_dot(p - segment.start, delta) / squaredLength)) : 0
                                    let position = segment.start + delta * t
                                    let d = p - position
                                    let distance = simd_length_squared(d)
                                    guard distance <= segment.width * segment.width / 4,
                                          distance < nearestDistance else { continue }
                                    nearestDistance = distance
                                    let turn = atan2(sin(segment.angle - segment.startAngle),
                                                     cos(segment.angle - segment.startAngle))
                                    let angle = segment.startAngle + turn * t
                                    let across = -d.x * sin(angle) + d.y * cos(angle)
                                    let along = d.x * cos(angle) + d.y * sin(angle)
                                    source = segment.startSource + (segment.source - segment.startSource) * t
                                        + SIMD2(across, along) / segment.textureScale
                                }
                                // One lookup in a canvas texture field. Continuous
                                // swept coverage reveals it; no nib image is stamped.
                                let deposited = source.map { mask.field(at: $0, crayon: crayon) } ?? 0
                                coverage += deposited * 0.25
                            }
                            let alpha = coverage * Double(color.w)
                            let i = (y * 32 + x) * 4
                            bytes[i] = UInt8(clamping: Int(Double(color.x) * alpha * 255))
                            bytes[i + 1] = UInt8(clamping: Int(Double(color.y) * alpha * 255))
                            bytes[i + 2] = UInt8(clamping: Int(Double(color.z) * alpha * 255))
                            bytes[i + 3] = UInt8(clamping: Int(alpha * 255))
                        }
                    }
                    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                          let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { continue }
                    context.saveGState()
                    context.interpolationQuality = .none
                    context.translateBy(x: CGFloat(x0) / scale, y: CGFloat(y0 + 32) / scale)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 32 / scale, height: 32 / scale))
                    context.restoreGState()
                }
            }
        }
    }

    /// Continuous swept segments reveal the authored field. Only the texture
    /// frame rotates, after position and angular jitter have been rejected.
    static func sweeps(for stroke: Stroke) -> [Sweep] {
        guard let first = stroke.points.first else { return [] }
        let crayon = stroke.style.instrument == .crayon
        let width = Double(max(0.1, stroke.style.width))
        let seed = stroke.id.uuidString.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let phase = (Double(seed % 1001) / 1000 - 0.5) * (crayon ? 0.16 : 0.5)
        let origin = SIMD2(Double(first.position.x), Double(first.position.y))
        let jitter = max(0.4, min(1.8, width * 0.06))
        var points = [origin]
        for sample in stroke.points.dropFirst() {
            let p = SIMD2(Double(sample.position.x), Double(sample.position.y))
            if simd_distance(points.last!, p) >= jitter { points.append(p) }
        }
        let initial = points.count > 1 ? points[1] - origin : SIMD2<Double>(1, 0)
        var heading = atan2(initial.y, initial.x)
        let headingWindow = max(1.2, min(8, width * 0.3))
        let textureScale = max(96, width * 8)
        var source = SIMD2(Double((seed >> 12) % 65521) / 65521,
                           Double((seed >> 32) % 65521) / 65521)
        if points.count == 1 {
            return [Sweep(start: origin, startAngle: heading + phase, startSource: source,
                          center: origin, angle: heading + phase, width: width, length: 0,
                          source: source, textureScale: textureScale)]
        }
        var result: [Sweep] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let delta = b - a
            let distance = simd_length(delta)
            let target = atan2(delta.y, delta.x)
            let difference = atan2(sin(target - heading), cos(target - heading))
            let oldAngle = heading + phase
            if abs(difference) > Double.pi / 36 {
                heading += difference * (1 - exp(-distance / headingWindow))
            }
            let angle = heading + phase
            let oldSource = source
            let midAngle = oldAngle + atan2(sin(angle - oldAngle), cos(angle - oldAngle)) * 0.5
            source += SIMD2(-delta.x * sin(midAngle) + delta.y * cos(midAngle),
                             delta.x * cos(midAngle) + delta.y * sin(midAngle)) / textureScale
            source += SIMD2(sin(angle) - sin(oldAngle), cos(angle) - cos(oldAngle)) * 0.09
            result.append(Sweep(start: a, startAngle: oldAngle, startSource: oldSource,
                                center: b, angle: angle, width: width, length: distance,
                                source: source, textureScale: textureScale))
        }
        return result
    }
}
