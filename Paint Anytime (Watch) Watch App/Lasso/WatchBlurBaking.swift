import CoreGraphics
import Foundation
import ImageIO

/// Bakes blur strokes before object editing, as raster editors do. A blur mixes
/// the pixels of everything it reads, so those strokes (and any stroke between
/// them that overlaps one) become a single raster object holding the blurred
/// result. The layer looks the same as before; afterwards the blurred pixels
/// move, rotate and duplicate with that object instead of staying in place.
nonisolated enum WatchBlurBaking {
    enum BakingError: Error { case rendering }

    /// `bounds` holds each stroke's canvas bounds, in the same order as `strokes`.
    static func prepare(strokes source: [Stroke], bounds sourceBounds: [CGRect],
                        size: CGSize, scale: CGFloat) throws -> [Stroke] {
        guard source.contains(where: { $0.style.instrument == .blur }) else { return source }
        guard sourceBounds.count == source.count, size.width > 0, size.height > 0, scale > 0,
              size.width.isFinite, size.height.isFinite, scale.isFinite else {
            throw BakingError.rendering
        }
        // Same resolution as transparency clipping: baked ink stays smooth when zoomed in.
        let resolution = min(max(scale, WatchBitmapRenderer.maximumRasterScale),
                             8192 / max(size.width, size.height))
        let paper = CGRect(origin: .zero, size: size)
        var strokes = source, bounds = sourceBounds
        // Bake in drawing order, so a later blur reads an earlier one's baked result.
        while let index = strokes.firstIndex(where: { $0.style.instrument == .blur }) {
            try Task.checkCancellation()
            let blur = strokes[index]
            let reach = readArea(of: blur, bounds: bounds[index], resolution: resolution)
            let group = members(below: index, reach: reach, strokes: strokes, bounds: bounds)
            guard !group.isEmpty, reach.intersects(paper) else {
                // Nothing visible to blur: the stroke has no effect on the picture.
                strokes.remove(at: index)
                bounds.remove(at: index)
                continue
            }
            let baked = try bake(blur: index, group: group, reach: reach, strokes: strokes,
                                 bounds: bounds, size: size, resolution: resolution)
            let removed = Set(group)
            var nextStrokes: [Stroke] = [], nextBounds: [CGRect] = []
            nextStrokes.reserveCapacity(strokes.count - group.count)
            nextBounds.reserveCapacity(strokes.count - group.count)
            for position in strokes.indices where !removed.contains(position) {
                if position == index {
                    // Take the blur's place: in-range erasers stay before the object,
                    // since their effect is already in its pixels; later ones still apply.
                    guard let baked, let raster = baked.raster else { continue }
                    nextStrokes.append(baked)
                    nextBounds.append(raster.bounds)
                } else {
                    nextStrokes.append(strokes[position])
                    nextBounds.append(bounds[position])
                }
            }
            strokes = nextStrokes
            bounds = nextBounds
        }
        return strokes
    }

    /// Canvas area whose pixels the blur reads: the feathered brush plus the filter margin.
    private static func readArea(of blur: Stroke, bounds: CGRect, resolution: CGFloat) -> CGRect {
        let parameters = WatchBlurFilter.Parameters(stroke: blur, scale: resolution)
        guard parameters.strength > 0, !blur.points.isEmpty, !bounds.isNull, !bounds.isEmpty else { return .null }
        // Pixels: the drawn rectangle's outset, the coverage feather, the filter margin, and rounding.
        let outset = CGFloat(1 + parameters.feather + parameters.margin + 2) / resolution
        return bounds.insetBy(dx: -outset, dy: -outset)
    }

    /// Objects the blur read, plus every stroke between them that overlaps one of them,
    /// so the baked object can take the blur's place without changing stacking order.
    private static func members(below index: Int, reach: CGRect, strokes: [Stroke], bounds: [CGRect]) -> [Int] {
        guard !reach.isNull, !reach.isEmpty else { return [] }
        func isObject(_ position: Int) -> Bool { strokes[position].style.instrument != .eraser }
        var group = Set((0..<index).filter { isObject($0) && bounds[$0].intersects(reach) })
        guard let lowest = group.min() else { return [] }
        var grew = true
        while grew {
            grew = false
            for position in lowest..<index where !group.contains(position) && isObject(position) {
                let box = bounds[position]
                guard !box.isNull, !box.isEmpty,
                      group.contains(where: { bounds[$0].intersects(box) }) else { continue }
                group.insert(position)
                grew = true
            }
        }
        return group.sorted()
    }

    /// Raster object `R` such that `R` over the strokes left below reproduces the
    /// layer with the blur applied; nil when nothing visible remains.
    private static func bake(blur index: Int, group: [Int], reach: CGRect, strokes: [Stroke],
                             bounds: [CGRect], size: CGSize, resolution: CGFloat) throws -> Stroke? {
        let members = Set(group)
        let prefix = Array(strokes[..<index])
        let remaining = prefix.indices.filter { !members.contains($0) }.map { prefix[$0] }
        // The group alone (with the erasers drawn among it), then blurred: the object's own shape.
        let lowest = group[0]
        let isolated = (lowest..<index).filter { members.contains($0) || strokes[$0].style.instrument == .eraser }
            .map { strokes[$0] } + [strokes[index]]
        guard let before = WatchBitmapRenderer.renderInk(strokes: prefix, size: size, scale: resolution),
              let target = WatchBitmapRenderer.renderInk(strokes: [strokes[index]], size: size,
                                                         scale: resolution, base: before)?.image,
              let under = WatchBitmapRenderer.layerThumbnail(strokes: remaining, size: size, scale: resolution),
              let own = WatchBitmapRenderer.layerThumbnail(strokes: isolated, size: size, scale: resolution),
              target.width == under.width, target.height == under.height,
              own.width == target.width, own.height == target.height else {
            try Task.checkCancellation()
            throw BakingError.rendering
        }
        let scaling = CGAffineTransform(scaleX: resolution, y: resolution)
        let area = group.reduce(reach) { $0.union(bounds[$1]) }
        let region = area.applying(scaling).integral
            .intersection(CGRect(x: 0, y: 0, width: target.width, height: target.height))
        guard !region.isNull, !region.isEmpty else { return nil }
        guard let t = pixelContext(target, region), let tData = t.data,
              let u = pixelContext(under, region), let uData = u.data,
              let o = pixelContext(own, region), let oData = o.data,
              let output = pixelContext(nil, region), let outData = output.data else {
            throw BakingError.rendering
        }
        let tp = tData.assumingMemoryBound(to: UInt8.self)
        let up = uData.assumingMemoryBound(to: UInt8.self)
        let op = oData.assumingMemoryBound(to: UInt8.self)
        let out = outData.assumingMemoryBound(to: UInt8.self)
        let width = Int(region.width), height = Int(region.height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let i = y * t.bytesPerRow + x * 4
                let j = y * u.bytesPerRow + x * 4
                let k = y * o.bytesPerRow + x * 4
                let m = y * output.bytesPerRow + x * 4
                let same = tp[i] == up[j] && tp[i + 1] == up[j + 1] && tp[i + 2] == up[j + 2] && tp[i + 3] == up[j + 3]
                if same && op[k + 3] == 0 {
                    for c in 0..<4 { out[m + c] = 0 }
                    continue
                }
                let pixel = solve(target: (tp[i], tp[i + 1], tp[i + 2], tp[i + 3]),
                                  under: (up[j], up[j + 1], up[j + 2], up[j + 3]), minimumAlpha: op[k + 3])
                out[m] = pixel.0; out[m + 1] = pixel.1; out[m + 2] = pixel.2; out[m + 3] = pixel.3
                guard pixel.3 > 0 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let image = output.makeImage()?.cropping(to: crop) else { throw BakingError.rendering }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw BakingError.rendering
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BakingError.rendering }
        var style = PencilStyle()
        style.blendingMode = .normal
        var stroke = Stroke(points: [], style: style)
        stroke.raster = StrokeRaster(png: data as Data, bounds: crop.offsetBy(dx: region.minX, dy: region.minY)
            .applying(CGAffineTransform(scaleX: 1 / resolution, y: 1 / resolution)))
        return stroke
    }

    /// Premultiplied `R` with `R + (1 − Rα)·U = T`. Where the layer below is opaque,
    /// alpha is free: keep at least the group's own coverage, so the object keeps its
    /// shape when moved, and raise it only as far as mixed colours require.
    private static func solve(target: (UInt8, UInt8, UInt8, UInt8), under: (UInt8, UInt8, UInt8, UInt8),
                              minimumAlpha: UInt8) -> (UInt8, UInt8, UInt8, UInt8) {
        let t = SIMD4<Float>(Float(target.0), Float(target.1), Float(target.2), Float(target.3)) / 255
        let u = SIMD4<Float>(Float(under.0), Float(under.1), Float(under.2), Float(under.3)) / 255
        var alpha: Float
        if u.w >= 254.5 / 255 {
            alpha = Float(minimumAlpha) / 255
            for c in 0..<3 {
                if t[c] < u[c] {
                    alpha = max(alpha, (u[c] - t[c]) / u[c])
                } else if t[c] > u[c] {
                    alpha = u[c] < 1 ? max(alpha, (t[c] - u[c]) / (1 - u[c])) : 1
                }
            }
        } else {
            alpha = (t.w - u.w) / (1 - u.w)
        }
        alpha = min(1, max(0, alpha))
        func byte(_ value: Float) -> UInt8 { UInt8(min(255, max(0, (value * 255).rounded()))) }
        let a = byte(alpha)
        guard a > 0 else { return (0, 0, 0, 0) }
        let limit = Float(a) / 255
        func channel(_ c: Int) -> UInt8 { min(a, byte(min(limit, max(0, t[c] - (1 - alpha) * u[c])))) }
        return (channel(0), channel(1), channel(2), a)
    }

    /// 8-bit premultiplied sRGB pixels of `image` cropped to `region`, or blank when nil.
    private static func pixelContext(_ image: CGImage?, _ region: CGRect) -> CGContext? {
        let width = Int(region.width), height = Int(region.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        data.initializeMemory(as: UInt8.self, repeating: 0, count: context.bytesPerRow * height)
        if let image {
            guard let cropped = image.cropping(to: region) else { return nil }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }
}
