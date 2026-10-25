import SwiftUI
import ImageIO

/// Brush geometry and pixel cuts run away from the UI actor.
actor WatchLassoBuilder {
    nonisolated enum SelectionError: Error { case rendering }

    private struct GeometryKey: Hashable {
        let id: UUID
        let revision: UUID
    }
    private struct OccupiedMask {
        let size: CGSize
        let scale: CGFloat
        let area: CGRect // Integer pixel coordinates, clipped to the paper.
        let columns: Int
        let rows: Int
        let counts: [Int]
        let total: Int
        let visibleBounds: CGRect?
    }
    private struct CachedGeometry {
        let bounds: CGRect
        var mask: OccupiedMask?
        var access: UInt64
    }
    // Up to 2,048 bounds and 64 masks of 64 * 64 Ints (~2 MiB).
    // No full-resolution images or brush command arrays survive a lookup.
    private var geometryCache: [GeometryKey: CachedGeometry] = [:]
    private var access: UInt64 = 0
    private var eraserVersions: [GeometryKey] = []
    private var eraserLocks: [Bool] = []
    private var attachedStrokes: [Stroke]?
    private var clippingInput: [Stroke] = []
    private var clippingSize = CGSize.zero
    private var clippingScale: CGFloat = 0
    private var clippedStrokes: [Stroke] = []

    private func clippingTransparency(in strokes: [Stroke], size: CGSize, scale: CGFloat) throws -> [Stroke] {
        guard strokes.contains(where: \.locksTransparency) else {
            clippingInput = []; clippedStrokes = []
            return strokes
        }
        if strokes == clippingInput, size == clippingSize, scale == clippingScale { return clippedStrokes }
        let result = try WatchTransparencyClipping.prepare(strokes: strokes, size: size, scale: scale)
        clippingInput = strokes
        clippingSize = size
        clippingScale = scale
        clippedStrokes = result
        return result
    }

    private func cachedBounds(_ stroke: Stroke) throws -> CGRect {
        let key = GeometryKey(id: stroke.id, revision: stroke.geometryRevision)
        access &+= 1
        if var entry = geometryCache[key] {
            entry.access = access
            geometryCache[key] = entry
            return entry.bounds
        }
        let bounds = try WatchBitmapRenderer.StrokeGeometry(stroke).bounds
        if geometryCache.count >= 2_048,
           let oldest = geometryCache.min(by: { $0.value.access < $1.value.access })?.key {
            geometryCache.removeValue(forKey: oldest)
        }
        geometryCache[key] = CachedGeometry(bounds: bounds, access: access)
        return bounds
    }

    private func occupiedMask(_ stroke: Stroke, bounds: CGRect, size: CGSize, scale: CGFloat) throws -> OccupiedMask {
        let key = GeometryKey(id: stroke.id, revision: stroke.geometryRevision)
        if let mask = geometryCache[key]?.mask, mask.size == size, mask.scale == scale { return mask }
        var ink = stroke
        ink.locksTransparency = false
        guard let image = WatchBitmapRenderer.layerThumbnail(strokes: [ink], size: size, scale: scale),
              let context = pixelContext(image), let data = context.data else { throw SelectionError.rendering }
        let area = bounds.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !area.isNull, !area.isEmpty else {
            return OccupiedMask(size: size, scale: scale, area: .zero, columns: 0, rows: 0,
                                counts: [], total: 0, visibleBounds: nil)
        }
        let width = Int(area.width), height = Int(area.height)
        let columns = min(64, width), rows = min(64, height)
        var counts = [Int](repeating: 0, count: columns * rows)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<height {
            try Task.checkCancellation()
            let py = y + Int(area.minY)
            for x in 0..<width {
                let px = x + Int(area.minX)
                guard pixels[py * context.bytesPerRow + px * 4 + 3] > 0 else { continue }
                counts[(y * rows / height) * columns + x * columns / width] += 1
                total += 1
                minX = min(minX, px); minY = min(minY, py)
                maxX = max(maxX, px); maxY = max(maxY, py)
            }
        }
        let visible = total == 0 ? nil : CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        let mask = OccupiedMask(size: size, scale: scale, area: area, columns: columns, rows: rows,
                               counts: counts, total: total, visibleBounds: visible)
        if geometryCache[key]?.mask == nil {
            let masks = geometryCache.filter { $0.value.mask != nil }
            if masks.count >= 64, let oldest = masks.min(by: { $0.value.access < $1.value.access })?.key {
                geometryCache[oldest]?.mask = nil
            }
        }
        geometryCache[key]?.mask = mask
        return mask
    }

    /// Each cell stores the exact occupied-pixel count, not downsampled alpha.
    /// Only cells untouched by the polygon boundary can decide membership.
    /// This gives rigorous bounds on the majority and keeps thin/textured ink exact.
    private func majorityBounds(_ stroke: Stroke, bounds: CGRect, path: CGPath,
                                edges: [CGRect], size: CGSize, scale: CGFloat) throws -> CGRect? {
        let mask = try occupiedMask(stroke, bounds: bounds, size: size, scale: scale)
        guard mask.total > 0 else { return nil }
        var inside = 0, uncertain = 0
        for row in 0..<mask.rows {
            try Task.checkCancellation()
            for column in 0..<mask.columns {
                let count = mask.counts[row * mask.columns + column]
                guard count > 0 else { continue }
                // Integer ceil divisions match the binning above exactly.
                let width = Int(mask.area.width), height = Int(mask.area.height)
                let x0 = (column * width + mask.columns - 1) / mask.columns
                let x1 = ((column + 1) * width + mask.columns - 1) / mask.columns
                let y0 = (row * height + mask.rows - 1) / mask.rows
                let y1 = ((row + 1) * height + mask.rows - 1) / mask.rows
                let cell = CGRect(x: (mask.area.minX + CGFloat(x0)) / scale,
                                  y: (mask.area.minY + CGFloat(y0)) / scale,
                                  width: CGFloat(x1 - x0) / scale, height: CGFloat(y1 - y0) / scale)
                if edges.contains(where: { $0.intersects(cell) }) { uncertain += count }
                else if path.contains(CGPoint(x: cell.midX, y: cell.midY), using: .evenOdd) { inside += count }
            }
        }
        if inside * 2 >= mask.total { return mask.visibleBounds }
        if (inside + uncertain) * 2 < mask.total { return nil }
        return try majorityAreaBounds(stroke, bounds: bounds, path: path, size: size, scale: scale)
    }

    func prepare(document: CanvasDocument, layerID: UUID, polygon: [CGPoint], mode: WatchLassoMode,
                 size: CGSize, scale: CGFloat) throws -> WatchLassoSelection? {
        guard var layer = document.layers.first(where: { $0.id == layerID }),
              layer.isVisible, layer.opacity > 0 else { return nil }
        let path = WatchLassoGeometry.path(polygon)
        let paper = CGRect(origin: .zero, size: size)
        guard path.boundingBoxOfPath.intersects(paper) else { return nil }
        layer.strokes = try clippingTransparency(in: layer.strokes, size: size, scale: scale)
        layer.strokes = try attachingErasers(in: layer.strokes)
        if mode == .area {
            return try cutArea(document: document, layer: layer, polygon: polygon, path: path, size: size, scale: scale)
        }
        // Conservative edge boxes include horizontal/vertical edges and vertices.
        let edges = polygon.indices.map { index in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -0.0001, dy: -0.0001)
        }
        var selected = Set<UUID>()
        var bounds = CGRect.null
        for stroke in layer.strokes where stroke.style.instrument != .eraser {
            try Task.checkCancellation()
            let strokeBounds = try cachedBounds(stroke)
            guard strokeBounds.intersects(path.boundingBoxOfPath), strokeBounds.intersects(paper) else { continue }
            // Evaluate each stroke's occupied area, not its centerline or
            // bounding rectangle. A small intersection is no longer enough.
            guard let visibleBounds = try majorityBounds(stroke, bounds: strokeBounds, path: path,
                edges: edges, size: size, scale: scale) else { continue }
            selected.insert(stroke.id)
            let selectionBounds = stroke.raster != nil || !stroke.excludedAreas.isEmpty || !stroke.erasures.isEmpty
                ? visibleBounds : strokeBounds
            bounds = bounds.union(selectionBounds)
        }
        guard !selected.isEmpty, !bounds.isNull, !bounds.isEmpty else { return nil }
        return WatchLassoSelection(document: document, layerID: layerID, strokes: layer.strokes,
                                   selectedIDs: selected, bounds: bounds)
    }

    private func attachingErasers(in strokes: [Stroke]) throws -> [Stroke] {
        guard strokes.contains(where: { $0.style.instrument == .eraser }) else {
            attachedStrokes = nil
            eraserVersions = []
            eraserLocks = []
            return strokes
        }
        let versions = strokes.map { GeometryKey(id: $0.id, revision: $0.geometryRevision) }
        let locks = strokes.map(\.locksTransparency)
        if versions == eraserVersions, locks == eraserLocks, let attachedStrokes { return attachedStrokes }
        var objects: [Stroke] = []
        var bounds: [CGRect] = []
        for stroke in strokes {
            try Task.checkCancellation()
            let strokeBounds = try cachedBounds(stroke)
            if stroke.style.instrument == .eraser {
                guard stroke.style.eraserMode == .pixels, !stroke.locksTransparency else { continue }
                // Only earlier objects were affected by this eraser. Keep a
                // separate local mask for each, so shared erasures can separate.
                for index in objects.indices where bounds[index].intersects(strokeBounds) {
                    var eraser = stroke
                    eraser.transform = StrokeTransform(stroke.transform.affine.concatenating(
                        objects[index].transform.affine.inverted()))
                    objects[index].erasures.append(eraser)
                }
            } else {
                objects.append(stroke)
                bounds.append(strokeBounds)
            }
        }
        eraserVersions = versions
        eraserLocks = locks
        attachedStrokes = objects
        return objects
    }

    private func majorityAreaBounds(_ stroke: Stroke, bounds: CGRect, path: CGPath,
                                    size: CGSize, scale: CGFloat) throws -> CGRect? {
        var ink = stroke
        ink.locksTransparency = false
        guard let image = WatchBitmapRenderer.layerThumbnail(strokes: [ink], size: size, scale: scale),
              let context = pixelContext(image), let data = context.data else { throw SelectionError.rendering }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let area = bounds
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !area.isNull, !area.isEmpty else { return nil }
        var totalPixels = 0
        var enclosedPixels = 0
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in Int(area.minY)..<Int(area.maxY) {
            try Task.checkCancellation()
            for x in Int(area.minX)..<Int(area.maxX) where pixels[y * context.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                totalPixels += 1
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if path.contains(point, using: .evenOdd) { enclosedPixels += 1 }
            }
        }
        // Count occupied pixels equally: opacity must not make one part of a
        // textured stroke count more than another. Exactly half is included.
        guard totalPixels > 0, enclosedPixels * 2 >= totalPixels else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func cutArea(document: CanvasDocument, layer: CanvasLayer, polygon: [CGPoint], path: CGPath,
                         size: CGSize, scale: CGFloat) throws -> WatchLassoSelection? {
        guard let image = WatchBitmapRenderer.layerThumbnail(strokes: layer.strokes, size: size, scale: scale) else {
            throw SelectionError.rendering
        }
        let region = path.boundingBoxOfPath.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !region.isNull, !region.isEmpty else { return nil }
        guard let cropped = image.cropping(to: region), let inside = pixelContext(cropped),
              let insideData = inside.data else { throw SelectionError.rendering }
        let cut = insideData.assumingMemoryBound(to: UInt8.self)
        var minX = cropped.width, minY = cropped.height, maxX = -1, maxY = -1
        // Both bitmap rows and the lasso have a top-left origin. Crop before
        // masking to keep small selections on a large canvas inexpensive.
        for y in 0..<cropped.height {
            try Task.checkCancellation()
            for x in 0..<cropped.width {
                let i = y * inside.bytesPerRow + x * 4
                let point = CGPoint(x: (region.minX + CGFloat(x) + 0.5) / scale,
                                    y: (region.minY + CGFloat(y) + 0.5) / scale)
                if cut[i + 3] > 0 && path.contains(point, using: .evenOdd) {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                } else {
                    for c in 0..<4 { cut[i + c] = 0 }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let selectedImage = inside.makeImage()?.cropping(to: crop) else { throw SelectionError.rendering }
        let bounds = crop.offsetBy(dx: region.minX, dy: region.minY)
            .applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let selected = try rasterStroke(selectedImage, bounds: bounds)
        // Keep each remaining stroke editable instead of flattening the rest
        // of the layer. The cutout travels with it in later object selections.
        let cutBounds = path.boundingBoxOfPath
        let remaining = try layer.strokes.map { original in
            try Task.checkCancellation()
            guard try cachedBounds(original).intersects(cutBounds) else { return original }
            var stroke = original
            let inverse = original.transform.affine.inverted()
            stroke.excludedAreas.append(polygon.map { point in
                let local = point.applying(inverse)
                return SIMD2(Float(local.x), Float(local.y))
            })
            return stroke
        }
        return WatchLassoSelection(document: document, layerID: layer.id, strokes: remaining + [selected],
                                   selectedIDs: [selected.id], bounds: bounds)
    }

    private func pixelContext(_ image: CGImage) -> CGContext? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    private func rasterStroke(_ image: CGImage, bounds: CGRect) throws -> Stroke {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw SelectionError.rendering
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SelectionError.rendering }
        var style = PencilStyle()
        style.blendingMode = .normal
        var stroke = Stroke(points: [], style: style)
        stroke.raster = StrokeRaster(png: data as Data, bounds: bounds)
        return stroke
    }
}
