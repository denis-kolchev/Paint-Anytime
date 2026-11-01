import CoreGraphics
import Foundation
import simd

nonisolated extension WatchBitmapRenderer {
    /// Filter a snapshot of the layer once per gesture, then mix through its
    /// coverage mask. Overlapping segments do not repeatedly blur the same ink.
    /// A separable sliding box filter keeps work independent of kernel area.
    static func applyBlur(_ stroke: Stroke, in context: CGContext, scale: CGFloat,
                          erasure: CGContext?) -> Bool {
        let strength = stroke.style.effectiveBlurStrength
        guard strength > 0, !stroke.points.isEmpty else { return true }
        guard let geometry = try? StrokeGeometry(stroke), let data = context.data,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let canvas = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        let affected = geometry.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
            .insetBy(dx: -1, dy: -1).integral.intersection(canvas)
        guard !affected.isNull, !affected.isEmpty else { return true }
        let transform = stroke.transform.affine
        let transformScale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        let radius = max(1, min(512, Int(ceil(CGFloat(stroke.style.effectiveBlurRadius) * scale * transformScale))))
        let sourceRect = affected.insetBy(dx: -CGFloat(radius), dy: -CGFloat(radius))
            .intersection(canvas).integral
        let width = Int(sourceRect.width), height = Int(sourceRect.height)
        let originX = Int(sourceRect.minX), originY = Int(sourceRect.minY)
        let maskWidth = Int(affected.width), maskHeight = Int(affected.height)
        guard let mask = makeFloatContext(width: maskWidth, height: maskHeight),
              let maskData = mask.data else { return false }
        mask.translateBy(x: -affected.minX, y: CGFloat(maskHeight) + affected.minY)
        mask.scaleBy(x: scale, y: -scale)
        for command in geometry.commands { draw(command, in: mask, space: space) }
        let coverage = maskData.assumingMemoryBound(to: Float.self)
        let maskStride = mask.bytesPerRow / MemoryLayout<Float>.size
        let pixels = data.assumingMemoryBound(to: Float.self)
        let stride = context.bytesPerRow / MemoryLayout<Float>.size
        let erased = erasure?.data?.assumingMemoryBound(to: Float.self)
        let erasureStride = (erasure?.bytesPerRow ?? 0) / MemoryLayout<Float>.size
        var horizontal = [SIMD4<Float>](repeating: .zero, count: width * height)
        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (originY + y) * stride + (originX + x) * 4
            return SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        for y in 0..<height {
            guard !Task.isCancelled else { return false }
            var sum = SIMD4<Float>.zero
            for x in 0...min(radius, width - 1) { sum += pixel(x, y) }
            for x in 0..<width {
                let count = min(width - 1, x + radius) - max(0, x - radius) + 1
                horizontal[y * width + x] = sum / Float(count)
                if x - radius >= 0 { sum -= pixel(x - radius, y) }
                if x + radius + 1 < width { sum += pixel(x + radius + 1, y) }
            }
        }
        let offsetX = Int(affected.minX) - originX
        let offsetY = Int(affected.minY) - originY
        for x in offsetX..<(offsetX + maskWidth) {
            guard !Task.isCancelled else { return false }
            var sum = SIMD4<Float>.zero
            for y in max(0, offsetY - radius)...min(height - 1, offsetY + radius) {
                sum += horizontal[y * width + x]
            }
            for y in offsetY..<(offsetY + maskHeight) {
                let count = min(height - 1, y + radius) - max(0, y - radius) + 1
                var blurred = sum / Float(count)
                let i = (originY + y) * stride + (originX + x) * 4
                let original = SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
                var amount = strength * coverage[(y - offsetY) * maskStride + (x - offsetX) * 4 + 3]
                if let erased {
                    amount *= erased[(originY + y) * erasureStride + (originX + x) * 4 + 3]
                }
                if stroke.locksTransparency {
                    // Keep alpha exactly, including partially transparent edges.
                    if blurred.w > 0 { blurred *= original.w / blurred.w }
                    else { blurred = original }
                    blurred.w = original.w
                }
                let mixed = original + (blurred - original) * min(1, max(0, amount))
                for channel in 0..<4 { pixels[i + channel] = max(0, min(1, mixed[channel])) }
                if y - radius >= 0 { sum -= horizontal[(y - radius) * width + x] }
                if y + radius + 1 < height { sum += horizontal[(y + radius + 1) * width + x] }
            }
        }
        return true
    }
}
