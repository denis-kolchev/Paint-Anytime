import SwiftUI
import simd

nonisolated extension WatchStrokeDrawing {
    /// Experimental replacement for the per-tile grain search of `dryTexture`, chosen per
    /// gesture by `RenderStage.incrementalDryGrains` (Render debug menu).
    ///
    /// `dryTexture` rebuilds every grain of each redrawn 32 px tile: it walks the cells of
    /// every polygon overlapping the tile and probes coverage again whenever an 8 pt index
    /// tile changes. A grain, however, depends only on its cell, its owner polygon and how
    /// many of its 8 feather probes lie inside the footprint. Appending polygons can change
    /// those only within the new polygons' bounds plus the feather distance, so this field
    /// keeps one grain per cell for the whole gesture and revisits only those cells:
    /// - ownership: a new segment can take a cell from an older corner fan, never from an
    ///   older segment (segments precede fans, then index order, as in `dryTexture`);
    /// - coverage: each cell keeps a bit per probe; only probes still outside are tested,
    ///   and only against the new polygons.
    /// Tiles are redrawn only where a grain actually changed.
    ///
    /// Cells live in 32×32 chunks of 48-byte values (about 15 pt of paper per chunk),
    /// so a lookup is one array index after a cached chunk lookup.
    ///
    /// The grain math is a copy of `dryTexture`. Keep the two identical while both exist,
    /// so the switch compares speed, not appearance.
    final class DryGrainField {
        private struct Cell {
            /// Grain outline; valid when `pigment != Cell.noGrain`.
            var a = SIMD2<Float>.zero
            var b = SIMD2<Float>.zero
            var c = SIMD2<Float>.zero
            var d = SIMD2<Float>.zero
            /// Owner polygon, or -1 while no polygon contains the cell's center.
            var owner: Int32 = -1
            /// Owner for which the outline and `pigment` were computed.
            var baseOwner: Int32 = -1
            /// Pigment band (0–2) after the paper-gap test, or `noGrain` when the gap removes it.
            var pigment: UInt8 = Cell.noGrain
            /// Drawn band (edge band × 3 + pigment), or `noGrain` when the grain is not drawn.
            var band: UInt8 = Cell.noGrain
            /// Bit i: probe i (angle i·π/4 at the feather distance) lies inside the footprint.
            var probes: UInt8 = 0
            /// Update in which the cell was first owned / last queued for a rebuild.
            var freshStamp: UInt32 = 0
            var touchedStamp: UInt32 = 0
            /// Draw call that last added this cell's grain, so overlapping areas add it once.
            var drawnStamp: UInt32 = 0
            static let noGrain: UInt8 = .max
        }

        private final class Chunk {
            var cells = [Cell](repeating: Cell(), count: DryGrainField.chunkSide * DryGrainField.chunkSide)
        }

        private static let cellSize = 0.48
        private static let chunkShift = 5
        private static let chunkSide = 1 << chunkShift
        private static let bucketSize: CGFloat = 2
        /// A grain's outline lies within 0.75 pt of its center (largest vertex offset of the
        /// pencil and pastel shapes) and antialiasing adds at most 1 px (0.5 pt at scale 2).
        private static let outlineReach: CGFloat = 0.75 + 0.5
        /// Reach of a changed grain from its bucket: the center may lie one cell past it.
        private static let grainReach: CGFloat = 0.48 + outlineReach
        /// Paper areas to gather in the next `draw`, instead of its single region. The
        /// renderer sets them for one call so that every changed area is filled in one pass.
        var gatherAreas: [CGRect]?
        private var drawStamp: UInt32 = 0

        private var chunks: [SIMD2<Int>: Chunk] = [:]
        /// Polygons by 2 pt paper tile, registered only where they reach (row spans),
        /// newest last. Coverage probes test these instead of the 8 pt footprint index.
        private var probeTiles: [SIMD2<Int>: [Int32]] = [:]
        private static let probeTileSize = 2.0
        private var lastChunkKey = SIMD2<Int>(.min, .min)
        private var lastChunk: Chunk?
        private var polygonCount = 0
        private var generation = Int.min
        private var stamp: UInt32 = 0
        private var touched: [SIMD2<Int>] = []
        private var strokeSeed = 0
        private var feather = 0.0
        private var probes: [CGPoint] = []
        /// Paper rectangles whose grains changed in the latest update.
        private var changedRects: [CGRect] = []
        private var changedBuckets = Set<SIMD2<Int>>()

        /// Bring the cells up to date with `geometry`'s polygons. A no-op when nothing was
        /// appended, so per-tile drawing may call it again safely.
        func update(_ geometry: DryGeometry, stroke: Stroke) {
            let reset = geometry.generation != generation || geometry.polygons.count < polygonCount
            guard reset || geometry.polygons.count > polygonCount else { return }
            changedRects.removeAll(keepingCapacity: true)
            changedBuckets.removeAll(keepingCapacity: true)
            if reset {
                // Old grains must be erased where they were drawn.
                changedRects = chunks.keys.map(Self.chunkRect)
                chunks.removeAll(keepingCapacity: true)
                probeTiles.removeAll(keepingCapacity: true)
                lastChunk = nil
                lastChunkKey = SIMD2(.min, .min)
                polygonCount = 0
                generation = geometry.generation
                strokeSeed = stroke.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
                feather = Double(max(0.35, min(2.4, stroke.style.width * 0.20)))
                probes = (0..<8).map { index in
                    let angle = Double(index) * Double.pi / 4
                    return CGPoint(x: cos(angle) * feather, y: sin(angle) * feather)
                }
            }
            stamp &+= 1
            if stamp == 0 { stamp = 1 }
            let current = stamp
            touched.removeAll(keepingCapacity: true)
            let added = polygonCount..<geometry.polygons.count
            polygonCount = geometry.polygons.count
            let footprints = geometry.index
            var probeCount = 0
            for polygonIndex in added {
                rowSpans(of: geometry.polygons[polygonIndex], rowHeight: Self.probeTileSize, expand: 0) { y, minX, maxX in
                    for x in minX...maxX { probeTiles[SIMD2(x, y), default: []].append(Int32(polygonIndex)) }
                }
            }

            // 1. Ownership, in dryTexture's order: segments first, then corner fans.
            let ordered = added.filter { !geometry.isJoin[$0] } + added.filter { geometry.isJoin[$0] }
            for polygonIndex in ordered {
                let bounds = footprints.bounds[polygonIndex]
                guard !bounds.isNull, !bounds.isEmpty else { continue }
                let polygonIsJoin = geometry.isJoin[polygonIndex]
                forEachCell(in: geometry.polygons[polygonIndex], expand: 0) { x, y, seed in
                    let key = Self.chunkKey(x, y), local = Self.localIndex(x, y)
                    if let chunk = chunk(key, create: false), chunk.cells[local].owner >= 0 {
                        // A new segment only takes a cell from an older corner fan.
                        guard !polygonIsJoin, geometry.isJoin[Int(chunk.cells[local].owner)],
                              footprints.contains(Self.center(x, y, seed: seed), in: polygonIndex) else { return }
                        chunk.cells[local].owner = Int32(polygonIndex)
                        touch(chunk, local, x, y, current)
                    } else {
                        guard footprints.contains(Self.center(x, y, seed: seed), in: polygonIndex),
                              let chunk = chunk(key, create: true) else { return }
                        chunk.cells[local].owner = Int32(polygonIndex)
                        chunk.cells[local].probes = 0
                        chunk.cells[local].freshStamp = current
                        touch(chunk, local, x, y, current)
                    }
                }
            }

            // 2. Coverage of older cells: test only probes still outside, against new polygons.
            for polygonIndex in added {
                let polygonBounds = footprints.bounds[polygonIndex]
                guard !polygonBounds.isNull, !polygonBounds.isEmpty else { continue }
                forEachCell(in: geometry.polygons[polygonIndex], expand: feather) { x, y, seed in
                    guard let chunk = chunk(Self.chunkKey(x, y), create: false) else { return }
                    let local = Self.localIndex(x, y)
                    let cell = chunk.cells[local]
                    guard cell.owner >= 0, cell.freshStamp != current, cell.probes != 0xFF else { return }
                    let center = Self.center(x, y, seed: seed)
                    var mask = cell.probes
                    for bit in 0..<8 where mask & (1 << bit) == 0 {
                        let point = CGPoint(x: center.x + probes[bit].x, y: center.y + probes[bit].y)
                        guard point.x >= polygonBounds.minX, point.x <= polygonBounds.maxX,
                              point.y >= polygonBounds.minY, point.y <= polygonBounds.maxY else { continue }
                        probeCount += 1
                        if footprints.contains(point, in: polygonIndex) { mask |= 1 << bit }
                    }
                    guard mask != cell.probes else { return }
                    chunk.cells[local].probes = mask
                    touch(chunk, local, x, y, current)
                }
            }

            // 3. Rebuild grains whose owner or coverage changed. The outline, paper gap and
            //    pigment depend on the owner only; a probe change reuses them.
            for cell in touched {
                guard let chunk = chunk(Self.chunkKey(cell.x, cell.y), create: false) else { continue }
                let local = Self.localIndex(cell.x, cell.y)
                var entry = chunk.cells[local]
                let seed = (cell.x &* 73856093) ^ (cell.y &* 19349663) ^ strokeSeed
                let center = Self.center(cell.x, cell.y, seed: seed)
                let previous = entry
                let ownerChanged = entry.baseOwner != entry.owner
                if ownerChanged {
                    let safelyInside = buildBase(&entry, center: center, seed: seed, stroke: stroke, geometry: geometry)
                    if safelyInside {
                        entry.probes = 0xFF
                    } else if entry.freshStamp == current {
                        entry.probes = probeAll(center, owner: Int(entry.owner), footprints: footprints)
                        probeCount += 8
                    }
                }
                // Copy of dryTexture's coverage test; it and the gap test are independent.
                let coverage = Double(entry.probes.nonzeroBitCount) / Double(probes.count)
                let edgeDensity = 0.12 + 0.88 * pow(coverage, 3)
                let edgeBand = coverage > 0.87 ? 2 : (coverage > 0.62 ? 1 : 0)
                entry.band = entry.pigment != Cell.noGrain && noise(seed &+ 11) < edgeDensity
                    ? UInt8(edgeBand * 3) + entry.pigment : Cell.noGrain
                chunk.cells[local] = entry
                let changed = entry.band != previous.band || (entry.band != Cell.noGrain && ownerChanged &&
                    (entry.a != previous.a || entry.b != previous.b || entry.c != previous.c || entry.d != previous.d))
                if changed {
                    changedBuckets.insert(SIMD2(Int(floor(Double(cell.x) * Self.cellSize / Double(Self.bucketSize))),
                                                Int(floor(Double(cell.y) * Self.cellSize / Double(Self.bucketSize)))))
                }
            }
            geometry.grainBuildCount += touched.count
            geometry.coverageProbeCount += probeCount
        }

        /// Paper rectangles to redraw after `update`, each covering the changed grains'
        /// outlines; `all` adds every chunk holding grains (opening pastel contact changes
        /// the opacity of the whole stroke).
        func dirtyRects(all: Bool) -> [CGRect] {
            var rects = changedRects
            rects += changedBuckets.map { bucket in
                CGRect(x: CGFloat(bucket.x) * Self.bucketSize, y: CGFloat(bucket.y) * Self.bucketSize,
                       width: Self.bucketSize, height: Self.bucketSize)
            }
            if all { rects += chunks.keys.map(Self.chunkRect) }
            return rects.map { $0.insetBy(dx: -Self.grainReach, dy: -Self.grainReach) }
        }

        /// Fill the grains reaching `region`, in dryTexture's 9 bands and opacities.
        func draw(_ stroke: Stroke, ink: SIMD4<Float>, region: CGRect, geometry: DryGeometry,
                  in context: inout WatchDrawingContext) {
            update(geometry, stroke: stroke)
            let pastel = stroke.style.instrument == .crayon
            let contact = pastel ? 0.09 + 0.91 * min(1, Double(geometry.travel) / 4) : 1
            // Every grain whose outline can reach an area: cells overlapping it plus the
            // outline reach. A grain shared by overlapping areas is added once.
            drawStamp &+= 1
            if drawStamp == 0 { drawStamp = 1 }
            let stamp = drawStamp
            let bands = (0..<9).map { _ in CGMutablePath() }
            let shift = Self.chunkShift, mask = Self.chunkSide - 1
            for gathered in gatherAreas ?? [region] {
                let area = gathered.insetBy(dx: -Self.outlineReach, dy: -Self.outlineReach)
                let minX = Int(floor(area.minX / Self.cellSize)), maxX = Int(floor(area.maxX / Self.cellSize))
                let minY = Int(floor(area.minY / Self.cellSize)), maxY = Int(floor(area.maxY / Self.cellSize))
                for chunkY in (minY >> shift)...(maxY >> shift) {
                    for chunkX in (minX >> shift)...(maxX >> shift) {
                        guard let chunk = chunks[SIMD2(chunkX, chunkY)] else { continue }
                        let x0 = max(minX, chunkX << shift), x1 = min(maxX, (chunkX << shift) + mask)
                        let y0 = max(minY, chunkY << shift), y1 = min(maxY, (chunkY << shift) + mask)
                        chunk.cells.withUnsafeMutableBufferPointer { cells in
                            for y in y0...y1 {
                                let row = (y & mask) << shift
                                for x in x0...x1 {
                                    let index = row | (x & mask)
                                    guard cells[index].band != Cell.noGrain, cells[index].drawnStamp != stamp
                                    else { continue }
                                    cells[index].drawnStamp = stamp
                                    let cell = cells[index]
                                    let path = bands[Int(cell.band)]
                                    path.move(to: point(cell.a))
                                    path.addLine(to: point(cell.b))
                                    path.addLine(to: point(cell.c))
                                    path.addLine(to: point(cell.d))
                                    path.closeSubpath()
                                }
                            }
                        }
                    }
                }
            }
            geometry.contourBuildCount += 1
            let pigment = pastel ? [0.48, 0.72, 0.93] : [0.56, 0.76, 0.94]
            for band in bands.indices {
                var layer = context
                layer.opacity *= pigment[band % 3] * [0.30, 0.65, 1.0][band / 3] * contact
                layer.fill(Path(bands[band]), with: .color(ink))
            }
        }

        // MARK: Cells

        private static func chunkKey(_ x: Int, _ y: Int) -> SIMD2<Int> {
            SIMD2(x >> chunkShift, y >> chunkShift)
        }

        private static func localIndex(_ x: Int, _ y: Int) -> Int {
            ((y & (chunkSide - 1)) << chunkShift) | (x & (chunkSide - 1))
        }

        private static func chunkRect(_ key: SIMD2<Int>) -> CGRect {
            let side = CGFloat(Double(chunkSide) * cellSize)
            return CGRect(x: CGFloat(key.x) * side, y: CGFloat(key.y) * side, width: side, height: side)
        }

        private func chunk(_ key: SIMD2<Int>, create: Bool) -> Chunk? {
            if key == lastChunkKey, let lastChunk { return lastChunk }
            if let found = chunks[key] {
                lastChunkKey = key
                lastChunk = found
                return found
            }
            guard create else { return nil }
            let made = Chunk()
            chunks[key] = made
            lastChunkKey = key
            lastChunk = made
            return made
        }

        /// Queue a cell for a grain rebuild once per update.
        private func touch(_ chunk: Chunk, _ local: Int, _ x: Int, _ y: Int, _ stamp: UInt32) {
            guard chunk.cells[local].touchedStamp != stamp else { return }
            chunk.cells[local].touchedStamp = stamp
            touched.append(SIMD2(x, y))
        }

        /// Cells whose center can lie within `expand` of `polygon`. A tilted segment or a
        /// corner fan covers a small part of its bounding box, so row spans skip most of
        /// the cells a bounds scan would test.
        private func forEachCell(in polygon: [SIMD2<Float>], expand: Double, _ body: (Int, Int, Int) -> Void) {
            rowSpans(of: polygon, rowHeight: Self.cellSize, expand: expand) { y, minX, maxX in
                for x in minX...maxX {
                    body(x, y, (x &* 73856093) ^ (y &* 19349663) ^ strokeSeed)
                }
            }
        }

        /// For each row of a `rowHeight` grid, the columns whose square can hold a point
        /// within `expand` of `polygon`: the polygon is cut to the row's slab (widened by
        /// `expand`) and the cut's x extent, widened by `expand`, is reported.
        private func rowSpans(of polygon: [SIMD2<Float>], rowHeight: Double, expand: Double,
                              _ body: (Int, Int, Int) -> Void) {
            guard let first = polygon.first else { return }
            var minPolygonY = Double(first.y), maxPolygonY = Double(first.y)
            for vertex in polygon {
                minPolygonY = min(minPolygonY, Double(vertex.y))
                maxPolygonY = max(maxPolygonY, Double(vertex.y))
            }
            let minY = Int(floor((minPolygonY - expand) / rowHeight))
            let maxY = Int(floor((maxPolygonY + expand) / rowHeight))
            for y in minY...maxY {
                let top = Double(y) * rowHeight - expand, bottom = Double(y + 1) * rowHeight + expand
                var low = Double.infinity, high = -Double.infinity
                for index in polygon.indices {
                    let p = polygon[index], q = polygon[(index + 1) % polygon.count]
                    let px = Double(p.x), py = Double(p.y), qx = Double(q.x), qy = Double(q.y)
                    if py >= top && py <= bottom { low = min(low, px); high = max(high, px) }
                    if (py - top) * (qy - top) < 0 {
                        let x = px + (top - py) / (qy - py) * (qx - px)
                        low = min(low, x); high = max(high, x)
                    }
                    if (py - bottom) * (qy - bottom) < 0 {
                        let x = px + (bottom - py) / (qy - py) * (qx - px)
                        low = min(low, x); high = max(high, x)
                    }
                }
                guard low <= high else { continue }
                body(y, Int(floor((low - expand) / rowHeight)), Int(floor((high + expand) / rowHeight)))
            }
        }

        private static func center(_ x: Int, _ y: Int, seed: Int) -> CGPoint {
            let cellSize = 0.48
            return CGPoint(x: (Double(x) + noise(seed)) * cellSize,
                           y: (Double(y) + noise(seed &+ 1)) * cellSize)
        }

        /// Probe bits of a newly owned cell against the whole footprint: its owner first,
        /// then the polygons reaching each probe's 2 pt tile, newest first.
        private func probeAll(_ center: CGPoint, owner: Int, footprints: DryFootprintIndex) -> UInt8 {
            let ownerBounds = footprints.bounds[owner]
            var mask: UInt8 = 0
            for bit in 0..<8 {
                let point = CGPoint(x: center.x + probes[bit].x, y: center.y + probes[bit].y)
                if Self.inside(point, ownerBounds), footprints.contains(point, in: owner) {
                    mask |= 1 << bit
                    continue
                }
                let tile = SIMD2(Int(floor(Double(point.x) / Self.probeTileSize)),
                                 Int(floor(Double(point.y) / Self.probeTileSize)))
                guard let candidates = probeTiles[tile] else { continue }
                for index in candidates.reversed() where Int(index) != owner {
                    let polygon = Int(index)
                    if Self.inside(point, footprints.bounds[polygon]), footprints.contains(point, in: polygon) {
                        mask |= 1 << bit
                        break
                    }
                }
            }
            return mask
        }

        private static func inside(_ point: CGPoint, _ rect: CGRect) -> Bool {
            point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
        }

        /// Owner-dependent part of the grain closure in `dryTexture` (copied): sets the
        /// outline and pigment, or `pigment = noGrain` when the paper gap removes the grain.
        /// Returns dryTexture's `safelyInside`, which makes every probe inside.
        private func buildBase(_ entry: inout Cell, center: CGPoint, seed: Int, stroke: Stroke,
                               geometry: DryGeometry) -> Bool {
            let pastel = stroke.style.instrument == .crayon
            let polygonIndex = Int(entry.owner)
            entry.baseOwner = entry.owner
            let polygon = geometry.polygons[polygonIndex]
            let delta = polygon.count == 4 ? polygon[3] - polygon[0]
                : (polygon.last ?? .zero) - (polygon.dropFirst().first ?? .zero)
            let frame = geometry.frames[polygonIndex]
            let tangent = frame?.tangent ?? (simd_length(delta) > 0.001 ? simd_normalize(delta) : SIMD2<Float>(0, 1))
            let normal = SIMD2<Float>(-tangent.y, tangent.x)
            let local = SIMD2<Float>(Float(center.x), Float(center.y)) - (frame?.origin ?? .zero)
            let alongDistance = simd_dot(local, tangent)
            let acrossDistance = abs(simd_dot(local, normal))
            let margin = Float(feather) + 0.0001
            let safelyInside = !geometry.isJoin[polygonIndex] && frame != nil &&
                alongDistance > margin && alongDistance < (frame?.length ?? 0) - margin &&
                acrossDistance < max(0.1, stroke.style.width) / 2 - margin
            let toothX = Int(floor(Double(center.x) / 1.8))
            let toothY = Int(floor(Double(center.y) / 1.8))
            let tooth = noise((toothX &* 83492791) ^ (toothY &* Int(truncatingIfNeeded: UInt32(2971215073))) ^ strokeSeed)
            let centerVector = SIMD2<Float>(Float(center.x), Float(center.y))
            var groove = 0.5
            var wear = 0.5
            if pastel {
                let relative = centerVector - (frame?.origin ?? stroke.points[0].position)
                let acrossNib = Double(simd_dot(relative, normal))
                let pathDistance = Double((frame?.distance ?? 0) +
                    min(frame?.length ?? 0, max(0, simd_dot(relative, tangent))))
                let lane = acrossNib / 0.85
                let laneIndex = Int(floor(lane))
                let laneFraction = lane - floor(lane)
                let laneBlend = laneFraction * laneFraction * (3 - 2 * laneFraction)
                let grooveA = noise((laneIndex &* 961748941) ^ strokeSeed)
                let grooveB = noise(((laneIndex &+ 1) &* 961748941) ^ strokeSeed)
                groove = grooveA + (grooveB - grooveA) * laneBlend
                let run = pathDistance / 14
                let runIndex = Int(floor(run))
                let runFraction = run - floor(run)
                let runBlend = runFraction * runFraction * (3 - 2 * runFraction)
                let wearA = noise((runIndex &* 982451653) ^ (laneIndex &* 31) ^ strokeSeed)
                let wearB = noise(((runIndex &+ 1) &* 982451653) ^ (laneIndex &* 31) ^ strokeSeed)
                wear = wearA + (wearB - wearA) * runBlend
            }
            let scraped = groove < 0.30 && wear > 0.20
            let gap = pastel ? (scraped ? 0.92 : (tooth < 0.15 ? 0.48 : 0.015))
                : (tooth < 0.22 ? 0.30 : 0.025)
            guard noise(seed &+ 2) > gap else {
                entry.pigment = Cell.noGrain
                return safelyInside
            }
            let pigmentBand = pastel
                ? (groove > 0.57 ? 2 : min(2, Int(noise(seed &+ 3) * 3)))
                : min(2, Int(noise(seed &+ 3) * 3))
            let grainScale: Float = tooth < 0.22 ? 0.75 : 1
            let halfWidth = Float(pastel ? 0.25 + noise(seed &+ 4) * 0.21
                                  : 0.30 + noise(seed &+ 4) * 0.34) * grainScale
            let halfLength = Float(pastel ? 0.28 + noise(seed &+ 5) * 0.32
                                   : 0.24 + noise(seed &+ 5) * 0.32) * grainScale
            let angle = pastel ? atan2(tangent.y, tangent.x) + Float(noise(seed &+ 6) - 0.5) * 0.28
                : Float(noise(seed &+ 6)) * 2 * Float.pi
            let along = SIMD2<Float>(cos(angle), sin(angle))
            let across = SIMD2<Float>(-along.y, along.x)
            let p = centerVector
            let u = across * halfWidth
            let v = along * halfLength
            entry.a = p - u - v * 0.7
            entry.b = p + u * 0.6 - v
            entry.c = p + u + v * 0.5
            entry.d = p - u * 0.7 + v
            entry.pigment = UInt8(pigmentBand)
            return safelyInside
        }

        private func point(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
    }
}
