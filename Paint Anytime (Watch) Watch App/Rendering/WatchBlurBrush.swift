import CoreGraphics
import Foundation
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

    /// output = original + (filtered − original) × strength × coverage × erasure in `rect`.
    /// `output` may equal `original`: each pixel is read before it is written, and
    /// the tiles were filtered beforehand.
    static func mix(_ rect: PixelRect, coverage: UnsafePointer<Float>, tiles: Tiles,
                    original: UnsafePointer<Float>, originalStride: Int,
                    output: UnsafeMutablePointer<Float>, outputStride: Int,
                    erasure: UnsafePointer<Float>?, erasureStride: Int, parameters: Parameters) {
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
                        if let erasure, amount > 0 { amount *= erasure[y * erasureStride + x * 4 + 3] }
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
    /// Committed blur stroke over the ink already in `context`.
    static func applyBlur(_ stroke: Stroke, in context: CGContext, scale: CGFloat,
                          erasure: CGContext?) -> Bool {
        typealias Filter = WatchBlurFilter
        let parameters = Filter.Parameters(stroke: stroke, scale: scale)
        guard parameters.strength > 0, !stroke.points.isEmpty else { return true }
        guard let geometry = try? StrokeGeometry(stroke), let data = context.data else { return false }
        let canvas = Filter.PixelRect(x: 0, y: 0, width: context.width, height: context.height)
        let drawn = Filter.PixelRect(geometry.bounds.applying(CGAffineTransform(scaleX: scale, y: scale)))
            .outset(by: 1).intersection(canvas)
        guard !drawn.isEmpty else { return true }
        guard let mask = Filter.makeCoverageContext(width: drawn.width, height: drawn.height),
              let maskData = mask.data else { return false }
        mask.translateBy(x: -CGFloat(drawn.x), y: CGFloat(drawn.height + drawn.y))
        mask.scaleBy(x: scale, y: -scale)
        for command in geometry.commands { Filter.fillCoverage(command, in: mask) }
        let area = drawn.outset(by: parameters.feather).intersection(canvas)
        let pixels = data.assumingMemoryBound(to: Float.self)
        let stride = context.bytesPerRow / MemoryLayout<Float>.size
        let tiles = Filter.Tiles(source: pixels, stride: stride, width: canvas.width, height: canvas.height,
                                 radius: parameters.boxRadius)
        let coverage = UnsafeMutablePointer<Float>.allocate(capacity: area.width * area.height)
        defer { coverage.deallocate() }
        Filter.feather(maskData.assumingMemoryBound(to: UInt8.self), stride: mask.bytesPerRow, domain: drawn,
                       canvas: canvas, target: area, radius: parameters.feather, into: coverage, workspace: tiles.workspace)
        guard tiles.prepare(tiles.covered(by: coverage, in: area)) else { return false }
        Filter.mix(area, coverage: coverage, tiles: tiles, original: pixels, originalStride: stride,
                   output: pixels, outputStride: stride,
                   erasure: erasure?.data?.assumingMemoryBound(to: Float.self),
                   erasureStride: (erasure?.bytesPerRow ?? 0) / MemoryLayout<Float>.size, parameters: parameters)
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

private extension CGPoint {
    init(_ point: SIMD2<Float>) { self.init(x: CGFloat(point.x), y: CGFloat(point.y)) }
}
