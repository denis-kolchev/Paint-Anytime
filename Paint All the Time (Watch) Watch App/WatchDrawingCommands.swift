import SwiftUI
import simd

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

    struct ScreenTile: Identifiable {
        let id: SIMD2<Int>
        let rect: CGRect // Canvas points, top-left origin.
        let image: CGImage
    }
    struct ScreenFrame {
        let background: CGImage
        let tiles: [ScreenTile]
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
        private var usesScreenTiles = false

        func screenFrame(strokes: [Stroke], activeStroke: Stroke?, key: CacheKey,
                         activeStrokeID: UInt64) -> ScreenFrame? {
            usesScreenTiles = true
            defer { usesScreenTiles = false }
            guard let image = render(strokes: strokes, activeStroke: activeStroke,
                                     key: key, activeStrokeID: activeStrokeID) else { return nil }
            if activeStroke != nil, let dry = activeDry, let background = committedImage {
                return ScreenFrame(background: background, tiles: dry.screenTiles.values.sorted {
                    $0.id.y == $1.id.y ? $0.id.x < $1.id.x : $0.id.y < $1.id.y
                })
            }
            return ScreenFrame(background: image, tiles: [])
        }

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

        private var activeDry: ActiveDry?
        private(set) var activeDryBuildCount = 0
        private(set) var lastDryDirtyArea: CGFloat = 0
        private struct ActiveDry {
            var stroke: Stroke
            let base: CGImage
            let frame: CGContext
            let display: CGContext
            let geometry: WatchStrokeDrawing.DryGeometry
            var travel: Float = 0
            var renderedContours: [SIMD2<Int>: UInt64] = [:]
            var screenTiles: [SIMD2<Int>: ScreenTile] = [:]
        }

        private func renderDry(_ stroke: Stroke, base: InkSnapshot, key: CacheKey) -> CGImage? {
            let previous = activeDry?.stroke
            let extends = previous.map {
                stroke.extends($0)
            } ?? false
            if !extends {
                guard let frame = WatchBitmapRenderer.makeFloatContext(width: base.image.width,
                                                                       height: base.image.height) else { return nil }
                frame.draw(base.image, in: CGRect(x: 0, y: 0, width: base.image.width, height: base.image.height))
                guard let display = WatchBitmapRenderer.makeDisplayContext(width: frame.width, height: frame.height) else { return nil }
                display.setFillColor(CGColor(gray: 1, alpha: 1))
                display.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                display.draw(base.image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                activeDry = ActiveDry(stroke: stroke, base: base.image, frame: frame, display: display,
                                      geometry: WatchStrokeDrawing.DryGeometry())
                activeDryBuildCount += 1
                activeImage = nil
            }
            guard var dry = activeDry else { return nil }
            if extends && previous?.geometryRevision == stroke.geometryRevision {
                return usesScreenTiles ? committedImage : dry.display.makeImage()
            }
            // New segments can change old feather probes at crossings. Include
            // the nib radius, feather distance, grain overhang and the last join.
            var start = extends ? max(0, (previous?.points.count ?? 0) - 2) : 0
            if stroke.style.instrument == .crayon, previous != nil {
                let travel = dry.travel
                if travel < 4 { start = 0 } // Opening contact changes opacity globally.
            }
            dry.geometry.append(stroke)
            let padding = CGFloat(stroke.style.width) / 2 + 5
            let canvas = CGRect(x: 0, y: 0, width: dry.frame.width, height: dry.frame.height)
            let tileSize: CGFloat = 32
            var tiles = Set<SIMD2<Int>>()
            for i in start..<stroke.points.count {
                let p = stroke.points[i].position
                let q = i > start ? stroke.points[i - 1].position : p
                var rect = CGRect(x: CGFloat(min(p.x, q.x)), y: CGFloat(min(p.y, q.y)),
                                  width: CGFloat(abs(p.x - q.x)) + 0.001,
                                  height: CGFloat(abs(p.y - q.y)) + 0.001)
                rect = rect.insetBy(dx: -padding, dy: -padding)
                    .applying(CGAffineTransform(scaleX: key.scale, y: key.scale)).integral.intersection(canvas)
                guard !rect.isNull, !rect.isEmpty else { continue }
                for y in Int(floor(rect.minY / tileSize))...Int(floor((rect.maxY - 0.001) / tileSize)) {
                    for x in Int(floor(rect.minX / tileSize))...Int(floor((rect.maxX - 0.001) / tileSize)) {
                        // Reject tiles outside the oriented swept nib envelope,
                        // rather than visiting every corner of its bounding box.
                        let delta = p - q
                        let length = simd_length(delta)
                        if length > 0.001 {
                            let tangent = delta / length
                            let normal = SIMD2<Float>(-tangent.y, tangent.x)
                            let half = Float(tileSize / (2 * key.scale))
                            let center = SIMD2<Float>(Float((CGFloat(x) + 0.5) * tileSize / key.scale),
                                                      Float((CGFloat(y) + 0.5) * tileSize / key.scale)) - q
                            let along = simd_dot(center, tangent)
                            let across = abs(simd_dot(center, normal))
                            let alongReach = half * (abs(tangent.x) + abs(tangent.y)) + Float(padding)
                            let acrossReach = half * (abs(normal.x) + abs(normal.y)) + Float(padding)
                            if along < -alongReach || along > length + alongReach || across > acrossReach { continue }
                        }
                        tiles.insert(SIMD2(x, y))
                    }
                }
            }
            lastDryDirtyArea = 0
            var changedTiles: [SIMD2<Int>] = []
            var batches: [(tile: SIMD2<Int>, rect: CGRect, commands: [WatchDrawingCommand], revision: UInt64?)] = []
            for tile in tiles {
                let dirty = CGRect(x: CGFloat(tile.x) * tileSize, y: CGFloat(tile.y) * tileSize,
                                   width: tileSize, height: tileSize).intersection(canvas)
                let region = dirty.applying(CGAffineTransform(scaleX: 1 / key.scale, y: 1 / key.scale))
                let commands = WatchStrokeDrawing.commands(for: stroke, region: region, dryGeometry: dry.geometry)
                guard !Task.isCancelled else { return nil }
                let revision = dry.geometry.contourRevision(in: region)
                if let revision, dry.renderedContours[tile] == revision { continue }
                changedTiles.append(tile)
                lastDryDirtyArea += dirty.width * dirty.height
                batches.append((tile, dirty, commands, revision))
            }
            if !batches.isEmpty {
                guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
                let frame = dry.frame
                let union = CGMutablePath()
                for batch in batches {
                    union.addRect(CGRect(x: batch.rect.minX, y: CGFloat(frame.height) - batch.rect.maxY,
                                         width: batch.rect.width, height: batch.rect.height))
                }
                frame.saveGState()
                frame.addPath(union); frame.clip()
                frame.clear(canvas)
                frame.draw(dry.base, in: canvas)
                frame.translateBy(x: 0, y: CGFloat(frame.height))
                frame.scaleBy(x: key.scale, y: -key.scale)
                let opacity = stroke.style.effectiveOpacity
                if opacity < 1 {
                    frame.setAlpha(CGFloat(opacity))
                    frame.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                for batch in batches {
                    frame.saveGState()
                    frame.clip(to: batch.rect.applying(CGAffineTransform(scaleX: 1 / key.scale, y: 1 / key.scale)))
                    for command in batch.commands { WatchBitmapRenderer.draw(command, in: frame, space: space) }
                    frame.restoreGState()
                    dry.renderedContours[batch.tile] = batch.revision
                }
                if opacity < 1 { frame.endTransparencyLayer() }
                frame.restoreGState()
            }
            if changedTiles.isEmpty {
                dry.stroke = stroke
                dry.travel = dry.geometry.travel
                activeDry = dry
                activeImage = usesScreenTiles ? committedImage : dry.display.makeImage()
                return activeImage
            }
            // Copy only changed rows into small snapshots. No full-canvas
            // CGImage snapshot is needed while a dry gesture is on screen.
            for tile in changedTiles {
                let dirty = CGRect(x: CGFloat(tile.x) * tileSize, y: CGFloat(tile.y) * tileSize,
                                   width: tileSize, height: tileSize).intersection(canvas)
                guard let patch = WatchBitmapRenderer.snapshot(dry.frame, rect: dirty, floating: true),
                      let flat = WatchBitmapRenderer.flatten(InkSnapshot(image: patch), paperWhite: 1) else { return nil }
                let destination = CGRect(x: dirty.minX, y: CGFloat(dry.frame.height) - dirty.maxY,
                                         width: dirty.width, height: dirty.height)
                dry.display.draw(flat, in: destination)
                dry.screenTiles[tile] = ScreenTile(id: tile,
                    rect: dirty.applying(CGAffineTransform(scaleX: 1 / key.scale, y: 1 / key.scale)), image: flat)
            }
            dry.stroke = stroke
            dry.travel = dry.geometry.travel
            activeDry = dry
            activeImage = usesScreenTiles ? committedImage : dry.display.makeImage()
            return activeImage
        }

        private struct ActiveInk {
            let id: UInt64?
            let coverage: WatchStrokeCoverage
            let base: CGContext
            let frame: CGContext
        }

        func render(strokes: [Stroke], activeStroke: Stroke?, key nextKey: CacheKey,
                    activeStrokeID: UInt64? = nil) -> CGImage? {
            if key != nextKey {
                let versions = strokes.map(StrokeVersion.init)
                if let oldKey = key, oldKey.documentID == nextKey.documentID,
                   oldKey.size == nextKey.size, oldKey.scale == nextKey.scale,
                   versions.count == committedStrokes.count + 1,
                   versions.starts(with: committedStrokes), let final = strokes.last,
                   let dry = activeDry, dry.stroke.id == final.id, dry.stroke.style == final.style,
                   final.extends(dry.stroke), let base = committedInk,
                   let display = renderDry(final, base: base, key: nextKey),
                   let ink = activeDry?.frame.makeImage(), !Task.isCancelled {
                    committedInk = InkSnapshot(image: ink)
                    committedImage = usesScreenTiles ? activeDry?.display.makeImage() : display
                    committedStrokes = versions
                    key = nextKey
                    appendCount += 1
                    activeDry = nil
                    activeImage = nil
                }
            }
            if key != nextKey {
                if key?.documentID != nextKey.documentID { geometry.removeAll() }
                // Bound ownership to current artwork; undo can regenerate removed entries.
                let ids = Set(strokes.map(\.id))
                geometry = geometry.filter { ids.contains($0.key) }
                let versions = strokes.map(StrokeVersion.init)
                // Reuse only an unchanged prefix at the same resolution and canvas size.
                // Requests may skip intermediate commits, so append the whole unseen suffix.
                let canAppend = committedInk != nil &&
                    key?.documentID == nextKey.documentID &&
                    key?.size == nextKey.size && key?.scale == nextKey.scale &&
                    versions.count > committedStrokes.count &&
                    versions.starts(with: committedStrokes)
                let pendingStrokes = canAppend ? Array(strokes.dropFirst(committedStrokes.count)) : strokes
                // Promoted live strokes need no vector cache until a full replay
                // (undo, resize, export) actually requires their geometry.
                for stroke in pendingStrokes where geometry[stroke.id]?.revision != stroke.geometryRevision {
                    guard !Task.isCancelled,
                          let entry = try? StrokeGeometry(stroke), !Task.isCancelled else { return nil }
                    geometry[stroke.id] = entry
                    geometryBuildCount += 1
                }
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
                activeDry = nil
                activeImage = nil
            }
            guard let committedInk else { return nil }
            guard let activeStroke else {
                activeInk = nil
                activeDry = nil
                activeImage = nil
                return committedImage
            }
            if activeStroke.style.instrument == .pencil || activeStroke.style.instrument == .crayon {
                activeInk = nil
                return renderDry(activeStroke, base: committedInk, key: nextKey)
            }
            activeDry = nil
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
                // Fade the complete stroke once, preserving texture and avoiding
                // darker overlaps within a single translucent gesture.
                let opacity = stroke.style.effectiveOpacity
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

    private static func snapshot(_ source: CGContext, rect: CGRect, floating: Bool) -> CGImage? {
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

    private static func makeDisplayContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
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

    func screenFrame(strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                     activeStrokeID: UInt64) -> WatchBitmapRenderer.ScreenFrame? {
        guard !Task.isCancelled else { return nil }
        let frame = cache.screenFrame(strokes: strokes, activeStroke: activeStroke,
                                      key: key, activeStrokeID: activeStrokeID)
        return Task.isCancelled ? nil : frame
    }

    func render(strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64) -> CGImage? {
        assert(!Thread.isMainThread, "Bitmap rendering must stay off the main thread")
        guard !Task.isCancelled, key.size.width > 0, key.size.height > 0 else { return nil }
        let image = cache.render(strokes: strokes, activeStroke: activeStroke,
                                 key: key, activeStrokeID: activeStrokeID)
        return Task.isCancelled ? nil : image
    }
}
