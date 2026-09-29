import SwiftUI

/// Geometry is generated once by the brushes and consumed by both rendering paths.
nonisolated struct WatchDrawingCommand {
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

nonisolated struct WatchDrawingContext {
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

nonisolated enum WatchBitmapRenderer {
    /// A transparent, floating-point ink snapshot preserves multiply and pixel erasing.
    private struct InkSnapshot {
        let image: CGImage
    }

    struct CacheKey: Equatable {
        let documentID: ObjectIdentifier
        let documentRevision: UInt64
        let size: CGSize
        let scale: CGFloat
    }

    /// Screen-only policy; export keeps its explicitly requested resolution.
    static let maximumRasterScale: CGFloat = 4
    static func rasterScale(displayScale: CGFloat, zoom: Double) -> CGFloat {
        min(maximumRasterScale, displayScale * CGFloat(max(1, zoom)))
    }

    struct StrokeGeometry {
        let revision: UUID
        let commands: [WatchDrawingCommand]
        let coverage: WatchStrokeCoverage.Geometry?
        let bounds: CGRect

        init(_ stroke: Stroke) throws {
            revision = stroke.geometryRevision
            if stroke.style.instrument == .marker || stroke.style.instrument == .watercolor {
                let geometry = try WatchStrokeCoverage.geometry(for: stroke)
                coverage = geometry
                commands = []
                bounds = geometry.bounds
            } else {
                coverage = nil
                commands = WatchStrokeDrawing.commands(for: stroke)
                bounds = commands.reduce(CGRect.null) { bounds, command in
                    let shapeBounds: CGRect
                    switch command.shape {
                    case let .fill(path): shapeBounds = path.boundingRect
                    case let .stroke(path, style):
                        shapeBounds = path.cgPath.copy(strokingWithWidth: style.lineWidth,
                            lineCap: style.lineCap, lineJoin: style.lineJoin,
                            miterLimit: style.miterLimit).boundingBoxOfPath
                    }
                    return bounds.union(shapeBounds)
                }
            }
        }
    }

    /// Owned by one canvas view. Appends extend the ink; history edits rebuild it.
    final class Cache {
        private var key: CacheKey?
        private(set) var geometry: [UUID: StrokeGeometry] = [:]
        private(set) var geometryBuildCount = 0
        private var committedInk: InkSnapshot?
        private var committedImage: CGImage?
        private(set) var rebuildCount = 0
        private(set) var appendCount = 0
        private(set) var committedRasterizedStrokeCount = 0
        private var committedStrokes: [StrokeVersion] = []

        private struct StrokeVersion: Equatable {
            let id: UUID
            let revision: UUID

            init(_ stroke: Stroke) {
                id = stroke.id
                revision = stroke.geometryRevision
            }
        }
        private var activeInk: ActiveInk?
        private var activeImage: CGImage?
        private(set) var activeCoverageBuildCount = 0
        var activeRasterizedPrimitiveCount: Int { activeInk?.coverage.rasterizedPrimitiveCount ?? 0 }

        private struct ActiveInk {
            let id: UInt64?
            let coverage: WatchStrokeCoverage
            let base: CGContext
            let frame: CGContext
        }

        func render(strokes: [Stroke], activeStroke: Stroke?, key nextKey: CacheKey,
                    activeStrokeID: UInt64? = nil) -> CGImage? {
            if key != nextKey {
                if key?.documentID != nextKey.documentID { geometry.removeAll() }
                // Bound ownership to current artwork; undo can regenerate removed entries.
                let ids = Set(strokes.map(\.id))
                geometry = geometry.filter { ids.contains($0.key) }
                for stroke in strokes where geometry[stroke.id]?.revision != stroke.geometryRevision {
                    guard !Task.isCancelled else { return nil }
                    guard let entry = try? StrokeGeometry(stroke) else { return nil }
                    geometry[stroke.id] = entry
                    geometryBuildCount += 1
                }
                let versions = strokes.map(StrokeVersion.init)
                // Reuse only an unchanged prefix at the same resolution and canvas size.
                // Requests may skip intermediate commits, so append the whole unseen suffix.
                let canAppend = committedInk != nil &&
                    key?.documentID == nextKey.documentID &&
                    key?.size == nextKey.size && key?.scale == nextKey.scale &&
                    versions.count > committedStrokes.count &&
                    versions.starts(with: committedStrokes)
                let pendingStrokes = canAppend ? Array(strokes.dropFirst(committedStrokes.count)) : strokes
                guard let ink = WatchBitmapRenderer.renderInk(strokes: pendingStrokes, size: nextKey.size,
                                                             scale: nextKey.scale,
                                                             base: canAppend ? committedInk : nil,
                                                             geometry: geometry),
                      let image = WatchBitmapRenderer.flatten(ink, paperWhite: 1),
                      !Task.isCancelled else { return nil }
                // Publish the snapshot and its prefix together only after success.
                committedInk = ink
                committedImage = image
                committedStrokes = versions
                key = nextKey
                if canAppend { appendCount += 1 } else { rebuildCount += 1 }
                committedRasterizedStrokeCount += pendingStrokes.count
                activeInk = nil
                activeImage = nil
            }
            guard let committedInk else { return nil }
            guard let activeStroke else {
                activeInk = nil
                activeImage = nil
                return committedImage
            }
            if activeStroke.style.instrument == .marker || activeStroke.style.instrument == .watercolor {
                if activeStrokeID == nil || activeInk?.id != activeStrokeID ||
                    activeInk?.coverage.canAppend(activeStroke) != true {
                    let width = committedInk.image.width
                    let height = committedInk.image.height
                    guard let base = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                          let frame = WatchBitmapRenderer.makeFloatContext(width: width, height: height)
                    else { return nil }
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    base.draw(committedInk.image, in: bounds)
                    frame.draw(committedInk.image, in: bounds)
                    activeInk = ActiveInk(id: activeStrokeID,
                        coverage: WatchStrokeCoverage(style: activeStroke.style, width: width,
                                                      height: height, scale: nextKey.scale),
                        base: base, frame: frame)
                    activeImage = committedImage
                    activeCoverageBuildCount += 1
                }
                guard let activeInk else { return nil }
                do {
                    let dirty = try activeInk.coverage.append(activeStroke)
                    if !dirty.isNull, !dirty.isEmpty {
                        activeInk.coverage.composite(dirty: dirty, over: activeInk.base, into: activeInk.frame)
                        guard let frame = activeInk.frame.makeImage(),
                              let image = WatchBitmapRenderer.flatten(InkSnapshot(image: frame), paperWhite: 1)
                        else { return nil }
                        activeImage = image
                    }
                    return activeImage
                } catch {
                    self.activeInk = nil
                    activeImage = nil
                    return nil
                }
            }
            activeInk = nil
            activeImage = nil
            guard let frame = WatchBitmapRenderer.renderInk(strokes: [activeStroke], size: nextKey.size,
                                                            scale: nextKey.scale, base: committedInk)
            else { return nil }
            return WatchBitmapRenderer.flatten(frame, paperWhite: 1)
        }
    }

    /// Full replay remains available for export and previews.
    static func render(strokes: [Stroke], size: CGSize, scale: CGFloat, paperWhite: CGFloat = 1) -> CGImage? {
        guard let ink = renderInk(strokes: strokes, size: size, scale: scale) else { return nil }
        return flatten(ink, paperWhite: paperWhite)
    }

    private static func renderInk(strokes: [Stroke], size: CGSize, scale: CGFloat,
                                  base: InkSnapshot? = nil, geometry: [UUID: StrokeGeometry] = [:]) -> InkSnapshot? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        guard width <= 8192, height <= 8192,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = makeFloatContext(width: Int(width), height: Int(height))
        else { return nil }
        if let base {
            context.draw(base.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        for stroke in strokes {
            guard !Task.isCancelled else { return nil }
            // Also tolerate separately edited copies with a shared ID.
            let cached = geometry[stroke.id].flatMap {
                $0.revision == stroke.geometryRevision ? $0 : nil
            }
            if stroke.style.instrument == .marker || stroke.style.instrument == .watercolor {
                let coverage = WatchStrokeCoverage(style: stroke.style, width: Int(width),
                                                   height: Int(height), scale: scale)
                let dirty: CGRect
                do {
                    if let shapes = cached?.coverage {
                        dirty = try coverage.replay(shapes)
                    } else {
                        dirty = try coverage.append(stroke)
                    }
                } catch { return nil }
                coverage.composite(dirty: dirty, over: context, into: context)
            } else {
                for command in cached?.commands ?? WatchStrokeDrawing.commands(for: stroke) {
                    draw(command, in: context, space: space)
                }
            }
        }
        guard let image = context.makeImage() else { return nil }
        return InkSnapshot(image: image)
    }

    private static func makeFloatContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                         bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func flatten(_ ink: InkSnapshot, paperWhite: CGFloat) -> CGImage? {
        // Paper is added only for display/export, so an eraser can still remove cached ink.
        let width = ink.image.width
        let height = ink.image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let output = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        output.setFillColor(CGColor(gray: paperWhite, alpha: 1))
        output.fill(bounds)
        output.draw(ink.image, in: bounds)
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

/// Serial ownership keeps mutable bitmap contexts off the UI actor and prevents
/// overlapping requests from modifying the same incremental cache.
actor WatchArtworkRenderer {
    private let cache = WatchBitmapRenderer.Cache()

    func render(strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64) -> CGImage? {
        assert(!Thread.isMainThread, "Bitmap rendering must stay off the main thread")
        guard !Task.isCancelled, key.size.width > 0, key.size.height > 0 else { return nil }
        let image = cache.render(strokes: strokes, activeStroke: activeStroke,
                                 key: key, activeStrokeID: activeStrokeID)
        return Task.isCancelled ? nil : image
    }
}
