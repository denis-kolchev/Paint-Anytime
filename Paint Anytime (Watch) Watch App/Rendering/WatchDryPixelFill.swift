import CoreGraphics
import simd

nonisolated extension WatchStrokeDrawing {
    /// Pixel fill of incremental pencil/pastel grains (Render debug → Pixel dry fill),
    /// replacing Core Graphics path fills of thousands of ~1 px quads.
    ///
    /// It reproduces what `DryGrainField.draw` + `renderIncrementalDry` produce with CG:
    /// - each of the 9 bands is one path of grain quads filled with the ink colour at the
    ///   band's opacity; quads of a band overlap as a union (same winding), so a band's
    ///   coverage is the area of that union in the pixel. Here: 8×8 sample masks per pixel
    ///   and band, OR-ed per quad, coverage = set samples / 64;
    /// - the bands are drawn source-over in one colour, so the stroke layer's alpha is
    ///   1 − Π(1 − coverage·alpha) whatever their order;
    /// - that layer is composited over the committed ink at the stroke opacity.
    /// The only difference from CG is its antialiasing estimate (within about 1/64 of
    /// coverage per pixel). Committed replay (Undo past snapshots, export) still uses CG.
    ///
    /// Every pixel of a work box is recomputed from the committed ink and all grains that
    /// reach it, so overlapping or repeated boxes give the same result.
    final class DryPixelFill {
        static let bandCount = 9
        /// Committed ink under the gesture, copied once from the float frame.
        private let base: UnsafeMutableRawPointer
        private let baseBytesPerRow: Int
        private let height: Int
        private var masks: UnsafeMutablePointer<UInt64>
        private var capacity = 0
        /// Current work box in pixels (top-left origin).
        private(set) var boxX = 0, boxY = 0, boxWidth = 0, boxHeight = 0

        /// Copies the frame's current pixels as the committed ink; nil unless the frame
        /// is a float RGBA bitmap.
        init?(frame: CGContext) {
            guard let data = frame.data, frame.bitsPerPixel == 128, frame.bitsPerComponent == 32
            else { return nil }
            baseBytesPerRow = frame.bytesPerRow
            height = frame.height
            base = .allocate(byteCount: baseBytesPerRow * height, alignment: 16)
            base.copyMemory(from: data, byteCount: baseBytesPerRow * height)
            masks = .allocate(capacity: 1)
            capacity = 1
        }

        deinit {
            base.deallocate()
            masks.deallocate()
        }

        /// Start a work box; clears its masks.
        func reset(x: Int, y: Int, width: Int, height: Int) {
            let needed = Self.bandCount * width * height
            if needed > capacity {
                masks.deallocate()
                masks = .allocate(capacity: needed)
                capacity = needed
            }
            masks.update(repeating: 0, count: needed)
            boxX = x; boxY = y; boxWidth = width; boxHeight = height
        }

        /// Add a convex grain quad (pixel coordinates) to `band`'s sample masks, clipped
        /// to the work box. Samples sit at (i + 0.5) / 8 of a pixel.
        func addQuad(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>, band: Int) {
            let minY = min(min(a.y, b.y), min(c.y, d.y)), maxY = max(max(a.y, b.y), max(c.y, d.y))
            let t0 = max(Int((minY * 8 - 0.5).rounded(.up)), boxY * 8)
            let t1 = min(Int((maxY * 8 - 0.5).rounded(.up)) - 1, (boxY + boxHeight) * 8 - 1)
            guard t0 <= t1 else { return }
            let sampleMinX = boxX * 8, sampleMaxX = (boxX + boxWidth) * 8 - 1
            let plane = boxWidth * boxHeight
            let bandBase = masks + band * plane
            for t in t0...t1 {
                let sy = (Float(t) + 0.5) / 8
                var low = Float.infinity, high = -Float.infinity
                Self.cross(a, b, sy, &low, &high)
                Self.cross(b, c, sy, &low, &high)
                Self.cross(c, d, sy, &low, &high)
                Self.cross(d, a, sy, &low, &high)
                guard low < high else { continue }
                // Samples whose centre lies in [low, high).
                let s0 = max(Int((low * 8 - 0.5).rounded(.up)), sampleMinX)
                let s1 = min(Int((high * 8 - 0.5).rounded(.up)) - 1, sampleMaxX)
                guard s0 <= s1 else { continue }
                let rowMasks = bandBase + ((t >> 3) - boxY) * boxWidth
                let shift = UInt64((t & 7) * 8)
                var s = s0
                while s <= s1 {
                    let pixel = s >> 3
                    let first = s & 7
                    let last = min(7, s1 - (pixel << 3))
                    let bits = (UInt64(0xFF) >> UInt64(7 - last)) & (UInt64(0xFF) << UInt64(first))
                    rowMasks[pixel - boxX] |= bits << shift
                    s = (pixel + 1) << 3
                }
            }
        }

        /// x where edge p→q crosses the sample row `y` (half-open in y, so a vertex on the
        /// row counts once per side).
        @inline(__always)
        private static func cross(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ y: Float,
                                  _ low: inout Float, _ high: inout Float) {
            guard (p.y <= y) != (q.y <= y) else { return }
            let x = p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x)
            low = min(low, x)
            high = max(high, x)
        }

        /// Recompute every 32 px tile the changed pixel rectangles (top-left origin) touch:
        /// the box around the changes in each tile, from the committed ink and all grains of
        /// `field`. Call after `field.update`. Returns the tiles written, or nil if cancelled.
        func fillChanged(_ pixels: [CGRect], field: DryGrainField, stroke: Stroke, geometry: DryGeometry,
                         frame: CGContext, scale: CGFloat)
            -> (tiles: [SIMD2<Int>], grains: Int, rasterNS: UInt64, compositeNS: UInt64)? {
            let tileSize = 32
            // Bounding box (min x, min y, max x, max y; exclusive) of the changes in each tile.
            var boxes: [SIMD2<Int>: SIMD4<Int>] = [:]
            for rect in pixels {
                let minX = Int(rect.minX), minY = Int(rect.minY), maxX = Int(rect.maxX), maxY = Int(rect.maxY)
                guard minX >= 0, minY >= 0, minX < maxX, minY < maxY else { continue }
                for tileY in (minY / tileSize)...((maxY - 1) / tileSize) {
                    for tileX in (minX / tileSize)...((maxX - 1) / tileSize) {
                        let part = SIMD4(max(minX, tileX * tileSize), max(minY, tileY * tileSize),
                                         min(maxX, (tileX + 1) * tileSize), min(maxY, (tileY + 1) * tileSize))
                        let tile = SIMD2(tileX, tileY)
                        if let box = boxes[tile] {
                            boxes[tile] = SIMD4(min(box.x, part.x), min(box.y, part.y),
                                                max(box.z, part.z), max(box.w, part.w))
                        } else {
                            boxes[tile] = part
                        }
                    }
                }
            }
            let ink = stroke.style.color
            let alphas = field.bandOpacities(stroke, geometry: geometry).map { Float($0) * ink.w }
            let opacity = stroke.style.effectiveOpacity
            var rasterNS: UInt64 = 0, compositeNS: UInt64 = 0
            var grains = 0
            for box in boxes.values {
                guard !Task.isCancelled else { return nil }
                let started = RenderDiagnostics.begin()
                reset(x: box.x, y: box.y, width: box.z - box.x, height: box.w - box.y)
                grains += field.rasterize(into: self, scale: Double(scale))
                let rasterized = RenderDiagnostics.begin()
                composite(into: frame, ink: ink, alphas: alphas, opacity: opacity)
                rasterNS &+= rasterized &- started
                compositeNS &+= RenderDiagnostics.begin() &- rasterized
            }
            if !boxes.isEmpty { geometry.contourBuildCount += 1 }
            return (Array(boxes.keys), grains, rasterNS, compositeNS)
        }

        /// Write the work box into `frame`: committed ink, then the bands of `ink` at
        /// `alphas` (band opacity × ink alpha), all at stroke `opacity`.
        func composite(into frame: CGContext, ink: SIMD4<Float>, alphas: [Float], opacity: Float) {
            guard let output = frame.data, alphas.count == Self.bandCount else { return }
            let bytesPerRow = frame.bytesPerRow
            let plane = boxWidth * boxHeight
            let color = SIMD4<Float>(ink.x, ink.y, ink.z, 1)
            alphas.withUnsafeBufferPointer { alpha in
                for row in 0..<boxHeight {
                    let y = boxY + row
                    guard y >= 0, y < height else { continue }
                    let rowOffset = y * bytesPerRow
                    let baseRow = y * baseBytesPerRow
                    let maskRow = masks + row * boxWidth
                    for column in 0..<boxWidth {
                        let pixelOffset = (boxX + column) * 16
                        let under = base.loadUnaligned(fromByteOffset: baseRow + pixelOffset, as: SIMD4<Float>.self)
                        var keep: Float = 1
                        for band in 0..<Self.bandCount {
                            let mask = maskRow[band * plane + column]
                            if mask != 0 {
                                keep *= 1 - Float(mask.nonzeroBitCount) * (1 / 64) * alpha[band]
                            }
                        }
                        let covered = opacity * (1 - keep)
                        let value = covered == 0 ? under : under * (1 - covered) + color * covered
                        output.storeBytes(of: value, toByteOffset: rowOffset + pixelOffset, as: SIMD4<Float>.self)
                    }
                }
            }
        }
    }
}
