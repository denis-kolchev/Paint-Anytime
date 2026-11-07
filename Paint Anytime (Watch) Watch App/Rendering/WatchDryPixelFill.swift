import Foundation
import CoreGraphics
import simd

nonisolated extension WatchStrokeDrawing {
    /// A snapped pencil/pastel shape being resized or turned with the finger still down.
    ///
    /// Every move rewrites all shape points, so the live grain field would be rebuilt from
    /// scratch each frame (watch, 2026-11-08: 176–426 ms per frame, 65–90 % in the grain
    /// update). Instead the shape drawn exactly once (`reference`) is kept as a stroke-only
    /// image and each move draws it with the move's similarity transform. The grain turns
    /// and scales with the shape while the finger is down; on lift the renderer draws
    /// the final shape exactly.
    final class DryShapePreview {
        let reference: Stroke
        private let layer: CGImage
        /// Layer position in pixels, top-left origin.
        private let crop: CGRect
        private let output: CGContext
        private var shownRevision: UUID?
        private var shown: CGImage?

        /// Rasterizes every grain of the reference field over transparency. `floatOutput`:
        /// frames come out as float RGBA (layer ink) instead of 8-bit (display).
        init?(reference: Stroke, field: DryGrainField, geometry: DryGeometry,
              width: Int, height: Int, scale: CGFloat, floatOutput: Bool) {
            guard let frame = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                  let fill = DryPixelFill(frame: frame) else { return nil }
            let canvas = CGRect(x: 0, y: 0, width: width, height: height)
            let pixels = field.dirtyRects(all: true).compactMap { paper -> CGRect? in
                let rect = paper.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(canvas)
                return rect.isNull || rect.isEmpty ? nil : rect
            }
            let crop = pixels.reduce(CGRect.null) { $0.union($1) }.intersection(canvas)
            guard !crop.isNull, !crop.isEmpty,
                  fill.fillChanged(pixels, field: field, stroke: reference, geometry: geometry,
                                   frame: frame, scale: scale) != nil,
                  let patch = WatchBitmapRenderer.snapshot(frame, rect: crop, floating: true),
                  let small = WatchBitmapRenderer.makeDisplayContext(width: Int(crop.width), height: Int(crop.height))
            else { return nil }
            small.setBlendMode(.copy)
            small.draw(patch, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            guard let layer = small.makeImage(),
                  let output = floatOutput ? WatchBitmapRenderer.makeFloatContext(width: width, height: height)
                                           : WatchBitmapRenderer.makeDisplayContext(width: width, height: height)
            else { return nil }
            output.interpolationQuality = .medium
            self.reference = reference
            self.layer = layer
            self.crop = crop
            self.output = output
        }

        /// `background` (same size as the output) with the moved shape over it, or nil when
        /// `stroke` is not the reference turned, scaled and moved. A pure turn moves the image
        /// as a whole; a resize keeps the line width (`drawPieces`).
        /// Repeated calls for the same stroke revision return the previous image.
        func frame(for stroke: Stroke, over background: CGImage, scale: CGFloat) -> CGImage? {
            if shownRevision == stroke.geometryRevision, let shown { return shown }
            guard let similarity = Self.similarity(from: reference, to: stroke) else { return nil }
            let z = similarity.z, t = similarity.t
            let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
            output.saveGState()
            output.setBlendMode(.copy)
            output.draw(background, in: bounds)
            output.restoreGState()
            output.saveGState()
            // Top-left pixel space.
            output.translateBy(x: 0, y: bounds.height)
            output.scaleBy(x: 1, y: -1)
            if abs(simd_length(z) - 1) < 0.01 {
                drawLayer(CGAffineTransform(a: z.x, b: z.y, c: -z.y, d: z.x, tx: t.x * scale, ty: t.y * scale))
            } else {
                drawPieces(stroke, z: z, scale: Double(scale))
            }
            output.restoreGState()
            shown = output.makeImage()
            shownRevision = stroke.geometryRevision
            return shown
        }

        /// Draw the layer image moved by `transform` (top-left pixel space → same).
        private func drawLayer(_ transform: CGAffineTransform) {
            output.saveGState()
            output.concatenate(transform)
            output.translateBy(x: crop.minX, y: crop.maxY)
            output.scaleBy(x: 1, y: -1) // The image upright.
            output.draw(layer, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            output.restoreGState()
        }

        /// Resize without changing the line width: the shape is cut into pieces that tile the
        /// destination plane around it without overlap (hard-edged clips, so no seams).
        /// - Bodies (along each chord between kept vertices): stretched by the scale only along
        ///   the chord, rotated, ends mapped exactly onto the new vertices; width unchanged.
        /// - Corners (outer wedge) and the caps of open shapes: only turned, not scaled, so
        ///   joins and round ends keep their size.
        /// Grain is stretched along bodies by the scale until lift.
        private func drawPieces(_ stroke: Stroke, z: SIMD2<Double>, scale: Double) {
            let s = simd_length(z)
            let cosine = z.x / s, sine = z.y / s
            func rotate(_ v: SIMD2<Double>) -> SIMD2<Double> {
                SIMD2(cosine * v.x - sine * v.y, sine * v.x + cosine * v.y)
            }
            func pixel(_ sample: PointerSample) -> SIMD2<Double> {
                SIMD2(Double(sample.position.x), Double(sample.position.y)) * scale
            }
            let reference = self.reference.points.map(pixel), moved = stroke.points.map(pixel)
            let width = Double(max(0.1, self.reference.style.width))
            // Reach of ink from the centerline: radius + feather + grain outline.
            let outer = (width / 2 + 4) * scale, inner = (width / 2 + 3) * scale
            // Vertices: drop repeats; merge nearly straight runs while stretching only along the
            // chord moves no point more than 0.3 px off its true place.
            var vertices = [0]
            var start = 0
            for index in 1..<reference.count {
                guard simd_distance(reference[index], reference[vertices.last!]) > 0.01 else { continue }
                if index == reference.count - 1 { vertices.append(index); break }
                let chord = reference[index + 1] - reference[start]
                let length = simd_length(chord)
                var fits = length > 0.01
                if fits {
                    let normal = SIMD2(-chord.y, chord.x) / length
                    for between in (start + 1)...index {
                        let offset = abs(simd_dot(reference[between] - reference[start], normal))
                        if offset * abs(s - 1) > 0.3 || offset > inner / 2 { fits = false; break }
                    }
                }
                if !fits { vertices.append(index); start = index }
            }
            let last = reference.count - 1
            if vertices.last != last {
                // A repeated final point replaces the vertex it repeats (no zero-length chord).
                if simd_distance(reference[last], reference[vertices.last!]) > 0.01 { vertices.append(last) }
                else if vertices.count > 1 { vertices[vertices.count - 1] = last }
            }
            let closed = vertices.count > 3
                && simd_distance(reference[vertices.first!], reference[vertices.last!]) < 0.5 * scale
            if closed { vertices.removeLast() }
            let count = vertices.count
            let segments = closed ? count : count - 1
            guard segments >= 1 else { return }
            func direction(_ segment: Int) -> SIMD2<Double> {
                let a = reference[vertices[segment]], b = reference[vertices[(segment + 1) % count]]
                return simd_normalize(b - a)
            }
            // Edge of each body at each of its ends: (left of the segment, vertex, right).
            var startEdges = [[SIMD2<Double>]](repeating: [], count: segments)
            var endEdges = [[SIMD2<Double>]](repeating: [], count: segments)
            var corners: [(vertex: Int, polygon: [SIMD2<Double>])] = []
            var caps: [(vertex: Int, polygon: [SIMD2<Double>])] = []
            for joint in 0..<count {
                let c = moved[vertices[joint]]
                let incoming = closed ? (joint + segments - 1) % segments : joint - 1
                let outgoing = closed || joint < segments ? joint : -1
                if incoming < 0 || outgoing < 0 {
                    // Open end: perpendicular edge and a turned (unscaled) cap behind it.
                    let segment = incoming < 0 ? outgoing : incoming
                    let e = rotate(direction(segment)), n = SIMD2(-e.y, e.x)
                    let edge = [c + n * outer, c, c - n * outer]
                    let back = incoming < 0 ? -e : e
                    caps.append((joint, [c + n * outer, c + n * outer + back * outer,
                                         c - n * outer + back * outer, c - n * outer]))
                    if incoming < 0 { startEdges[segment] = edge } else { endEdges[segment] = edge }
                    continue
                }
                let eIn = rotate(direction(incoming)), eOut = rotate(direction(outgoing))
                let nIn = SIMD2(-eIn.y, eIn.x), nOut = SIMD2(-eOut.y, eOut.x)
                let turn = eIn.x * eOut.y - eIn.y * eOut.x
                var bisector = nIn + nOut
                bisector = simd_length(bisector) < 1e-6 ? nIn : simd_normalize(bisector)
                let miter = 1 / max(0.25, simd_dot(bisector, nIn))
                if abs(turn) < 0.1 && simd_dot(eIn, eOut) > 0 {
                    // Nearly straight: both bodies meet on the bisector.
                    let edge = [c + bisector * outer * miter, c, c - bisector * outer * miter]
                    endEdges[incoming] = edge
                    startEdges[outgoing] = edge
                    continue
                }
                // Corner: bodies meet on the inner bisector; the outer wedge between their
                // perpendiculars is a turned, unscaled piece.
                let outerSide: Double = turn > 0 ? -1 : 1 // Normals point into the turn.
                let innerPoint = c - bisector * (outerSide * inner * miter)
                let outerIn = c + nIn * (outerSide * outer), outerOut = c + nOut * (outerSide * outer)
                let tip = c + bisector * (outerSide * outer * miter)
                endEdges[incoming] = outerSide > 0 ? [outerIn, c, innerPoint] : [innerPoint, c, outerIn]
                startEdges[outgoing] = outerSide > 0 ? [outerOut, c, innerPoint] : [innerPoint, c, outerOut]
                corners.append((joint, [c, outerIn, tip, outerOut]))
            }
            output.setShouldAntialias(false)
            func clip(_ polygon: [SIMD2<Double>]) {
                let path = CGMutablePath()
                path.addLines(between: polygon.map { CGPoint(x: $0.x, y: $0.y) })
                path.closeSubpath()
                output.addPath(path)
                output.clip()
            }
            // Rigid (turned) or body (turned + stretched along `along`) map of reference
            // point `from` onto moved point `to`.
            func transform(from: SIMD2<Double>, to: SIMD2<Double>, along: SIMD2<Double>?) -> CGAffineTransform {
                var m00 = 1.0, m01 = 0.0, m10 = 0.0, m11 = 1.0
                if let d = along {
                    m00 += (s - 1) * d.x * d.x; m01 += (s - 1) * d.x * d.y
                    m10 += (s - 1) * d.x * d.y; m11 += (s - 1) * d.y * d.y
                }
                let a = cosine * m00 - sine * m10, c = cosine * m01 - sine * m11
                let b = sine * m00 + cosine * m10, d = sine * m01 + cosine * m11
                return CGAffineTransform(a: a, b: b, c: c, d: d,
                                         tx: to.x - (a * from.x + c * from.y), ty: to.y - (b * from.x + d * from.y))
            }
            for segment in 0..<segments {
                let first = vertices[segment]
                let startEdge = startEdges[segment], endEdge = endEdges[segment]
                guard startEdge.count == 3, endEdge.count == 3 else { continue }
                output.saveGState()
                clip([startEdge[0], endEdge[0], endEdge[1], endEdge[2], startEdge[2], startEdge[1]])
                drawLayer(transform(from: reference[first], to: moved[first], along: direction(segment)))
                output.restoreGState()
            }
            for piece in corners + caps {
                output.saveGState()
                clip(piece.polygon)
                let index = vertices[piece.vertex]
                drawLayer(transform(from: reference[index], to: moved[index], along: nil))
                output.restoreGState()
            }
            output.setShouldAntialias(true)
        }

        /// z (scale·rotation as a complex number) and t with stroke = z·reference + t for
        /// every point, in paper points. Same gesture, style and pressures; plain strokes only.
        static func similarity(from reference: Stroke, to stroke: Stroke) -> (z: SIMD2<Double>, t: SIMD2<Double>)? {
            let r = reference.points, c = stroke.points
            guard stroke.id == reference.id, stroke.style == reference.style, r.count == c.count, r.count >= 2,
                  stroke.transform == .identity, reference.transform == .identity,
                  stroke.excludedAreas.isEmpty, reference.excludedAreas.isEmpty,
                  stroke.erasures.isEmpty, stroke.raster == nil, reference.raster == nil,
                  stroke.locksTransparency == reference.locksTransparency else { return nil }
            func point(_ sample: PointerSample) -> SIMD2<Double> { SIMD2(Double(sample.position.x), Double(sample.position.y)) }
            func multiply(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
                SIMD2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)
            }
            let r0 = point(r[0])
            var far = 0, farDistance = 0.0
            for index in 1..<r.count {
                let distance = simd_length_squared(point(r[index]) - r0)
                if distance > farDistance { far = index; farDistance = distance }
            }
            guard farDistance > 1 else { return nil }
            let d = point(r[far]) - r0, e = point(c[far]) - point(c[0])
            let z = SIMD2(e.x * d.x + e.y * d.y, e.y * d.x - e.x * d.y) / farDistance
            let t = point(c[0]) - multiply(z, r0)
            // Float shape points: allow rounding of coordinates up to a few hundred points.
            let tolerance = 0.1 * max(1, simd_length(z))
            let step = max(1, r.count / 32)
            for index in Swift.stride(from: 0, to: r.count, by: step).map({ $0 }) + [r.count - 1] {
                guard r[index].pressure == c[index].pressure,
                      simd_length(multiply(z, point(r[index])) + t - point(c[index])) <= tolerance else { return nil }
            }
            return (z, t)
        }
    }
}

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

nonisolated extension WatchBitmapRenderer {
    /// One-shot pencil/pastel render through the live pixel path (incremental grains +
    /// `DryPixelFill`) instead of the CG replay, for small previews such as the tool
    /// settings viewport. nil when the switches are off or the stroke needs the CG replay.
    static func renderDryPixel(_ stroke: Stroke, size: CGSize, scale: CGFloat,
                               paperWhite: CGFloat = 1) -> CGImage? {
        guard stroke.style.instrument == .pencil || stroke.style.instrument == .crayon,
              RenderStageSwitches.isOn(.incrementalDryGrains), RenderStageSwitches.isOn(.pixelDryFill),
              !stroke.locksTransparency, stroke.transform == .identity, stroke.excludedAreas.isEmpty,
              stroke.erasures.isEmpty, stroke.raster == nil,
              size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else { return nil }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        // A new bitmap context starts transparent: no committed ink under the stroke.
        guard width <= 8192, height <= 8192,
              let frame = makeFloatContext(width: width, height: height),
              let fill = WatchStrokeDrawing.DryPixelFill(frame: frame) else { return nil }
        let geometry = WatchStrokeDrawing.DryGeometry()
        let field = WatchStrokeDrawing.DryGrainField()
        geometry.grainField = field
        geometry.append(stroke)
        field.update(geometry, stroke: stroke)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let pixels = field.dirtyRects(all: true).compactMap { paper -> CGRect? in
            let rect = paper.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(canvas)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
        guard fill.fillChanged(pixels, field: field, stroke: stroke, geometry: geometry,
                               frame: frame, scale: scale) != nil,
              let image = frame.makeImage() else { return nil }
        return flatten(InkSnapshot(image: image), paperWhite: paperWhite)
    }
}
