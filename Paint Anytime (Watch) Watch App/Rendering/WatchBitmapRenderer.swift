import SwiftUI
import simd
import ImageIO

nonisolated enum WatchBitmapRenderer {
    /// A transparent, floating-point ink snapshot preserves multiply and pixel erasing.
    struct InkSnapshot {
        let image: CGImage
    }

    struct ScreenTile: Identifiable {
        let id: SIMD2<Int>
        let rect: CGRect // Canvas points, top-left origin.
        let image: CGImage
    }
    struct SelectionTexture {
        let image: CGImage
        let rect: CGRect
        let sessionID: UUID
        let key: CacheKey
        let transform: CGAffineTransform
        let layerBelow: CGImage?
        let layerAbove: CGImage?
        let upperLayers: CGImage?
        let opacity: Float
    }

    struct ScreenFrame {
        let background: CGImage
        let tiles: [ScreenTile]
        var selection: SelectionTexture? = nil
    }

    struct CacheKey: Equatable {
        let documentID: ObjectIdentifier
        let documentRevision: UInt64
        let size: CGSize
        let scale: CGFloat
    }

    /// Prepared eraser regions per stroke, so replaying a layer (after Undo, a resize of
    /// the raster or a reopened drawing) does not replay the same erasers again.
    /// Only the small region image is kept; the full white mask is rebuilt around it.
    /// Owned by one renderer cache and used only from its actor.
    final class ErasureMaskCache {
        fileprivate struct Key: Hashable {
            let stroke: UUID
            // Changes with the stroke's transform and erasures, which fully define its mask.
            let revision: UUID
            let width: CGFloat
            let height: CGFloat
            let scale: CGFloat
        }
        fileprivate struct Entry {
            let region: CGRect
            let image: CGImage?
            let bytes: Int
            var access: UInt64
        }
        static let byteLimit = 8 * 1024 * 1024
        static let entryLimit = 2_048
        private var entries: [Key: Entry] = [:]
        private var bytes = 0
        private var clock: UInt64 = 0
        private(set) var hits = 0

        init() {}

        fileprivate func entry(_ key: Key) -> Entry? {
            guard var entry = entries[key] else { return nil }
            clock &+= 1
            entry.access = clock
            entries[key] = entry
            hits += 1
            return entry
        }

        fileprivate func store(_ key: Key, region: CGRect, image: CGImage?) {
            let size = image.map { $0.bytesPerRow * $0.height } ?? 0
            guard size <= Self.byteLimit else { return }
            if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
            while bytes + size > Self.byteLimit || entries.count >= Self.entryLimit,
                  let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
                bytes -= oldest.value.bytes
                entries.removeValue(forKey: oldest.key)
            }
            clock &+= 1
            entries[key] = Entry(region: region, image: image, bytes: size, access: clock)
            bytes += size
        }
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
            if let raster = stroke.raster {
                coverage = nil
                commands = []
                bounds = raster.bounds.applying(stroke.transform.affine)
            } else if stroke.style.instrument == .marker || stroke.style.instrument == .watercolor {
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

    /// Full replay remains available for export and previews.
    static func render(strokes: [Stroke], size: CGSize, scale: CGFloat, paperWhite: CGFloat = 1) -> CGImage? {
        guard let ink = renderInk(strokes: strokes, size: size, scale: scale) else { return nil }
        return flatten(ink, paperWhite: paperWhite)
    }

    static func layerThumbnail(strokes: [Stroke], size: CGSize, scale: CGFloat) -> CGImage? {
        renderInk(strokes: strokes, size: size, scale: scale)?.image
    }

    static func renderInk(strokes: [Stroke], size: CGSize, scale: CGFloat,
                                  base: InkSnapshot? = nil, geometry: [UUID: StrokeGeometry] = [:],
                                  selection: WatchSelectionPreview? = nil,
                                  masks: ErasureMaskCache? = nil) -> InkSnapshot? {
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
        for source in strokes {
            guard !Task.isCancelled else { return nil }
            var stroke = source
            if let selection, selection.selectedIDs.contains(source.id) {
                stroke.transform = StrokeTransform(source.transform.affine.concatenating(selection.transform))
            }
            context.saveGState()
            defer { context.restoreGState() }
            var erasure: CGContext?
            if !stroke.erasures.isEmpty {
                // A selection preview gives moved strokes a new revision every frame; do not cache those.
                guard let maskContext = erasureMask(for: stroke, size: size, scale: scale,
                                                    masks: selection == nil ? masks : nil),
                      let mask = maskContext.makeImage() else { return nil }
                erasure = maskContext
                // CGImage rows run down from the top, while CGContext image
                // drawing uses a bottom-left origin. Flip only to install the clip.
                let imageHeight = height / scale
                context.translateBy(x: 0, y: imageHeight)
                context.scaleBy(x: 1, y: -1)
                context.clip(to: CGRect(x: 0, y: 0, width: width / scale, height: imageHeight), mask: mask)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -imageHeight)
            }
            if let raster = stroke.raster {
                guard let source = CGImageSourceCreateWithData(raster.png as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                context.saveGState()
                exclude(WatchStrokeDrawing.exclusionPaths(for: stroke), from: context)
                context.concatenate(stroke.transform.affine)
                context.translateBy(x: raster.bounds.minX, y: raster.bounds.maxY)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: raster.bounds.size))
                context.restoreGState()
                continue
            }
            if stroke.style.instrument == .blur {
                guard applyBlur(stroke, in: context, scale: scale, erasure: erasure) else { return nil }
                continue
            }
            // Paint on opaque straight RGB, then restore the original alpha mask.
            // This preserves even partially transparent edges across repeated strokes.
            // Evaluate translucent fill overlap against the ink rendered at this
            // exact scale, rather than baking a correction at the flood-fill scale.
            let fillAlpha = min(1, max(0, stroke.style.color.w * stroke.style.effectiveOpacity))
            var fillBaseAlpha: [Float] = []
            if stroke.style.instrument == .fill, fillAlpha > 0, fillAlpha < 1,
               !stroke.locksTransparency, let data = context.data {
                let pixels = data.assumingMemoryBound(to: Float.self)
                let stride = context.bytesPerRow / MemoryLayout<Float>.size
                let color = [stroke.style.color.x, stroke.style.color.y, stroke.style.color.z]
                fillBaseAlpha.reserveCapacity(context.width * context.height)
                for y in 0..<context.height { for x in 0..<context.width {
                    let i = y * stride + x * 4
                    let alpha = pixels[i + 3]
                    let matches = (0..<3).allSatisfy {
                        abs(pixels[i + $0] - color[$0] * alpha) <= 2 / 255.0
                    }
                    fillBaseAlpha.append(matches ? alpha : -1)
                } }
            }
            var lockedAlpha: [Float] = []
            if stroke.locksTransparency, let data = context.data {
                if stroke.style.instrument == .eraser { continue }
                let pixels = data.assumingMemoryBound(to: Float.self)
                let stride = context.bytesPerRow / MemoryLayout<Float>.size
                lockedAlpha.reserveCapacity(context.width * context.height)
                for y in 0..<context.height { for x in 0..<context.width {
                    let i = y * stride + x * 4
                    let alpha = pixels[i + 3]
                    lockedAlpha.append(alpha)
                    for c in 0..<3 { pixels[i + c] = alpha > 0 ? pixels[i + c] / alpha : 0 }
                    pixels[i + 3] = 1
                } }
            }
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
                coverage.composite(dirty: dirty, over: context, into: context, erasure: erasure)
            } else {
                // Fade the complete stroke once, preserving texture and avoiding
                // darker overlaps within a single translucent gesture.
                let opacity = stroke.style.instrument == .eraser ? 1 : stroke.style.effectiveOpacity
                if opacity < 1 {
                    context.saveGState()
                    context.setAlpha(CGFloat(opacity))
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                let commands = cached?.commands ?? WatchStrokeDrawing.commands(for: stroke)
                guard !Task.isCancelled else { return nil }
                for command in commands {
                    guard !Task.isCancelled else { return nil }
                    draw(command, in: context, space: space)
                }
                if opacity < 1 {
                    context.endTransparencyLayer()
                    context.restoreGState()
                }
            }
            if !fillBaseAlpha.isEmpty, let data = context.data {
                let pixels = data.assumingMemoryBound(to: Float.self)
                let stride = context.bytesPerRow / MemoryLayout<Float>.size
                for y in 0..<context.height { for x in 0..<context.width {
                    let i = y * stride + x * 4
                    let before = fillBaseAlpha[y * context.width + x]
                    let after = pixels[i + 3]
                    guard before > 0, before < 1, after > before else { continue }
                    let added = max(0, (after - before) / (1 - before))
                    // Sum edge coverage, capped at the intended opacity. This
                    // closes the seam without applying a second coat to the ink.
                    let alpha = max(before, min(fillAlpha, before + added))
                    for channel in 0..<3 { pixels[i + channel] *= alpha / after }
                    pixels[i + 3] = alpha
                } }
            }
            if !lockedAlpha.isEmpty, let data = context.data {
                let pixels = data.assumingMemoryBound(to: Float.self)
                let stride = context.bytesPerRow / MemoryLayout<Float>.size
                for y in 0..<context.height { for x in 0..<context.width {
                    let i = y * stride + x * 4
                    let alpha = lockedAlpha[y * context.width + x]
                    for c in 0..<3 { pixels[i + c] *= alpha }
                    pixels[i + 3] = alpha
                } }
            }
        }
        guard let image = context.makeImage() else { return nil }
        return InkSnapshot(image: image)
    }

    /// `allowsRegion: false` forces the original full-canvas replay; checks compare both paths.
    /// `masks` reuses a prepared eraser region for an unchanged stroke at this resolution.
    static func erasureMask(for stroke: Stroke, size: CGSize, scale: CGFloat,
                            allowsRegion: Bool = true, masks: ErasureMaskCache? = nil) -> CGContext? {
        guard let background = makeFloatContext(width: Int(ceil(size.width * scale)),
                                                height: Int(ceil(size.height * scale))) else { return nil }
        background.setFillColor(CGColor(gray: 1, alpha: 1))
        background.fill(CGRect(x: 0, y: 0, width: background.width, height: background.height))
        func install(_ region: CGRect, _ image: CGImage?) {
            guard let image else { return }
            background.setBlendMode(.copy)
            background.draw(image, in: CGRect(x: region.minX, y: CGFloat(background.height) - region.maxY,
                                              width: region.width, height: region.height))
        }
        let key = ErasureMaskCache.Key(stroke: stroke.id, revision: stroke.geometryRevision,
                                       width: size.width, height: size.height, scale: scale)
        if allowsRegion, let cached = masks?.entry(key) {
            install(cached.region, cached.image)
            return background
        }
        let erasers = stroke.erasures.map { local in
            var eraser = local
            eraser.transform = StrokeTransform(local.transform.affine.concatenating(stroke.transform.affine))
            return eraser
        }
        if allowsRegion {
            switch regionalErasure(erasers, width: background.width, height: background.height, scale: scale) {
            case .failed:
                return nil
            case let .region(region, image):
                masks?.store(key, region: region, image: image)
                install(region, image)
                return background
            case .unsupported:
                break
            }
        }
        guard let image = background.makeImage() else { return nil }
        guard let mask = renderInk(strokes: erasers, size: size, scale: scale, base: InkSnapshot(image: image))?.image
        else { return nil }
        background.setBlendMode(.copy)
        background.draw(mask, in: CGRect(x: 0, y: 0, width: background.width, height: background.height))
        return background
    }

    private enum RegionalErasure {
        /// An eraser needs the general renderer.
        case unsupported
        case failed
        /// Top-left pixel rectangle and its mask; nil image means the mask stays white.
        case region(CGRect, CGImage?)
    }

    /// Erasers change the white mask only inside their own outlines. Replay them in a
    /// context covering just their bounds; the caller copies that region into the full
    /// mask, instead of allocating and copying a second full-canvas float context per stroke.
    /// The offset is a whole number of pixels, so rasterization matches the full replay.
    private static func regionalErasure(_ erasers: [Stroke], width: Int, height: Int,
                                        scale: CGFloat) -> RegionalErasure {
        var commands: [WatchDrawingCommand] = []
        var bounds = CGRect.null
        for eraser in erasers {
            // Only plain pixel erasers are drawn as commands with no full-context passes.
            guard eraser.style.instrument == .eraser, eraser.style.eraserMode == .pixels,
                  !eraser.locksTransparency, eraser.raster == nil, eraser.erasures.isEmpty,
                  eraser.fillRects == nil else { return .unsupported }
            for command in WatchStrokeDrawing.commands(for: eraser) {
                // Conservative bounds are enough: a larger region only copies more white.
                switch command.shape {
                case let .fill(path):
                    bounds = bounds.union(path.boundingRect)
                case let .stroke(path, style):
                    // Half the width reaches round/bevel edges; square caps reach √2 of it,
                    // miter joins at most the miter limit times it.
                    let reach = style.lineJoin == .miter ? max(2.squareRoot(), style.miterLimit) : 2.squareRoot()
                    let pad = style.lineWidth / 2 * reach
                    bounds = bounds.union(path.boundingRect.insetBy(dx: -pad, dy: -pad))
                }
                commands.append(command)
            }
        }
        // Nothing to draw leaves the mask white, exactly like an empty replay.
        guard !bounds.isNull else { return .region(.null, nil) }
        guard bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.maxX.isFinite, bounds.maxY.isFinite else { return .unsupported }
        // Top-left pixel rectangle, padded for antialiased edges.
        let region = CGRect(x: bounds.minX * scale, y: bounds.minY * scale,
                            width: bounds.width * scale, height: bounds.height * scale)
            .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !region.isNull, !region.isEmpty else { return .region(.null, nil) }
        // Bottom-left origin of the region in the mask's device space.
        let originY = CGFloat(height) - region.maxY
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = makeFloatContext(width: Int(region.width), height: Int(region.height)) else { return .failed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.translateBy(x: -region.minX, y: -originY)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        for command in commands {
            guard !Task.isCancelled else { return .failed }
            draw(command, in: context, space: space)
        }
        guard let image = context.makeImage() else { return .failed }
        return .region(region, image)
    }

    static func makeFloatContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                         bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    static func snapshot(_ source: CGContext, rect: CGRect, floating: Bool) -> CGImage? {
        guard let input = source.data else { return nil }
        let width = Int(rect.width), height = Int(rect.height)
        guard width > 0, height > 0,
              let target = floating ? makeFloatContext(width: width, height: height)
                  : makeDisplayContext(width: width, height: height), let output = target.data else { return nil }
        let bytesPerPixel = floating ? 16 : 4
        for row in 0..<height {
            let sourceOffset = (Int(rect.minY) + row) * source.bytesPerRow + Int(rect.minX) * bytesPerPixel
            output.advanced(by: row * target.bytesPerRow)
                .copyMemory(from: input.advanced(by: sourceOffset), byteCount: width * bytesPerPixel)
        }
        return target.makeImage()
    }

    static func makeDisplayContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func flatten(_ ink: InkSnapshot, paperWhite: CGFloat) -> CGImage? {
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

    static func draw(_ command: WatchDrawingCommand, in context: CGContext,
                             space: CGColorSpace, normalBlend: Bool = false) {
        context.saveGState()
        exclude(command.exclusionPaths, from: context)
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

    static func exclude(_ paths: [Path], from context: CGContext) {
        for path in paths {
            // The enclosing rectangle supplies the inverse of the lasso contour.
            context.addRect(context.boundingBoxOfClipPath)
            context.addPath(path.cgPath)
            context.clip(using: .evenOdd)
        }
    }

}
