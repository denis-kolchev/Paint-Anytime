import SwiftUI

/// Geometry is generated once by the brushes and consumed by both rendering paths.
struct WatchDrawingCommand {
    enum Shape {
        case fill(Path)
        case stroke(Path, StrokeStyle)
    }
    let shape: Shape
    let rgba: SIMD4<Float>
    let opacity: Double
    let blendMode: GraphicsContext.BlendMode
    let usesOpacityLayer: Bool
}

struct WatchDrawingContext {
    enum Shading {
        case color(SIMD4<Float>)
    }
    final class Storage {
        var commands: [WatchDrawingCommand] = []
    }
    let storage = Storage()
    var opacity = 1.0
    var blendMode: GraphicsContext.BlendMode = .normal
    var usesOpacityLayer = false

    func fill(_ path: Path, with shading: Shading) {
        append(.fill(path), shading)
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        append(.stroke(path, style), shading)
    }

    private func append(_ shape: WatchDrawingCommand.Shape, _ shading: Shading) {
        if case let .color(rgba) = shading {
            storage.commands.append(WatchDrawingCommand(shape: shape, rgba: rgba,
                                                        opacity: opacity, blendMode: blendMode,
                                                        usesOpacityLayer: usesOpacityLayer))
        }
    }
}

enum WatchBitmapRenderer {
    /// An eagerly rendered bitmap: no Canvas, ImageRenderer or deferred image provider.
    static func render(strokes: [Stroke], size: CGSize, scale: CGFloat, paperWhite: CGFloat = 1) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        guard width <= 8192, height <= 8192,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 32, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(gray: paperWhite, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        // Pixel erasing must affect only ink, leaving the paper opaque.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for stroke in strokes {
            let commands = WatchStrokeDrawing.commands(for: stroke)
            if commands.contains(where: { $0.blendMode == .multiply }) {
                // Allocate and process only the pixels touched by this stroke.
                let bounds = commands.reduce(CGRect.null) { result, command in
                    switch command.shape {
                    case let .fill(path): return result.union(path.boundingRect)
                    case let .stroke(path, style): return result.union(path.strokedPath(style).boundingRect)
                    }
                }.applying(context.ctm).insetBy(dx: -1, dy: -1).integral
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let washWidth = Int(bounds.width)
                let washHeight = Int(bounds.height)
                guard let wash = CGContext(data: nil, width: washWidth, height: washHeight,
                                           bitsPerComponent: 32, bytesPerRow: 0, space: space,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return nil }
                wash.translateBy(x: -bounds.minX, y: -bounds.minY)
                wash.concatenate(context.ctm)
                for command in commands {
                    draw(command, in: wash, space: space, normalBlend: true)
                }
                // Coverage is accumulated for the whole gesture before color blending.
                // Two passes implement C = (1-a)D + a[kDS + (1-k)S], k = 0.8.
                // normalAlpha = a(1-k), multiplyAlpha = ak / (1-normalAlpha).
                // Compute these per pixel so soft edges obey the same formula.
                guard let data = wash.data else { return nil }
                let pixels = data.assumingMemoryBound(to: Float.self)
                let ink = stroke.style.color
                let coverage = (0..<washHeight).flatMap { y in
                    (0..<washWidth).map { x in pixels[y * (wash.bytesPerRow / MemoryLayout<Float>.stride) + x * 4 + 3] }
                }
                context.saveGState()
                context.concatenate(context.ctm.inverted())
                for multiply in [true, false] {
                    for y in 0..<washHeight {
                        for x in 0..<washWidth {
                            let a = Double(coverage[y * washWidth + x]) * Double(ink.w)
                            let normalAlpha = a * 0.2
                            let alpha = multiply ? a * 0.8 / (1 - normalAlpha) : normalAlpha
                            let offset = y * (wash.bytesPerRow / MemoryLayout<Float>.stride) + x * 4
                            for channel in 0..<3 {
                                pixels[offset + channel] = Float(Double(ink[channel]) * alpha)
                            }
                            pixels[offset + 3] = Float(alpha)
                        }
                    }
                    guard let image = wash.makeImage() else { return nil }
                    context.setBlendMode(multiply ? .multiply : .normal)
                    context.draw(image, in: bounds)
                }
                context.restoreGState()
            } else {
                for command in commands { draw(command, in: context, space: space) }
            }
        }
        context.endTransparencyLayer()
        // Keep intermediate blends in floating point; quantize only the final bitmap.
        guard let image = context.makeImage(),
              let output = CGContext(data: nil, width: Int(width), height: Int(height),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        output.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return output.makeImage()
    }

    private static func draw(_ command: WatchDrawingCommand, in context: CGContext,
                             space: CGColorSpace, normalBlend: Bool = false) {
        context.saveGState()
        let c = command.rgba
        let color = CGColor(colorSpace: space, components: [
            CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), (normalBlend || command.usesOpacityLayer) ? 1 : CGFloat(c.w)])!
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.setAlpha(command.opacity)
        if !normalBlend && command.blendMode == .multiply { context.setBlendMode(.multiply) }
        else if command.blendMode == .destinationOut { context.setBlendMode(.destinationOut) }
        if command.usesOpacityLayer {
            // Core Graphics may split long stroked paths into overlapping batches.
            // Draw those batches opaquely, then composite their combined coverage once.
            context.setAlpha(command.opacity * (normalBlend ? 1 : Double(c.w)))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        switch command.shape {
        case let .fill(path):
            context.addPath(path.cgPath)
            context.fillPath()
        case let .stroke(path, style):
            context.setLineWidth(style.lineWidth)
            context.setLineCap(style.lineCap)
            context.setLineJoin(style.lineJoin)
            context.setMiterLimit(style.miterLimit)
            context.addPath(path.cgPath)
            context.strokePath()
        }
        if command.usesOpacityLayer { context.endTransparencyLayer() }
        context.restoreGState()
    }

}
