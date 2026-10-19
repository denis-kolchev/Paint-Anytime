import CoreGraphics
import Foundation

/// Materialize the otherwise implicit alpha-lock boundary before object editing.
/// Exclusions live in stroke-local coordinates and travel with its transform.
nonisolated enum WatchTransparencyClipping {
    enum ClippingError: Error { case rendering }
    private struct Run: Hashable { let x: Int; let width: Int }

    static func prepare(strokes: [Stroke], size: CGSize, scale: CGFloat) throws -> [Stroke] {
        guard strokes.contains(where: \.locksTransparency) else { return strokes }
        var preceding: [Stroke] = []
        var result: [Stroke] = []
        var alpha: CGContext?
        for stroke in strokes {
            try Task.checkCancellation()
            defer { preceding.append(stroke) }
            guard stroke.locksTransparency, stroke.style.instrument != .eraser else {
                result.append(stroke)
                alpha = nil
                continue
            }
            if alpha == nil {
                guard let image = WatchBitmapRenderer.layerThumbnail(strokes: preceding, size: size, scale: scale),
                      let context = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                    else { throw ClippingError.rendering }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                alpha = context
            }
            guard let alpha, let data = alpha.data else { throw ClippingError.rendering }
            let bounds = try WatchBitmapRenderer.StrokeGeometry(stroke).bounds
                .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
                .intersection(CGRect(x: 0, y: 0, width: alpha.width, height: alpha.height))
            guard !bounds.isNull, !bounds.isEmpty else { result.append(stroke); continue }
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var active: [Run: CGRect] = [:]
            var cuts: [CGRect] = []
            for y in Int(bounds.minY)..<Int(bounds.maxY) {
                try Task.checkCancellation()
                var next: [Run: CGRect] = [:]
                var x = Int(bounds.minX)
                while x < Int(bounds.maxX) {
                    guard pixels[y * alpha.bytesPerRow + x * 4 + 3] == 0 else { x += 1; continue }
                    let start = x
                    while x < Int(bounds.maxX), pixels[y * alpha.bytesPerRow + x * 4 + 3] == 0 { x += 1 }
                    let run = Run(x: start, width: x - start)
                    var rect = active.removeValue(forKey: run) ?? CGRect(x: start, y: y, width: run.width, height: 0)
                    rect.size.height += 1
                    next[run] = rect
                }
                cuts.append(contentsOf: active.values)
                active = next
            }
            cuts.append(contentsOf: active.values)
            var clipped = stroke
            let inverse = stroke.transform.affine.inverted()
            clipped.excludedAreas += cuts.map { rect in
                [CGPoint(x: rect.minX / scale, y: rect.minY / scale),
                 CGPoint(x: rect.maxX / scale, y: rect.minY / scale),
                 CGPoint(x: rect.maxX / scale, y: rect.maxY / scale),
                 CGPoint(x: rect.minX / scale, y: rect.maxY / scale)].map {
                    let point = $0.applying(inverse)
                    return SIMD2(Float(point.x), Float(point.y))
                }
            }
            result.append(clipped)
        }
        return result
    }
}
