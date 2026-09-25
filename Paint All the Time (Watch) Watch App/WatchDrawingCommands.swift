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

    func fill(_ path: Path, with shading: Shading) {
        append(.fill(path), shading)
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        append(.stroke(path, style), shading)
    }

    private func append(_ shape: WatchDrawingCommand.Shape, _ shading: Shading) {
        if case let .color(rgba) = shading {
            storage.commands.append(WatchDrawingCommand(shape: shape, rgba: rgba,
                                                        opacity: opacity, blendMode: blendMode))
        }
    }
}

enum WatchBitmapRenderer {
    /// An eagerly rendered bitmap: no Canvas, ImageRenderer or deferred image provider.
    static func render(strokes: [Stroke], size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        guard width <= 8192, height <= 8192,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        // Pixel erasing must affect only ink, leaving the paper opaque.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for stroke in strokes {
            for command in WatchStrokeDrawing.commands(for: stroke) {
                context.saveGState()
                let c = command.rgba
                let color = CGColor(colorSpace: space, components: [
                    CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), CGFloat(c.w)])!
                context.setFillColor(color)
                context.setStrokeColor(color)
                context.setAlpha(command.opacity)
                if command.blendMode == .multiply { context.setBlendMode(.multiply) }
                else if command.blendMode == .destinationOut { context.setBlendMode(.destinationOut) }
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
                context.restoreGState()
            }
        }
        context.endTransparencyLayer()
        return context.makeImage()
    }
}
