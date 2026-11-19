import CoreGraphics
import Foundation
import os
import simd
import SwiftUI

/// Blur brush: three box passes per axis (close to a Gaussian) of the layer under
/// the stroke, mixed through a feathered coverage mask.
///
/// The filtered layer is computed lazily in tiles that the mask touches, so the work
/// follows the stroke's shape rather than its bounding box. Committed replay
/// (`applyBlur`) and the live preview (`LiveBlurInk`) share tiles and mixing, so
/// lifting the finger does not change the picture. The filter always reads the
/// layer as it was before the gesture: overlapping segments never blur twice.
nonisolated enum WatchBlurFilter {
    /// Pixel rectangle; rows run top to bottom like the bitmap memory.
    struct PixelRect: Equatable {
        var x: Int, y: Int, width: Int, height: Int
        var maxX: Int { x + width }
        var maxY: Int { y + height }
        var isEmpty: Bool { width <= 0 || height <= 0 }
        var cgRect: CGRect { isEmpty ? .null : CGRect(x: x, y: y, width: width, height: height) }

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = max(0, width); self.height = max(0, height)
        }

        init(_ rect: CGRect) {
            guard !rect.isNull, !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite,
                  rect.maxX.isFinite, rect.maxY.isFinite else {
                self.init(x: 0, y: 0, width: 0, height: 0)
                return
            }
            let x0 = Int(max(-1e7, floor(rect.minX))), y0 = Int(max(-1e7, floor(rect.minY)))
            let x1 = Int(min(1e7, ceil(rect.maxX))), y1 = Int(min(1e7, ceil(rect.maxY)))
            self.init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        func outset(by amount: Int) -> PixelRect {
            PixelRect(x: x - amount, y: y - amount, width: width + 2 * amount, height: height + 2 * amount)
        }

        func intersection(_ other: PixelRect) -> PixelRect {
            let x0 = max(x, other.x), y0 = max(y, other.y)
            return PixelRect(x: x0, y: y0, width: min(maxX, other.maxX) - x0, height: min(maxY, other.maxY) - y0)
        }
    }

    struct Parameters: Equatable {
        let strength: Float
        /// Box radius of each of the three passes, in pixels.
        let boxRadius: Int
        /// Box radius softening the coverage edge, in pixels. The ramp is centred
        /// on the brush outline, so half strength sits under the cursor ring.
        let feather: Int
        let locksTransparency: Bool
        /// Source pixels the filter reads around an output pixel.
        var margin: Int { boxRadius * 3 }

        init(stroke: Stroke, scale: CGFloat) {
            let transform = stroke.transform.affine
            let pixels = scale * max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
            strength = stroke.style.effectiveBlurStrength
            let radius = min(512, max(1, CGFloat(stroke.style.effectiveBlurRadius) * pixels))
            // Three boxes of radius b spread like a Gaussian with σ ≈ √(b(b+1)), which
            // matches a single box of radius r (σ ≈ r/√3) when b ≈ r/√3.
            boxRadius = max(1, Int((radius / 3.squareRoot()).rounded()))
            let width = CGFloat(stroke.style.width) * pixels
            feather = max(1, min(64, Int((width.isFinite ? width : 1) * 0.15)))
            locksTransparency = stroke.locksTransparency
        }
    }

    /// Reusable scratch memory; grows to the largest request.
    final class Workspace {
        private var vectorStorage: UnsafeMutablePointer<SIMD4<Float>>?
        private var vectorCapacity = 0
        private var scalarStorage: UnsafeMutablePointer<Float>?
        private var scalarCapacity = 0

        deinit {
            vectorStorage?.deallocate()
            scalarStorage?.deallocate()
        }

        func vectors(_ count: Int) -> UnsafeMutablePointer<SIMD4<Float>> {
            if let vectorStorage, count <= vectorCapacity { return vectorStorage }
            vectorStorage?.deallocate()
            let storage = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: count)
            vectorStorage = storage
            vectorCapacity = count
            return storage
        }

        func scalars(_ count: Int) -> UnsafeMutablePointer<Float> {
            if let scalarStorage, count <= scalarCapacity { return scalarStorage }
            scalarStorage?.deallocate()
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
            scalarStorage = storage
            scalarCapacity = count
            return storage
        }
    }

    // MARK: Coverage

    /// One 8-bit channel: a quarter of an RGBA float mask, and enough for coverage.
    static func makeCoverageContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        data.initializeMemory(as: UInt8.self, repeating: 0, count: context.bytesPerRow * height)
        return context
    }

    /// Draws the command's shape as white coverage, ignoring its colour.
    static func fillCoverage(_ command: WatchDrawingCommand, in context: CGContext) {
        context.saveGState()
        WatchBitmapRenderer.exclude(command.exclusionPaths, from: context)
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
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

    /// Softens coverage stored for `domain` with a box of `radius` and writes `target`
    /// as rows of `target.width` values in 0…1. Inside the canvas, coverage outside
    /// `domain` is zero. Beyond the canvas edge the edge pixel repeats: the stroke
    /// continues off the paper, so edge pixels keep full strength instead of fading.
    static func feather(_ raw: UnsafePointer<UInt8>, stride: Int, domain: PixelRect, canvas: PixelRect,
                        target: PixelRect, radius: Int, into output: UnsafeMutablePointer<Float>,
                        workspace: Workspace) {
        let width = target.width, rows = target.height + 2 * radius
        guard width > 0, target.height > 0, !canvas.isEmpty else { return }
        let lines = workspace.scalars(width * (rows + 1))
        let sums = lines + width * rows
        for row in 0..<rows {
            let y = min(canvas.maxY - 1, max(canvas.y, target.y - radius + row))
            let line = lines + row * width
            guard y >= domain.y, y < domain.maxY else {
                line.update(repeating: 0, count: width)
                continue
            }
            let source = raw + (y - domain.y) * stride
            func value(_ position: Int) -> Int {
                let x = min(canvas.maxX - 1, max(canvas.x, position))
                return x >= domain.x && x < domain.maxX ? Int(source[x - domain.x]) : 0
            }
            var sum = 0
            for x in (target.x - radius)...(target.x + radius) { sum += value(x) }
            for i in 0..<width {
                line[i] = Float(sum)
                let x = target.x + i
                sum += value(x + radius + 1) - value(x - radius)
            }
        }
        // Integer sums stay below 2^24, so the vertical pass is exact in Float.
        let side = Float(2 * radius + 1)
        let normal = 1 / (side * side * 255)
        sums.update(repeating: 0, count: width)
        for row in 0...(2 * radius) {
            let line = lines + row * width
            for x in 0..<width { sums[x] += line[x] }
        }
        for y in 0..<target.height {
            let out = output + y * width
            for x in 0..<width { out[x] = min(1, sums[x] * normal) }
            let removed = lines + y * width
            for x in 0..<width { sums[x] -= removed[x] }
            if y + 2 * radius + 1 < rows {
                let added = lines + (y + 2 * radius + 1) * width
                for x in 0..<width { sums[x] += added[x] }
            }
        }
    }

    // MARK: Filter

    /// Filters `source` for `rect` into `output` (rows of `rect.width` pixels).
    /// Reads `rect` grown by three box radii; canvas edges renormalize.
    /// The result for a pixel does not depend on how its rectangle was chosen.
    static func blur(_ source: UnsafePointer<Float>, stride: Int, canvas: PixelRect, rect: PixelRect,
                     radius: Int, into output: UnsafeMutablePointer<SIMD4<Float>>,
                     workspace: Workspace) -> Bool {
        let region = rect.outset(by: 3 * radius).intersection(canvas)
        let width = region.width, height = region.height
        guard width > 0, height > 0 else { return true }
        let planes = workspace.vectors(2 * width * height + 3 * width)
        let first = planes, second = planes + width * height
        let rowA = second + width * height, rowB = rowA + width, sums = rowB + width
        for y in 0..<height {
            if y & 31 == 0, Task.isCancelled { return false }
            let line = source + (region.y + y) * stride + region.x * 4
            for x in 0..<width {
                let i = x * 4
                rowA[x] = SIMD4(line[i], line[i + 1], line[i + 2], line[i + 3])
            }
            boxRow(rowA, rowB, count: width, radius: radius)
            boxRow(rowB, rowA, count: width, radius: radius)
            boxRow(rowA, first + y * width, count: width, radius: radius)
        }
        guard !Task.isCancelled else { return false }
        boxColumns(first, second, width: width, height: height, radius: radius, sums: sums)
        boxColumns(second, first, width: width, height: height, radius: radius, sums: sums)
        guard !Task.isCancelled else { return false }
        boxColumns(first, second, width: width, height: height, radius: radius, sums: sums)
        let offsetX = rect.x - region.x, offsetY = rect.y - region.y
        for y in 0..<rect.height {
            (output + y * rect.width).update(from: second + (offsetY + y) * width + offsetX, count: rect.width)
        }
        return true
    }

    private static func boxRow(_ input: UnsafePointer<SIMD4<Float>>, _ output: UnsafeMutablePointer<SIMD4<Float>>,
                               count: Int, radius: Int) {
        var sum = SIMD4<Float>.zero
        for x in 0...min(radius, count - 1) { sum += input[x] }
        let inner = 1 / Float(2 * radius + 1)
        for x in 0..<count {
            let low = x - radius, high = x + radius
            let scale = low >= 0 && high < count ? inner : 1 / Float(min(count - 1, high) - max(0, low) + 1)
            output[x] = sum * scale
            if low >= 0 { sum -= input[low] }
            if high + 1 < count { sum += input[high + 1] }
        }
    }

    /// Vertical pass in row order: running sums per column keep memory access linear.
    private static func boxColumns(_ input: UnsafePointer<SIMD4<Float>>, _ output: UnsafeMutablePointer<SIMD4<Float>>,
                                   width: Int, height: Int, radius: Int, sums: UnsafeMutablePointer<SIMD4<Float>>) {
        sums.update(repeating: .zero, count: width)
        for y in 0...min(radius, height - 1) {
            let line = input + y * width
            for x in 0..<width { sums[x] += line[x] }
        }
        let inner = 1 / Float(2 * radius + 1)
        for y in 0..<height {
            let low = y - radius, high = y + radius
            let scale = low >= 0 && high < height ? inner : 1 / Float(min(height - 1, high) - max(0, low) + 1)
            let out = output + y * width
            for x in 0..<width { out[x] = sums[x] * scale }
            if low >= 0 {
                let line = input + low * width
                for x in 0..<width { sums[x] -= line[x] }
            }
            if high + 1 < height {
                let line = input + (high + 1) * width
                for x in 0..<width { sums[x] += line[x] }
            }
        }
    }

    // MARK: Tiles

    /// The filtered source, computed on demand for tiles under the coverage.
    final class Tiles {
        let source: UnsafePointer<Float>
        let stride: Int
        let canvas: PixelRect
        let radius: Int
        let tileWidth = 64
        let tileHeight: Int
        let columns: Int
        let rows: Int
        let workspace = Workspace()
        private var storage: [UnsafeMutablePointer<SIMD4<Float>>?]

        /// `source` must outlive the tiles and stay unchanged while they are used.
        init(source: UnsafePointer<Float>, stride: Int, width: Int, height: Int, radius: Int) {
            self.source = source
            self.stride = stride
            self.radius = radius
            canvas = PixelRect(x: 0, y: 0, width: width, height: height)
            // Taller bands amortize the vertical margin of large radii.
            tileHeight = max(64, min(256, 6 * radius))
            columns = (width + tileWidth - 1) / tileWidth
            rows = (height + tileHeight - 1) / tileHeight
            storage = Array(repeating: nil, count: columns * rows)
        }

        deinit { for tile in storage { tile?.deallocate() } }

        func rect(column: Int, row: Int) -> PixelRect {
            PixelRect(x: column * tileWidth, y: row * tileHeight,
                      width: tileWidth, height: tileHeight).intersection(canvas)
        }

        func tile(column: Int, row: Int) -> UnsafeMutablePointer<SIMD4<Float>>? {
            storage[row * columns + column]
        }

        /// Tiles with non-zero `coverage` (rows of `rect.width`) inside `rect`.
        func covered(by coverage: UnsafePointer<Float>, in rect: PixelRect) -> [Bool] {
            var needed = [Bool](repeating: false, count: columns * rows)
            guard !rect.isEmpty else { return needed }
            for y in rect.y..<rect.maxY {
                let row = y / tileHeight
                let line = coverage + (y - rect.y) * rect.width
                var x = rect.x
                while x < rect.maxX {
                    let column = x / tileWidth
                    let end = min(rect.maxX, (column + 1) * tileWidth)
                    if !needed[row * columns + column] {
                        for i in x..<end where line[i - rect.x] > 0 {
                            needed[row * columns + column] = true
                            break
                        }
                    }
                    x = end
                }
            }
            return needed
        }

        /// Filters missing `needed` tiles, joining neighbours in a row into one pass.
        func prepare(_ needed: [Bool]) -> Bool {
            for row in 0..<rows {
                var column = 0
                while column < columns {
                    guard needed[row * columns + column], storage[row * columns + column] == nil else {
                        column += 1
                        continue
                    }
                    var end = column + 1
                    while end < columns, needed[row * columns + end], storage[row * columns + end] == nil { end += 1 }
                    let first = rect(column: column, row: row), last = rect(column: end - 1, row: row)
                    let run = PixelRect(x: first.x, y: first.y, width: last.maxX - first.x, height: first.height)
                    let filtered = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: run.width * run.height)
                    defer { filtered.deallocate() }
                    guard WatchBlurFilter.blur(source, stride: stride, canvas: canvas, rect: run, radius: radius,
                                               into: filtered, workspace: workspace) else { return false }
                    for index in column..<end {
                        let part = rect(column: index, row: row)
                        let tile = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: tileWidth * tileHeight)
                        for y in 0..<part.height {
                            (tile + y * tileWidth).update(from: filtered + y * run.width + (part.x - run.x),
                                                          count: part.width)
                        }
                        storage[row * columns + index] = tile
                    }
                    column = end
                }
            }
            return true
        }
    }

    // MARK: Mixing

    /// A filtered low-resolution copy of the layer under a blur (`applyBlur(source:)`):
    /// premultiplied float pixels whose top-left corner is canvas point `origin`.
    final class LowSource {
        let pixels: UnsafeMutablePointer<SIMD4<Float>>
        let width: Int
        let height: Int
        let scale: CGFloat
        let origin: CGPoint

        init(pixels: UnsafeMutablePointer<SIMD4<Float>>, width: Int, height: Int, scale: CGFloat, origin: CGPoint) {
            self.pixels = pixels; self.width = width; self.height = height
            self.scale = scale; self.origin = origin
        }

        deinit { pixels.deallocate() }

        /// Bilinear sample at canvas point `point`; edges clamp.
        func sample(_ point: CGPoint) -> SIMD4<Float> {
            let u = Float((point.x - origin.x) * scale - 0.5), v = Float((point.y - origin.y) * scale - 0.5)
            let x0 = min(width - 1, max(0, Int(u.rounded(.down)))), y0 = min(height - 1, max(0, Int(v.rounded(.down))))
            let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
            let fx = min(1, max(0, u - Float(x0))), fy = min(1, max(0, v - Float(y0)))
            let top = pixels[y0 * width + x0] * (1 - fx) + pixels[y0 * width + x1] * fx
            let bottom = pixels[y1 * width + x0] * (1 - fx) + pixels[y1 * width + x1] * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// `mix` with the filtered values sampled from `source` instead of the raster's tiles.
    static func mixSampled(_ rect: PixelRect, coverage: UnsafePointer<Float>, source: LowSource,
                           scale: CGFloat, origin: CGPoint, pixels: UnsafeMutablePointer<Float>, stride: Int,
                           erasure: UnsafePointer<UInt8>?, erasureStride: Int, parameters: Parameters) {
        guard !rect.isEmpty else { return }
        for y in rect.y..<rect.maxY {
            let weights = coverage + (y - rect.y) * rect.width - rect.x
            let canvasY = origin.y + (CGFloat(y) + 0.5) / scale
            for x in rect.x..<rect.maxX {
                var amount = parameters.strength * weights[x]
                if let erasure, amount > 0 { amount *= Float(erasure[y * erasureStride + x]) / 255 }
                guard amount > 0 else { continue }
                let i = y * stride + x * 4
                let before = SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
                var after = source.sample(CGPoint(x: origin.x + (CGFloat(x) + 0.5) / scale, y: canvasY))
                if parameters.locksTransparency {
                    // Keep alpha exactly, including partially transparent edges.
                    if after.w > 0 { after *= before.w / after.w } else { after = before }
                    after.w = before.w
                }
                let mixed = simd_clamp(before + (after - before) * min(1, amount),
                                       SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1))
                for c in 0..<4 { pixels[i + c] = mixed[c] }
            }
        }
    }

    /// output = original + (filtered − original) × strength × coverage × erasure in `rect`.
    /// `output` may equal `original`: each pixel is read before it is written, and
    /// the tiles were filtered beforehand.
    static func mix(_ rect: PixelRect, coverage: UnsafePointer<Float>, tiles: Tiles,
                    original: UnsafePointer<Float>, originalStride: Int,
                    output: UnsafeMutablePointer<Float>, outputStride: Int,
                    erasure: UnsafePointer<UInt8>?, erasureStride: Int, parameters: Parameters) {
        guard !rect.isEmpty else { return }
        let copies = UnsafePointer(output) != original
        for row in (rect.y / tiles.tileHeight)...((rect.maxY - 1) / tiles.tileHeight) {
            for column in (rect.x / tiles.tileWidth)...((rect.maxX - 1) / tiles.tileWidth) {
                let part = tiles.rect(column: column, row: row).intersection(rect)
                guard !part.isEmpty else { continue }
                let filtered = tiles.tile(column: column, row: row)
                let tileX = column * tiles.tileWidth, tileY = row * tiles.tileHeight
                for y in part.y..<part.maxY {
                    let weights = coverage + (y - rect.y) * rect.width - rect.x
                    for x in part.x..<part.maxX {
                        let i = y * originalStride + x * 4
                        let o = y * outputStride + x * 4
                        var amount = parameters.strength * weights[x]
                        if let erasure, amount > 0 { amount *= Float(erasure[y * erasureStride + x]) / 255 }
                        guard amount > 0, let filtered else {
                            if copies { for c in 0..<4 { output[o + c] = original[i + c] } }
                            continue
                        }
                        let before = SIMD4(original[i], original[i + 1], original[i + 2], original[i + 3])
                        var after = filtered[(y - tileY) * tiles.tileWidth + (x - tileX)]
                        if parameters.locksTransparency {
                            // Keep alpha exactly, including partially transparent edges.
                            if after.w > 0 { after *= before.w / after.w } else { after = before }
                            after.w = before.w
                        }
                        let mixed = simd_clamp(before + (after - before) * min(1, amount),
                                               SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1))
                        for c in 0..<4 { output[o + c] = mixed[c] }
                    }
                }
            }
        }
    }
}

nonisolated extension WatchBitmapRenderer {
    /// What a blur in part of the canvas (a zoom tile, a save strip) needs to read the
    /// layer beyond that part. `before`: the layer's strokes ahead of those being replayed
    /// (the caller's input). `layer` and `index`: the whole layer in drawing order and the
    /// blur's position in it, filled in by `renderInk`.
    struct BlurSourceContext {
        let before: [Stroke]
        let paper: CGSize
        var layer: [Stroke] = []
        var index = 0
    }

    /// Committed blur stroke over the ink already in `context`.
    ///
    /// With `source`, a raster that is only part of the canvas (or is zoomed far in)
    /// filters a separate low-resolution render of the layer under the blur instead of
    /// its own pixels, as Inkscape and Skia do for large blurs: the blur reads its whole
    /// reach, so neighbouring tiles agree and show no seams, and its cost and radius no
    /// longer depend on the zoom. The result is smooth, so its resolution does not show;
    /// sharp ink around it stays at the raster's resolution.
    static func applyBlur(_ stroke: Stroke, in context: CGContext, scale: CGFloat,
                          erasure: CGContext?, origin: CGPoint = .zero,
                          source: BlurSourceContext? = nil) -> Bool {
        typealias Filter = WatchBlurFilter
        let parameters = Filter.Parameters(stroke: stroke, scale: scale)
        guard parameters.strength > 0, !stroke.points.isEmpty else { return true }
        guard let geometry = try? StrokeGeometry(stroke), let data = context.data else { return false }
        let canvas = Filter.PixelRect(x: 0, y: 0, width: context.width, height: context.height)
        // Top-left pixels of the raster; a viewport region starts at canvas point `origin`.
        let toPixels = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: -origin.x * scale, ty: -origin.y * scale)
        let drawn = Filter.PixelRect(geometry.bounds.applying(toPixels))
            .outset(by: 1).intersection(canvas)
        guard !drawn.isEmpty else { return true }
        guard let mask = Filter.makeCoverageContext(width: drawn.width, height: drawn.height),
              let maskData = mask.data else { return false }
        mask.translateBy(x: -CGFloat(drawn.x), y: CGFloat(drawn.height + drawn.y))
        mask.scaleBy(x: scale, y: -scale)
        mask.translateBy(x: -origin.x, y: -origin.y)
        for command in geometry.commands { Filter.fillCoverage(command, in: mask) }
        let area = drawn.outset(by: parameters.feather).intersection(canvas)
        let pixels = data.assumingMemoryBound(to: Float.self)
        let stride = context.bytesPerRow / MemoryLayout<Float>.size
        if let source, case let .use(low) = lowResolutionSource(for: stroke, area: area, canvas: canvas, scale: scale,
                                                               origin: origin, parameters: parameters, context: source) {
            guard let lowSource = low else { return true }
            let coverage = UnsafeMutablePointer<Float>.allocate(capacity: area.width * area.height)
            defer { coverage.deallocate() }
            let workspace = Filter.Workspace()
            Filter.feather(maskData.assumingMemoryBound(to: UInt8.self), stride: mask.bytesPerRow, domain: drawn,
                           canvas: canvas, target: area, radius: parameters.feather, into: coverage,
                           workspace: workspace)
            Filter.mixSampled(area, coverage: coverage, source: lowSource, scale: scale, origin: origin,
                              pixels: pixels, stride: stride,
                              erasure: erasure?.data?.assumingMemoryBound(to: UInt8.self),
                              erasureStride: erasure?.bytesPerRow ?? 0, parameters: parameters)
            return true
        }
        let tiles = Filter.Tiles(source: pixels, stride: stride, width: canvas.width, height: canvas.height,
                                 radius: parameters.boxRadius)
        let coverage = UnsafeMutablePointer<Float>.allocate(capacity: area.width * area.height)
        defer { coverage.deallocate() }
        Filter.feather(maskData.assumingMemoryBound(to: UInt8.self), stride: mask.bytesPerRow, domain: drawn,
                       canvas: canvas, target: area, radius: parameters.feather, into: coverage, workspace: tiles.workspace)
        guard tiles.prepare(tiles.covered(by: coverage, in: area)) else { return false }
        Filter.mix(area, coverage: coverage, tiles: tiles, original: pixels, originalStride: stride,
                   output: pixels, outputStride: stride,
                   erasure: erasure?.data?.assumingMemoryBound(to: UInt8.self),
                   erasureStride: erasure?.bytesPerRow ?? 0, parameters: parameters)
        return true
    }

    private enum LowSourceChoice {
        /// The raster holds everything the blur reads, at a modest resolution: filter it.
        case filterRaster
        /// Mix from this source; nil when there is no ink under the blur (nothing to do).
        case use(WatchBlurFilter.LowSource?)
    }

    /// The low resolution every blur of a layer shares: just fine enough for its
    /// smallest radius (~4 px per box pass), on the tile ladder so nearby scales share
    /// blocks. No floor at the saved grid: a filtered layer is smooth, so a 17 pt blur
    /// needs ~0.5 px per point, not 2. With a floor of 2, Pixels mode (tiles at 2 px/pt)
    /// gained nothing from the source and only paid for it.
    private static func layerLowScale(_ layer: [Stroke]) -> CGFloat {
        let radii = layer.lazy.filter { $0.style.instrument == .blur }.map { stroke -> CGFloat in
            let transform = stroke.transform.affine
            return CGFloat(stroke.style.effectiveBlurRadius)
                * max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        }
        let smallest = radii.min() ?? 30
        return pow(2, (log2(min(64, max(0.25, 7 / max(0.1, smallest)))) * 2).rounded(.up) / 2)
    }

    /// Hash of `layer[..<count]`: what a blur at `count` reads.
    private static func prefixHash(_ layer: [Stroke], count: Int) -> Int {
        var hasher = Hasher()
        for stroke in layer[..<count] {
            hasher.combine(stroke.id)
            hasher.combine(stroke.geometryRevision)
            hasher.combine(stroke.locksTransparency)
        }
        return hasher.finalize()
    }

    /// The filtered layer under a blur, at low resolution, for the pixels of `area`.
    ///
    /// The low-resolution grid is fixed per layer (not per tile) and filtered in blocks
    /// of `BlurSourceCache.blockPixels` that every tile and strip shares through the
    /// cache. A missing block is made by one low-resolution replay of the layer that
    /// filters every blur's block on the way (`fillLayerBlocks`): before, each blur
    /// replayed all strokes under it, and a layer of 15 blurs took seconds to redraw.
    private static func lowResolutionSource(for stroke: Stroke, area: WatchBlurFilter.PixelRect,
                                            canvas: WatchBlurFilter.PixelRect, scale: CGFloat, origin: CGPoint,
                                            parameters: WatchBlurFilter.Parameters,
                                            context: BlurSourceContext) -> LowSourceChoice {
        typealias Filter = WatchBlurFilter
        let paper = CGRect(origin: .zero, size: context.paper)
        guard !paper.isEmpty, !area.isEmpty, context.index < context.layer.count else { return .filterRaster }
        let raster = CGRect(x: origin.x, y: origin.y,
                            width: CGFloat(canvas.width) / scale, height: CGFloat(canvas.height) / scale)
        let output = CGRect(x: origin.x + CGFloat(area.x) / scale, y: origin.y + CGFloat(area.y) / scale,
                            width: CGFloat(area.width) / scale, height: CGFloat(area.height) / scale)
        let reads = output.insetBy(dx: -CGFloat(parameters.margin) / scale, dy: -CGFloat(parameters.margin) / scale)
            .intersection(paper)
        let lowScale = min(scale, layerLowScale(context.layer))
        let readsOutside = !raster.insetBy(dx: -0.01, dy: -0.01).contains(reads)
        guard readsOutside || scale > lowScale * 1.5 else { return .filterRaster }
        let low = Filter.Parameters(stroke: stroke, scale: lowScale)
        let paperWidth = Int(ceil(context.paper.width * lowScale))
        let paperHeight = Int(ceil(context.paper.height * lowScale))
        let paperPixels = Filter.PixelRect(x: 0, y: 0, width: paperWidth, height: paperHeight)
        // Low pixels under the output, plus one for bilinear sampling.
        let needed = Filter.PixelRect(output.applying(CGAffineTransform(scaleX: lowScale, y: lowScale)))
            .outset(by: 1).intersection(paperPixels)
        guard !needed.isEmpty else { return .use(nil) }
        let hash = prefixHash(context.layer, count: context.index)
        let side = BlurSourceCache.blockPixels
        let pixels = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: needed.width * needed.height)
        pixels.initialize(repeating: .zero, count: needed.width * needed.height)
        let assembled = Filter.LowSource(pixels: pixels, width: needed.width, height: needed.height, scale: lowScale,
                                         origin: CGPoint(x: CGFloat(needed.x) / lowScale,
                                                         y: CGFloat(needed.y) / lowScale))
        var anyInk = false
        for row in (needed.y / side)...((needed.maxY - 1) / side) {
            for column in (needed.x / side)...((needed.maxX - 1) / side) {
                guard !Task.isCancelled else { return .filterRaster }
                let key = BlurSourceCache.Key(prefix: hash, prefixCount: context.index,
                                              boxRadius: low.boxRadius, lowScale: Double(lowScale),
                                              paperWidth: paperWidth, paperHeight: paperHeight,
                                              column: column, row: row)
                let block = Filter.PixelRect(x: column * side, y: row * side, width: side, height: side)
                    .intersection(paperPixels)
                guard !block.isEmpty else { continue }
                let found: BlurSourceCache.Block? = BlurSourceCache.shared.block(for: key)
                    ?? BlurSourceCache.computing { () -> BlurSourceCache.Block? in
                        // Another tile may have made it while this one waited.
                        if let cached = BlurSourceCache.shared.block(for: key) { return cached }
                        // Through the layer's last blur: one replay fills every blur's block here.
                        let last = context.layer.lastIndex { $0.style.instrument == .blur } ?? context.index
                        guard fillLayerBlocks(block, column: column, row: row, upTo: max(last, context.index),
                                              lowScale: lowScale, paperPixels: paperPixels, context: context)
                        else { return nil }
                        return BlurSourceCache.shared.block(for: key)
                    }
                guard let filtered = found else { return .filterRaster }
                guard filtered.hasInk else { continue }
                anyInk = true
                let part = block.intersection(needed)
                guard !part.isEmpty else { continue }
                filtered.pixels.withUnsafeBufferPointer { source in
                    for y in part.y..<part.maxY {
                        let from = source.baseAddress! + (y - block.y) * block.width + (part.x - block.x)
                        let to = pixels + (y - needed.y) * needed.width + (part.x - needed.x)
                        for x in 0..<part.width { to[x] = SIMD4<Float>(from[x]) / 255 }
                    }
                }
            }
        }
        return .use(anyInk ? assembled : nil)
    }

    /// One low-resolution replay of the layer over `block` plus the widest blur reach,
    /// through the blur at `last`: at each blur on the way the ink so far is filtered for
    /// the block and cached under that blur's key, then the blur is applied (to this
    /// render itself) so later blurs read its result. Blurs that cannot reach the block
    /// cache an empty entry. False when rendering failed or was cancelled.
    private static func fillLayerBlocks(_ block: WatchBlurFilter.PixelRect, column: Int, row: Int, upTo last: Int,
                                        lowScale: CGFloat, paperPixels: WatchBlurFilter.PixelRect,
                                        context: BlurSourceContext) -> Bool {
        typealias Filter = WatchBlurFilter
        let layer = context.layer
        let blurs = layer.indices.filter { $0 <= last && layer[$0].style.instrument == .blur }
        let parameters = Dictionary(uniqueKeysWithValues: blurs.map {
            ($0, Filter.Parameters(stroke: layer[$0], scale: lowScale))
        })
        let margin = (parameters.values.map(\.margin).max() ?? 0) + 2
        let rendered = block.outset(by: margin).intersection(paperPixels)
        let region = regionGeometry(pixels: rendered.cgRect, scale: lowScale)
        let blockPoints = CGRect(x: CGFloat(block.x) / lowScale, y: CGFloat(block.y) / lowScale,
                                 width: CGFloat(block.width) / lowScale, height: CGFloat(block.height) / lowScale)
        let local = Filter.PixelRect(x: block.x - rendered.x, y: block.y - rendered.y,
                                     width: block.width, height: block.height)
        let whole = Filter.PixelRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        let workspace = Filter.Workspace()
        var hasher = Hasher()
        var hashed = 0
        var ink: InkSnapshot?
        var start = 0
        for index in blurs {
            guard !Task.isCancelled else { return false }
            // The strokes since the previous blur, that blur included (applied to this render).
            if index > start {
                guard let next = renderInk(strokes: Array(layer[start..<index]), size: region.size, scale: lowScale,
                                           base: ink, origin: region.origin, cullsOutside: true) else { return false }
                ink = next
                start = index
            }
            while hashed < index {
                hasher.combine(layer[hashed].id)
                hasher.combine(layer[hashed].geometryRevision)
                hasher.combine(layer[hashed].locksTransparency)
                hashed += 1
            }
            var finished = hasher
            let blurParameters = parameters[index]!
            let key = BlurSourceCache.Key(prefix: finished.finalize(), prefixCount: index,
                                          boxRadius: blurParameters.boxRadius, lowScale: Double(lowScale),
                                          paperWidth: paperPixels.width, paperHeight: paperPixels.height,
                                          column: column, row: row)
            guard BlurSourceCache.shared.block(for: key) == nil else { continue }
            // A blur reaching neither the block nor a sample beside it never reads it.
            let reach = WatchBitmapRenderer.reach(of: layer[index])
                .insetBy(dx: -2 / lowScale, dy: -2 / lowScale)
            guard reach.intersects(blockPoints), let current = ink,
                  current.image.width == rendered.width, current.image.height == rendered.height,
                  let data = current.image.dataProvider?.data as Data? else {
                BlurSourceCache.shared.store(BlurSourceCache.Block(pixels: [], hasInk: false), for: key)
                continue
            }
            let inkStride = current.image.bytesPerRow / MemoryLayout<Float>.size
            var filtered = [SIMD4<Float>](repeating: .zero, count: block.width * block.height)
            let succeeded = data.withUnsafeBytes { bytes in
                filtered.withUnsafeMutableBufferPointer { output in
                    Filter.blur(bytes.bindMemory(to: Float.self).baseAddress!, stride: inkStride, canvas: whole,
                                rect: local, radius: blurParameters.boxRadius, into: output.baseAddress!,
                                workspace: workspace)
                }
            }
            guard succeeded else { return false }
            // 8 bits per channel: a quarter of the memory, so a layer's blurs fit the cache
            // together. The filtered layer is smooth and the result is 8-bit anyway.
            let quantized = filtered.map {
                SIMD4<UInt8>(simd_clamp($0 * 255, SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 255))
                    .rounded(.toNearestOrAwayFromZero))
            }
            BlurSourceCache.shared.store(BlurSourceCache.Block(pixels: quantized, hasInk: true), for: key)
        }
        return true
    }

    /// Live blur stroke over committed ink, extended by its new samples only.
    /// The layer under the gesture is filtered once per tile the brush reaches;
    /// each update draws the new segment into the coverage mask and mixes only
    /// the changed rectangle. The committed stroke is replayed whole on lift.
    final class LiveBlurInk: WatchLiveInk {
        let frame: CGContext
        let base: CGImage
        let scale: CGFloat
        private(set) var stroke: Stroke
        private let backdrop: CGContext
        private let coverage: CGContext
        private var parameters: WatchBlurFilter.Parameters
        private var tiles: WatchBlurFilter.Tiles
        private var weights: UnsafeMutablePointer<Float>?
        private var weightsCapacity = 0

        static func supports(_ stroke: Stroke) -> Bool {
            stroke.style.instrument == .blur && !stroke.points.isEmpty
                && stroke.transform == .identity && stroke.excludedAreas.isEmpty
                && stroke.erasures.isEmpty && stroke.raster == nil
        }

        init?(stroke: Stroke, base: CGImage, scale: CGFloat) {
            let width = base.width, height = base.height
            guard Self.supports(stroke), width > 0, height > 0,
                  let frame = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                  let backdrop = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                  let coverage = WatchBlurFilter.makeCoverageContext(width: width, height: height),
                  frame.data != nil, let source = backdrop.data
            else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            backdrop.draw(base, in: bounds)
            frame.draw(base, in: bounds)
            coverage.translateBy(x: 0, y: CGFloat(height))
            coverage.scaleBy(x: scale, y: -scale)
            self.frame = frame
            self.backdrop = backdrop
            self.coverage = coverage
            self.base = base
            self.scale = scale
            self.stroke = stroke
            parameters = WatchBlurFilter.Parameters(stroke: stroke, scale: scale)
            tiles = WatchBlurFilter.Tiles(source: source.assumingMemoryBound(to: Float.self),
                                          stride: backdrop.bytesPerRow / MemoryLayout<Float>.size,
                                          width: width, height: height, radius: parameters.boxRadius)
            guard redraw(stroke) else { return nil }
        }

        deinit { weights?.deallocate() }

        private var canvas: WatchBlurFilter.PixelRect {
            WatchBlurFilter.PixelRect(x: 0, y: 0, width: frame.width, height: frame.height)
        }

        /// Pixel rectangle (rows top to bottom) changed by `next`; the whole frame
        /// when it had to be redrawn. nil when this buffer cannot show `next`.
        func update(_ next: Stroke) -> CGRect? {
            guard Self.supports(next), next.id == stroke.id else { return nil }
            guard next.extends(stroke) else {
                return redraw(next) ? canvas.cgRect : nil
            }
            let drawn = stroke.points.count
            stroke = next
            guard next.points.count > drawn, drawn > 0 else { return .null }
            let path = CGMutablePath()
            path.move(to: CGPoint(next.points[drawn - 1].position))
            for sample in next.points[drawn...] { path.addLine(to: CGPoint(sample.position)) }
            let width = CGFloat(next.style.width)
            coverage.saveGState()
            coverage.setStrokeColor(gray: 1, alpha: 1)
            coverage.setLineWidth(width)
            coverage.setLineCap(.round)
            coverage.setLineJoin(.round)
            coverage.addPath(path)
            coverage.strokePath()
            coverage.restoreGState()
            // Paper space to pixels: y already runs down in both.
            let changed = WatchBlurFilter.PixelRect(path.boundingBoxOfPath
                .insetBy(dx: -width / 2, dy: -width / 2)
                .applying(CGAffineTransform(scaleX: scale, y: scale))).outset(by: 2)
            return refresh(changed)
        }

        private func redraw(_ next: Stroke) -> Bool {
            stroke = next
            let updated = WatchBlurFilter.Parameters(stroke: next, scale: scale)
            if updated.boxRadius != tiles.radius {
                tiles = WatchBlurFilter.Tiles(source: tiles.source, stride: tiles.stride,
                                              width: frame.width, height: frame.height, radius: updated.boxRadius)
            }
            parameters = updated
            coverage.data?.initializeMemory(as: UInt8.self, repeating: 0,
                                            count: coverage.bytesPerRow * coverage.height)
            for command in WatchStrokeDrawing.commands(for: next) {
                WatchBlurFilter.fillCoverage(command, in: coverage)
            }
            return refresh(canvas) != nil
        }

        /// Re-mixes the pixels whose feathered coverage depends on `changed`.
        private func refresh(_ changed: WatchBlurFilter.PixelRect) -> CGRect? {
            let area = changed.outset(by: parameters.feather).intersection(canvas)
            guard !area.isEmpty else { return .null }
            guard let raw = coverage.data?.assumingMemoryBound(to: UInt8.self),
                  let output = frame.data?.assumingMemoryBound(to: Float.self) else { return nil }
            let count = area.width * area.height
            if count > weightsCapacity {
                weights?.deallocate()
                weights = .allocate(capacity: count)
                weightsCapacity = count
            }
            guard let weights else { return nil }
            WatchBlurFilter.feather(raw, stride: coverage.bytesPerRow, domain: canvas, canvas: canvas, target: area,
                                    radius: parameters.feather, into: weights, workspace: tiles.workspace)
            guard tiles.prepare(tiles.covered(by: weights, in: area)) else { return nil }
            WatchBlurFilter.mix(area, coverage: weights, tiles: tiles,
                                original: tiles.source, originalStride: tiles.stride,
                                output: output, outputStride: frame.bytesPerRow / MemoryLayout<Float>.size,
                                erasure: nil, erasureStride: 0, parameters: parameters)
            return area.cgRect
        }
    }
}

/// A live stroke buffer that the bitmap cache extends frame by frame.
nonisolated protocol WatchLiveInk: AnyObject {
    var frame: CGContext { get }
    var base: CGImage { get }
    var scale: CGFloat { get }
    /// Changed pixel rectangle (rows top to bottom), `.null` when nothing changed,
    /// nil when this buffer cannot show `next`.
    func update(_ next: Stroke) -> CGRect?
}

nonisolated extension WatchBitmapRenderer.LivePenInk: WatchLiveInk {}

nonisolated private extension CGPoint {
    init(_ point: SIMD2<Float>) { self.init(x: CGFloat(point.x), y: CGFloat(point.y)) }
}

/// Filtered low-resolution blocks of the layer under blurs, shared by every tile, strip
/// and renderer (each on its own thread). Keyed by what the block depends on: the layer's
/// strokes before the blur, the filter radius, the low scale and the paper; least
/// recently used blocks go first beyond `byteLimit`.
nonisolated final class BlurSourceCache: @unchecked Sendable {
    static let shared = BlurSourceCache()
    /// Low pixels per block side. Each block also renders its read margin (~100 px around
    /// for a large blur at 2 px/pt): at 128 that was ~9× the block's own pixels, at 256 ~3×.
    static let blockPixels = 256
    /// A share of what this device leaves the app (as `LayerCache.inkByteLimit`), 8–24 MB
    /// (32 to 96 blocks of 256 KB), fixed at first use.
    static let byteLimit: Int = {
        let ceiling = 24 * 1024 * 1024, minimum = 8 * 1024 * 1024
        guard let available = availableMemory else { return ceiling }
        return min(ceiling, max(minimum, available / 10))
    }()

    /// Bytes left before the app's limit; nil without one (Simulator, macOS checks).
    static var availableMemory: Int? {
        #if targetEnvironment(simulator) || os(macOS)
        return nil
        #else
        return Int(os_proc_available_memory())
        #endif
    }

    /// Below this much room, blocks are computed one at a time instead of by every tile
    /// at once: each holds a float render of its area (and one per nested blur) meanwhile.
    static let serialComputeThreshold = 64 * 1024 * 1024
    /// Recursive: a block's render computes the blocks of blurs below it on the same thread.
    private static let computeLock = NSRecursiveLock()

    /// Runs `work` alone when memory is short; otherwise concurrently with other tiles.
    static func computing<T>(_ work: () -> T) -> T {
        guard let available = availableMemory, available < serialComputeThreshold else { return work() }
        computeLock.lock(); defer { computeLock.unlock() }
        return work()
    }

    struct Key: Hashable {
        let prefix: Int
        let prefixCount: Int
        let boxRadius: Int
        let lowScale: Double
        let paperWidth: Int
        let paperHeight: Int
        let column: Int
        let row: Int
    }

    final class Block {
        /// Premultiplied 8-bit RGBA, rows of the block's width; empty when `hasInk` is false.
        let pixels: [SIMD4<UInt8>]
        let hasInk: Bool
        var bytes: Int { pixels.count * MemoryLayout<SIMD4<UInt8>>.stride + 64 }

        init(pixels: [SIMD4<UInt8>], hasInk: Bool) {
            self.pixels = pixels
            self.hasInk = hasInk
        }
    }

    private let lock = NSLock()
    private var blocks: [Key: (block: Block, access: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0

    func block(for key: Key) -> Block? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = blocks[key] else { return nil }
        clock &+= 1
        blocks[key] = (entry.block, clock)
        return entry.block
    }

    func store(_ block: Block, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        if let old = blocks.updateValue((block, clock), forKey: key) { bytes -= old.block.bytes }
        bytes += block.bytes
        while bytes > Self.byteLimit, blocks.count > 1,
              let oldest = blocks.min(by: { $0.value.access < $1.value.access })?.key,
              let removed = blocks.removeValue(forKey: oldest) {
            bytes -= removed.block.bytes
        }
    }

    /// Dropped with the canvas's other caches when a save needs the memory.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        blocks.removeAll()
        bytes = 0
    }
}
