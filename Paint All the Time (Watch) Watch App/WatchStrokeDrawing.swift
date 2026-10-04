import SwiftUI
import simd

// Procedural watchOS brushes. Apple Pencil pressure/tilt and PencilKit's
// proprietary ink textures are not available to this finger-driven canvas.
nonisolated enum WatchStrokeDrawing {
    static func commands(for stroke: Stroke, region: CGRect? = nil, dryGeometry: DryGeometry? = nil) -> [WatchDrawingCommand] {
        var context = WatchDrawingContext()
        draw(stroke, region: region, dryGeometry: dryGeometry, in: &context)
        return context.storage.commands
    }

    private static func draw(_ stroke: Stroke, region: CGRect?, dryGeometry: DryGeometry?, in context: inout WatchDrawingContext) {
        guard !stroke.points.isEmpty else { return }
        let ink = stroke.style.color
        var paint = context
        switch stroke.style.instrument {
        case .monoline:
            paint.stroke(centerline(stroke), with: .color(ink), style: StrokeStyle(
                lineWidth: CGFloat(stroke.style.width), lineCap: .round, lineJoin: .round))
            drawDotIfNeeded(stroke, ink: ink, in: &paint)
        case .pen:
            paint.fill(shape(BrushGeometry.roundPolygons(for: stroke)), with: .color(ink))
        case .fountainPen, .reed:
            paint.fill(shape(FountainPenGeometry.polygons(for: stroke)), with: .color(ink))
        case .marker:
            // Composite marker coverage once, even when a long path is drawn in batches.
            paint.usesOpacityLayer = true
            paint.opacity *= 0.7
            paint.blendMode = .multiply
            paint.fill(shape(BrushGeometry.markerPolygons(for: stroke)), with: .color(ink))
        case .pencil, .crayon:
            dryTexture(stroke, ink: ink, region: region, geometry: dryGeometry, in: &paint)
        case .watercolor:
            watercolor(stroke, ink: ink, in: &paint)
        case .eraser:
            guard stroke.style.eraserMode == .pixels else { return }
            // Erase alpha, never paint white over the drawing.
            paint.blendMode = .destinationOut
            paint.stroke(centerline(stroke), with: .color(SIMD4<Float>(0, 0, 0, 1)), style: StrokeStyle(
                lineWidth: CGFloat(stroke.style.width), lineCap: .round, lineJoin: .round))
            drawDotIfNeeded(stroke, ink: SIMD4<Float>(0, 0, 0, 1), in: &paint)
        }
    }

    private static func centerline(_ stroke: Stroke) -> Path {
        var path = Path()
        guard let first = stroke.points.first else { return path }
        path.move(to: point(first.position))
        for sample in stroke.points.dropFirst() { path.addLine(to: point(sample.position)) }
        return path
    }

    private static func drawDotIfNeeded(_ stroke: Stroke, ink: SIMD4<Float>, in context: inout WatchDrawingContext) {
        guard stroke.points.count == 1, let sample = stroke.points.first else { return }
        let radius = CGFloat(stroke.style.width) / 2
        context.fill(Path(ellipseIn: CGRect(x: CGFloat(sample.position.x) - radius,
                                           y: CGFloat(sample.position.y) - radius,
                                           width: radius * 2, height: radius * 2)), with: .color(ink))
    }

    private static func shape(_ polygons: [[SIMD2<Float>]]) -> Path {
        var path = Path()
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            path.move(to: point(first))
            for vertex in polygon.dropFirst() { path.addLine(to: point(vertex)) }
            path.closeSubpath()
        }
        return path
    }

    // Paper-space grain: increasing the nib width exposes more grains instead
    // of spreading a fixed number over a larger footprint. One cell is deposited
    // only once per gesture, including joins and retraced sections.
    private static func dryTexture(_ stroke: Stroke, ink: SIMD4<Float>, region: CGRect?, geometry: DryGeometry?,
                               in context: inout WatchDrawingContext) {
        let pastel = stroke.style.instrument == .crayon
        let geometry = geometry ?? DryGeometry()
        geometry.append(stroke)
        let travel = geometry.travel
        let strokeSeed = stroke.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let cellSize = 0.48
        let footprints = geometry.index
        let feather = Double(max(0.35, min(2.4, stroke.style.width * 0.20)))
        let probes = (0..<8).map { index in
            let angle = Double(index) * Double.pi / 4
            return CGPoint(x: cos(angle) * feather, y: sin(angle) * feather)
        }
        var deposited = Set<SIMD2<Int>>()
        let bands = (0..<9).map { _ in CGMutablePath() }
        let candidates = region.map { footprints.candidates(in: $0.insetBy(dx: -2, dy: -2)) }
            ?? Array(geometry.polygons.indices)
        // Segments always own grains before corner fans, as in full replay.
        let ordered = candidates.sorted {
            if geometry.isJoin[$0] != geometry.isJoin[$1] { return !geometry.isJoin[$0] }
            return $0 < $1
        }
        for polygonIndex in ordered {
            guard !Task.isCancelled else { return }
            let polygon = geometry.polygons[polygonIndex]
            let searchBounds = region.map { footprints.bounds[polygonIndex].intersection($0.insetBy(dx: -2, dy: -2)) }
                ?? footprints.bounds[polygonIndex]
            guard !searchBounds.isNull, !searchBounds.isEmpty else { continue }
            let delta = polygon.count == 4 ? polygon[3] - polygon[0]
                : (polygon.last ?? .zero) - (polygon.dropFirst().first ?? .zero)
            let frame = geometry.frames[polygonIndex]
            let tangent = frame?.tangent ?? (simd_length(delta) > 0.001 ? simd_normalize(delta) : SIMD2<Float>(0, 1))
            let normal = SIMD2<Float>(-tangent.y, tangent.x)
            let footprint = footprints.paths[polygonIndex]
            let bounds = searchBounds
            guard !bounds.isNull, !bounds.isEmpty else { continue }
            let minX = Int(floor(bounds.minX / cellSize))
            let maxX = Int(floor(bounds.maxX / cellSize))
            let minY = Int(floor(bounds.minY / cellSize))
            let maxY = Int(floor(bounds.maxY / cellSize))
            for y in minY...maxY {
                guard !Task.isCancelled else { return }
                for x in minX...maxX {
                    let cell = SIMD2<Int>(x, y)
                    guard !deposited.contains(cell) else { continue }
                    let seed = (x &* 73856093) ^ (y &* 19349663) ^ strokeSeed
                    let center = CGPoint(
                        x: (Double(x) + noise(seed)) * cellSize,
                        y: (Double(y) + noise(seed &+ 1)) * cellSize)
                    guard footprint.contains(center) else { continue }
                    deposited.insert(cell)
                    let cached = geometry.grainCache[cell]
                    let reusable = cached.map {
                        $0.owner == polygonIndex && ($0.fullCoverage || $0.revision == geometry.polygons.count)
                    } ?? false
                    let grain: DryGeometry.Grain?
                    if reusable {
                        grain = cached?.grain
                        geometry.grainCacheHits += 1
                    } else {
                        var fullCoverage = false
                        grain = { () -> DryGeometry.Grain? in
                            // Density and opacity fall near the boundary of the complete
                            // stroke, not at individual event segments. Broken edge grains
                            // retain the flat cap without a hard rectangular silhouette.
                            let local = SIMD2<Float>(Float(center.x), Float(center.y)) - (frame?.origin ?? .zero)
                            let alongDistance = simd_dot(local, tangent)
                            let acrossDistance = abs(simd_dot(local, normal))
                            let margin = Float(feather) + 0.0001
                            let safelyInside = !geometry.isJoin[polygonIndex] && frame != nil &&
                                alongDistance > margin && alongDistance < (frame?.length ?? 0) - margin &&
                                acrossDistance < max(0.1, stroke.style.width) / 2 - margin
                            let inside = safelyInside ? 8 : probes.reduce(0) { count, offset in
                                count + (footprints.contains(CGPoint(
                                    x: center.x + offset.x, y: center.y + offset.y)) ? 1 : 0)
                            }
                            fullCoverage = inside == 8
                            geometry.coverageProbeCount += safelyInside ? 0 : 8
                            let coverage = Double(inside) / Double(probes.count)
                            let edgeDensity = 0.12 + 0.88 * pow(coverage, 3)
                            guard noise(seed &+ 11) < edgeDensity else { return nil }
                            let edgeBand = coverage > 0.87 ? 2 : (coverage > 0.62 ? 1 : 0)
                            // Overlapping irregular grains form dense graphite clusters.
                            // Coarser paper tooth modulates them independently of nib width.
                            let toothX = Int(floor(Double(center.x) / 1.8))
                            let toothY = Int(floor(Double(center.y) / 1.8))
                            let tooth = noise((toothX &* 83492791) ^ (toothY &* 2971215073) ^ strokeSeed)
                            let centerVector = SIMD2<Float>(Float(center.x), Float(center.y))
                            // Long correlated grooves come from the nib, while paper
                            // tooth supplies smaller chips. The grains themselves are
                            // compact, avoiding the previous field of little dashes.
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
                            guard noise(seed &+ 2) > gap else { return nil }
                            let pigmentBand = pastel
                                ? (groove > 0.57 ? 2 : min(2, Int(noise(seed &+ 3) * 3)))
                                : min(2, Int(noise(seed &+ 3) * 3))
                            let band = edgeBand * 3 + pigmentBand
                            let grainScale: Float = tooth < 0.22 ? 0.75 : 1
                            let halfWidth = Float(pastel ? 0.25 + noise(seed &+ 4) * 0.21
                                                  : 0.30 + noise(seed &+ 4) * 0.34) * grainScale
                            let halfLength = Float(pastel ? 0.28 + noise(seed &+ 5) * 0.32
                                                   : 0.24 + noise(seed &+ 5) * 0.32) * grainScale
                            let angle = pastel ? atan2(tangent.y, tangent.x) + Float(noise(seed &+ 6) - 0.5) * 0.28
                                : Float(noise(seed &+ 6)) * 2 * Float.pi
                            let along = SIMD2<Float>(cos(angle), sin(angle))
                            let across = SIMD2<Float>(-along.y, along.x)
                            let p = SIMD2<Float>(Float(center.x), Float(center.y))
                            let u = across * halfWidth
                            let v = along * halfLength
                            return DryGeometry.Grain(a: p - u - v * 0.7, b: p + u * 0.6 - v,
                                                     c: p + u + v * 0.5, d: p - u * 0.7 + v, band: band)
                        }()
                        geometry.grainBuildCount += 1
                        // Bounded per-gesture memory, including cached empty cells.
                        // Eviction affects speed only, never pigment or random seeds.
                        if geometry.grainCache.count >= 32768, let victim = geometry.grainCache.keys.first {
                            geometry.grainCache.removeValue(forKey: victim)
                        }
                        geometry.grainCache[cell] = DryGeometry.CachedGrain(owner: polygonIndex,
                            revision: geometry.polygons.count, fullCoverage: fullCoverage, grain: grain)
                    }
                    if let grain {
                        let path = bands[grain.band]
                        path.move(to: point(grain.a))
                        path.addLine(to: point(grain.b))
                        path.addLine(to: point(grain.c))
                        path.addLine(to: point(grain.d))
                        path.closeSubpath()
                    }
                }
            }
        }
        for band in bands.indices {
            var layer = context
            let pigment = pastel ? [0.48, 0.72, 0.93] : [0.56, 0.76, 0.94]
            // Contact builds over a short travel distance, independent of the
            // number of touch events. A circular rub quickly becomes saturated.
            let contact = pastel ? 0.09 + 0.91 * min(1, Double(travel) / 4) : 1
            layer.opacity *= pigment[band % 3] * [0.30, 0.65, 1.0][band / 3] * contact
            layer.fill(Path(bands[band]), with: .color(ink))
        }
    }

    /// Append-only geometry and spatial index owned by one active gesture.
    final class DryGeometry {
        struct Grain {
            let a: SIMD2<Float>
            let b: SIMD2<Float>
            let c: SIMD2<Float>
            let d: SIMD2<Float>
            let band: Int
        }
        struct CachedGrain {
            let owner: Int
            let revision: Int
            let fullCoverage: Bool
            let grain: Grain?
        }
        var grainCache: [SIMD2<Int>: CachedGrain] = [:]
        var grainBuildCount = 0
        var grainCacheHits = 0
        var coverageProbeCount = 0
        struct Frame {
            let origin: SIMD2<Float>
            let tangent: SIMD2<Float>
            let length: Float
            let distance: Float
        }
        var polygons: [[SIMD2<Float>]] = []
        var frames: [Frame?] = []
        var isJoin: [Bool] = []
        var index = DryFootprintIndex(polygons: [])
        private var firstFrames: [SIMD2<Float>: Frame] = [:]
        private var points: [SIMD2<Float>] = []
        private var count = 0
        private var distance: Float = 0
        private(set) var travel: Float = 0

        func append(_ stroke: Stroke) {
            guard stroke.points.count > count else { return }
            // The tiny opening changes from a resting footprint to a moving nib.
            if travel < 0.5 {
                polygons.removeAll(); frames.removeAll(); isJoin.removeAll()
                grainCache.removeAll(keepingCapacity: true)
                index = DryFootprintIndex(polygons: [])
                firstFrames.removeAll(); points.removeAll()
                count = 0; distance = 0; travel = 0
            }
            for i in count..<stroke.points.count {
                let p = stroke.points[i].position
                if i > 0 { travel += simd_distance(stroke.points[i - 1].position, p) }
                guard let previous = points.last else { points.append(p); continue }
                let length = simd_distance(previous, p)
                guard length > 0.001 else { continue }
                let frame = Frame(origin: previous, tangent: (p - previous) / length,
                                  length: length, distance: distance)
                if firstFrames[previous] == nil { firstFrames[previous] = frame }
                let tail = Array(points.suffix(2)) + [p]
                let samples = tail.map { PointerSample(position: $0, pressure: 1, timestamp: 0) }
                let shapes = BrushGeometry.pencilPolygons(for: Stroke(points: samples, style: stroke.style))
                let segmentIndex = tail.count - 2
                add(shapes[segmentIndex], frame: frame, join: false)
                if shapes.count > tail.count - 1 {
                    add(shapes[shapes.count - 1], frame: firstFrames[previous], join: true)
                }
                distance += length
                points.append(p)
            }
            count = stroke.points.count
            if points.count == 1 || (stroke.style.instrument == .crayon && travel < 0.5), let p = points.first {
                polygons.removeAll(); frames.removeAll(); isJoin.removeAll()
                grainCache.removeAll(keepingCapacity: true)
                index = DryFootprintIndex(polygons: [])
                let r = stroke.style.instrument == .crayon
                    ? max(0.1, stroke.style.width) * 0.38 : min(3, max(0.1, stroke.style.width)) / 2
                add([p + SIMD2(-r, -r), p + SIMD2(r, -r), p + SIMD2(r, r), p + SIMD2(-r, r)],
                    frame: nil, join: false)
            }
        }

        private func add(_ polygon: [SIMD2<Float>], frame: Frame?, join: Bool) {
            polygons.append(polygon); frames.append(frame); isJoin.append(join)
            index.append(polygon)
        }
    }

    /// Exact vector coverage with a spatial broad phase; no raster mask or
    /// resolution-dependent approximation is introduced into the texture.
    struct DryFootprintIndex {
        private(set) var paths: [CGPath] = []
        private(set) var bounds: [CGRect] = []
        private var tiles: [SIMD2<Int>: [Int]] = [:]
        private let tileSize: CGFloat = 8

        init(polygons: [[SIMD2<Float>]]) {
            for polygon in polygons { append(polygon) }
        }

        mutating func append(_ polygon: [SIMD2<Float>]) {
            let path = shape([polygon]).cgPath
            let rect = path.boundingBoxOfPath
            let index = paths.count
            paths.append(path); bounds.append(rect)
            guard !rect.isNull, !rect.isEmpty else { return }
            for y in Int(floor(rect.minY / tileSize))...Int(floor(rect.maxY / tileSize)) {
                for x in Int(floor(rect.minX / tileSize))...Int(floor(rect.maxX / tileSize)) {
                    tiles[SIMD2(x, y), default: []].append(index)
                }
            }
        }

        func candidates(in rect: CGRect) -> [Int] {
            guard !rect.isNull, !rect.isEmpty else { return [] }
            var result = Set<Int>()
            for y in Int(floor(rect.minY / tileSize))...Int(floor(rect.maxY / tileSize)) {
                for x in Int(floor(rect.minX / tileSize))...Int(floor(rect.maxX / tileSize)) {
                    for index in tiles[SIMD2(x, y)] ?? [] { result.insert(index) }
                }
            }
            return Array(result)
        }

        func contains(_ point: CGPoint) -> Bool {
            let tile = SIMD2(Int(floor(point.x / tileSize)), Int(floor(point.y / tileSize)))
            guard let candidates = tiles[tile] else { return false }
            for index in candidates {
                let rect = bounds[index]
                guard point.x >= rect.minX, point.x <= rect.maxX,
                      point.y >= rect.minY, point.y <= rect.maxY else { continue }
                if paths[index].contains(point) { return true }
            }
            return false
        }
    }

    private static func watercolor(_ stroke: Stroke, ink: SIMD4<Float>, in context: inout WatchDrawingContext) {
        let points = BrushGeometry.spacedPoints(for: stroke, spacing: max(0.5, stroke.style.width * 0.12))
        // Nested translucent washes produce a soft edge. Each wash is filled once;
        // separate strokes build color, without dark joints between input samples.
        for band in 0..<6 {
            var wash = Path()
            for (index, position) in points.enumerated() {
                let r = watercolorRadius(width: stroke.style.width, band: band, index: index)
                wash.addEllipse(in: CGRect(x: Double(position.x) - r, y: Double(position.y) - r,
                                           width: r * 2, height: r * 2))
            }
            var layer = context
            layer.blendMode = .multiply
            layer.opacity *= 1 - pow(1 - 0.7, 1.0 / 6)
            layer.fill(wash, with: .color(ink))
        }
    }

    static func watercolorRadius(width: Float, band: Int, index: Int) -> Double {
        Double(width) / 2 * (1 - Double(band) * 0.105) * (0.92 + noise(index * 13) * 0.08)
    }

    private static func noise(_ seed: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: seed) &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) & 0xffff) / 65535
    }

    private static func point(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }
}
