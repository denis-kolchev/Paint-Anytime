import SwiftUI
import simd
import ImageIO
import Accelerate

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
    /// Lasso textures: the moving selection (`image` over `rect`) and the static scene
    /// around it. The static images (the frame's background, `layerBelow`, `layerAbove`,
    /// `upperLayers`) cover `staticRect` only: the view and a margin at screen resolution,
    /// not the whole paper (`SelectionViewport`). `underlay` shows the static scene at
    /// low resolution outside it, for a zoom-out before the textures are prepared again.
    struct SelectionTexture {
        let image: CGImage
        let rect: CGRect
        /// Pixels per canvas point of `image`.
        let scale: CGFloat
        let sessionID: UUID
        let key: CacheKey
        let transform: CGAffineTransform
        let layerBelow: CGImage?
        let layerAbove: CGImage?
        let upperLayers: CGImage?
        let opacity: Float
        let staticRect: CGRect
        let staticScale: CGFloat
        var underlay: CGImage? = nil
        /// Blends or stroke order the textures cannot move exactly (a later alpha-locked
        /// stroke or multiply marker, a selection with gaps): approximate while dragging,
        /// exact from the committed render.
        let isApproximate: Bool
    }

    /// Where and how finely lasso textures are needed: the visible canvas plus a margin
    /// (canvas points) and the resolution the screen shows it at (pixels per point).
    struct SelectionViewport: Equatable {
        let rect: CGRect
        let scale: CGFloat
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
        /// Canvas point at the raster's top-left corner. Non-zero for a viewport region:
        /// `size` is then the region's size, not the canvas size.
        var origin: CGPoint = .zero
        /// A viewport region's raster; see `LayerCache.isRegion`.
        var isRegion = false
        /// The whole canvas a region belongs to, for blurs reading beyond the region.
        var paper: CGSize? = nil
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
            let originX: CGFloat
            let originY: CGFloat
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

    /// Highest resolution of a viewport region: on a 2× display, the canvas's zoom limit
    /// (one canvas point over `WatchCanvasView.maximumPointZoom` = 128 screen points).
    /// Tiles cover about one screen of pixels whatever their scale, so this costs no
    /// memory; stamp spacing is in canvas points, so no extra stamps per tile either.
    static let maximumRegionScale: CGFloat = 256

    /// Screen raster resolution, in pixels per canvas point.
    ///
    /// `fit` is the paper's on-screen scale at 100% zoom: a 1024 pt canvas on a
    /// ~200 pt screen shows ~0.4 px per point, so rendering it at the display scale
    /// spent ~25 times the pixels (48–64 MiB per layer) on detail the screen cannot
    /// show. Zoom adds resolution only while every layer's float ink fits
    /// `LayerCache.inkByteLimit`. Never below what the unzoomed screen shows; quarter
    /// steps keep the cache key stable. The canvas view passes zoom 1: a viewport
    /// region (`WatchRasterArtwork.Region`) renders the zoomed view instead.
    /// `inkShare` is the fraction of that limit the raster may use (lasso: the rest
    /// goes to the viewport tiles above it).
    static func rasterScale(displayScale: CGFloat, zoom: Double, fit: CGFloat,
                            canvasSize: CGSize, layerCount: Int, inkShare: CGFloat = 1) -> CGFloat {
        let screen = max(0.25, (displayScale * (fit.isFinite && fit > 0 ? fit : 1) * 4).rounded(.up) / 4)
        let requested = min(maximumRasterScale, screen * CGFloat(max(1, zoom)))
        let pixels = canvasSize.width * canvasSize.height * CGFloat(max(1, layerCount))
        guard pixels.isFinite, pixels > 0 else { return requested }
        let fitting = (CGFloat(LayerCache.inkByteLimit) * min(1, max(0, inkShare)) / (16 * pixels)).squareRoot()
        return min(requested, max(screen, (fitting * 4).rounded(.down) / 4))
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
                                  masks: ErasureMaskCache? = nil,
                                  origin: CGPoint = .zero, cullsOutside: Bool = false,
                                  blurSource: BlurSourceContext? = nil) -> InkSnapshot? {
        // `origin` renders a viewport region: `size` is the region's size and canvas
        // point `origin` lands on the top-left pixel. It must be a whole number of
        // pixels, so the region matches the full-canvas raster pixel for pixel.
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0,
              origin.x.isFinite, origin.y.isFinite else { return nil }
        // `cullsOutside`: skip strokes that cannot change a pixel of this raster. Each
        // still costs its geometry, eraser masks, coverage buffers and, on alpha-locked
        // layers, two passes over every pixel, which dominated zoomed regions of large
        // drawings. Only for regions: an empty result is a 1×1 transparent ink, which
        // the incremental live buffers (disabled for regions) cannot take as a base.
        let bounds = CGRect(origin: origin, size: size)
        if cullsOutside, base == nil, selection == nil,
           !strokes.contains(where: { mayDraw($0, in: bounds) }) {
            return makeFloatContext(width: 1, height: 1)?.makeImage().map { InkSnapshot(image: $0) }
        }
        // Appending strokes that miss this raster keeps the base as is: a commit elsewhere
        // must not copy and re-wrap every tile's float ink.
        if cullsOutside, let base, selection == nil,
           !strokes.contains(where: { mayDraw($0, in: bounds) }) {
            return base
        }
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
        context.translateBy(x: -origin.x, y: -origin.y)
        // `blurSource`: the whole layer in order, for blurs that read beyond this raster
        // (`applyBlur(source:)`). Not with a selection preview (moved strokes).
        let blurLayer = selection == nil ? blurSource.map { $0.before + strokes } : nil
        for (position, source) in strokes.enumerated() {
            guard !Task.isCancelled else { return nil }
            var stroke = source
            if let selection, selection.selectedIDs.contains(source.id) {
                stroke.transform = StrokeTransform(source.transform.affine.concatenating(selection.transform))
            }
            if cullsOutside, !mayDraw(stroke, in: bounds) { continue }
            context.saveGState()
            defer { context.restoreGState() }
            var erasure: CGContext?
            // Erasers wholly outside the raster leave the mask white: no mask, no clip.
            if !stroke.erasures.isEmpty, !cullsOutside || stroke.erasures.contains(where: {
                mayDraw($0, in: bounds, transform: $0.transform.affine.concatenating(stroke.transform.affine))
            }) {
                // A selection preview gives moved strokes a new revision every frame; do not cache those.
                guard let maskContext = erasureMask(for: stroke, size: size, scale: scale,
                                                    masks: selection == nil ? masks : nil, origin: origin),
                      let mask = clipMask(maskContext) else { return nil }
                erasure = maskContext
                // CGImage rows run down from the top, while CGContext image
                // drawing uses a bottom-left origin. Flip only to install the clip.
                // The mask covers the raster, so undo the region offset around it.
                let imageHeight = height / scale
                context.translateBy(x: origin.x, y: origin.y + imageHeight)
                context.scaleBy(x: 1, y: -1)
                context.clip(to: CGRect(x: 0, y: 0, width: width / scale, height: imageHeight), mask: mask)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: -origin.x, y: -origin.y - imageHeight)
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
                let blurContext = blurLayer.flatMap { layer in
                    blurSource.map {
                        BlurSourceContext(before: $0.before, paper: $0.paper, layer: layer,
                                          index: $0.before.count + position)
                    }
                }
                guard applyBlur(stroke, in: context, scale: scale, erasure: erasure, origin: origin,
                                source: blurContext) else { return nil }
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
                                                   height: Int(height), scale: scale, origin: origin)
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

    /// Whether `stroke` may change a pixel inside `rect` (canvas points), from cheap,
    /// conservative bounds: its samples, fill rectangles and photo, padded beyond the
    /// widest brush reach. Every brush stays within half its width of the samples (the
    /// reed nib's corner 1.01×, the blur feather adds 0.15×); pencil grains and
    /// antialiasing add under 2 pt, and one more point covers any pixel rounding.
    static func mayDraw(_ stroke: Stroke, in rect: CGRect, transform: CGAffineTransform? = nil) -> Bool {
        reach(of: stroke, transform: transform).intersects(rect)
    }

    /// Canvas points `stroke` may change; null for a stroke that draws nothing. See `mayDraw`.
    static func reach(of stroke: Stroke, transform: CGAffineTransform? = nil) -> CGRect {
        var minX = Float.infinity, minY = Float.infinity
        var maxX = -Float.infinity, maxY = -Float.infinity
        for sample in stroke.points {
            let p = sample.position
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        for r in stroke.fillRects ?? [] {
            minX = min(minX, r.x); maxX = max(maxX, r.x + r.z)
            minY = min(minY, r.y); maxY = max(maxY, r.y + r.w)
        }
        var local = minX <= maxX && minY <= maxY
            ? CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
            : CGRect.null
        if let raster = stroke.raster { local = local.union(raster.bounds) }
        guard !local.isNull, local.minX.isFinite, local.minY.isFinite,
              local.maxX.isFinite, local.maxY.isFinite else { return .null }
        let pad = CGFloat(max(0.1, stroke.style.width.isFinite ? stroke.style.width : 0.1)) * 0.75 + 2
        return local.insetBy(dx: -pad, dy: -pad)
            .applying(transform ?? stroke.transform.affine).insetBy(dx: -1, dy: -1)
    }

    /// `allowsRegion: false` forces the original full-canvas replay; checks compare both paths.
    /// `masks` reuses a prepared eraser region for an unchanged stroke at this resolution.
    ///
    /// The mask is an 8-bit DeviceGray context (`makeMaskContext`): 255 keeps ink, 0
    /// erases. Erasers still rasterize in float; only the result is quantized, by at
    /// most 1/510 at antialiased edges, for 1 byte per pixel instead of 16.
    static func erasureMask(for stroke: Stroke, size: CGSize, scale: CGFloat,
                            allowsRegion: Bool = true, masks: ErasureMaskCache? = nil,
                            origin: CGPoint = .zero) -> CGContext? {
        guard let background = makeMaskContext(width: Int(ceil(size.width * scale)),
                                               height: Int(ceil(size.height * scale))),
              let data = background.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        memset(pixels, 255, background.bytesPerRow * background.height)
        /// Copies an 8-bit region mask (rows from the top) into the mask.
        func install(_ region: CGRect, _ image: CGImage?) {
            guard let image, let bytes = image.dataProvider?.data as Data? else { return }
            let x = Int(region.minX), y = Int(region.minY), width = Int(region.width)
            bytes.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                for row in 0..<Int(region.height) {
                    UnsafeMutableRawPointer(pixels + (y + row) * background.bytesPerRow + x)
                        .copyMemory(from: base + row * image.bytesPerRow, byteCount: width)
                }
            }
        }
        let key = ErasureMaskCache.Key(stroke: stroke.id, revision: stroke.geometryRevision,
                                       width: size.width, height: size.height, scale: scale,
                                       originX: origin.x, originY: origin.y)
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
            switch regionalErasure(erasers, width: background.width, height: background.height,
                                   scale: scale, origin: origin) {
            case .failed:
                return nil
            case let .region(region, image):
                let alpha = image.flatMap(maskImage)
                if image != nil, alpha == nil { return nil }
                masks?.store(key, region: region, image: alpha)
                install(region, alpha)
                return background
            case .unsupported:
                break
            }
        }
        // General erasers replay over a white float raster, as before; it lives only here.
        guard let white = makeFloatContext(width: background.width, height: background.height) else { return nil }
        white.setFillColor(CGColor(gray: 1, alpha: 1))
     
        white.fill(CGRect(x: 0, y: 0, width: white.width, height: white.height))
        guard let image = white.makeImage(),
              let mask = renderInk(strokes: erasers, size: size, scale: scale, base: InkSnapshot(image: image),
                                   origin: origin)?.image
        else { return nil }
        guard copyAlpha(of: mask, into: pixels, stride: background.bytesPerRow) else { return nil }
        return background
    }

    /// One byte per pixel: DeviceGray without alpha, the format `clip(to:mask:)` documents.
    /// Its bytes are written directly (`copyAlpha`), never drawn: drawing would convert
    /// color, while a mask needs the eraser alpha as is.
    static func makeMaskContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    /// Writes the alpha of a premultiplied float RGBA image (`makeFloatContext`), rounded
    /// to 8 bits, into `target` rows from the top.
    private static func copyAlpha(of image: CGImage, into target: UnsafeMutablePointer<UInt8>, stride: Int) -> Bool {
        guard image.bitsPerComponent == 32, image.bitsPerPixel == 128,
              let data = image.dataProvider?.data as Data? else { return false }
        let width = image.width, n = vDSP_Length(image.width)
        let floatStride = image.bytesPerRow / MemoryLayout<Float>.stride
        var row = [Float](repeating: 0, count: width)
        var unit: Float = 255, low: Float = 0, high: Float = 255
        data.withUnsafeBytes { source in
            guard let floats = source.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            row.withUnsafeMutableBufferPointer { row in
                guard let values = row.baseAddress else { return }
                for y in 0..<image.height {
                    vDSP_vsmul(floats + y * floatStride + 3, 4, &unit, values, 1, n)
                    vDSP_vclip(values, 1, &low, &high, values, 1, n)
                    vDSP_vfixru8(values, 1, target + y * stride, 1, n)
                }
            }
        }
        return true
    }

    /// The 8-bit mask of a float eraser region, for the mask cache (16 times smaller).
    private static func maskImage(_ image: CGImage) -> CGImage? {
        guard let context = makeMaskContext(width: image.width, height: image.height),
              let pixels = context.data,
              copyAlpha(of: image, into: pixels.assumingMemoryBound(to: UInt8.self), stride: context.bytesPerRow)
        else { return nil }
        return context.makeImage()
    }

    static func clipMask(_ mask: CGContext) -> CGImage? { mask.makeImage() }

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
                                        scale: CGFloat, origin: CGPoint = .zero) -> RegionalErasure {
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
        // Top-left pixel rectangle of the raster (a region starts at `origin`), padded
        // for antialiased edges.
        let region = CGRect(x: (bounds.minX - origin.x) * scale, y: (bounds.minY - origin.y) * scale,
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
        context.translateBy(x: -origin.x, y: -origin.y)
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
