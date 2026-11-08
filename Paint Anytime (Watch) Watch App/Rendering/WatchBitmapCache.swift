import Accelerate
import SwiftUI
import simd
import ImageIO

nonisolated extension WatchBitmapRenderer {
    /// Owned by one canvas view. Appends extend the ink; history edits rebuild it.
    final class Cache {
        private var usesScreenTiles = false

        func screenFrame(strokes: [Stroke], activeStroke: Stroke?, key: CacheKey,
                         activeStrokeID: UInt64) -> ScreenFrame? {
            usesScreenTiles = true
            defer { usesScreenTiles = false }
            guard let image = render(strokes: strokes, activeStroke: activeStroke,
                                     key: key, activeStrokeID: activeStrokeID) else { return nil }
            if usesScreenTiles, activeStroke != nil, let preview = activeDry?.previewImage {
                return ScreenFrame(background: preview, tiles: [])
            }
            if usesScreenTiles, activeStroke != nil, let dry = activeDry, let background = committedImage {
                return ScreenFrame(background: dry.screenBackground ?? background, tiles: dry.screenTiles.values.sorted {
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
        /// Eraser regions survive full replays (Undo past retained snapshots, resizes).
        let masks = ErasureMaskCache()

        /// Committed states replaced by later ones, newest first. Undo and Redo return to
        /// one of these exactly, so their first frame needs no replay of the drawing.
        private struct CommittedState {
            let key: CacheKey
            let ink: InkSnapshot
            let image: CGImage
            let strokes: [StrokeVersion]
            var bytes: Int {
                ink.image.bytesPerRow * ink.image.height + image.bytesPerRow * image.height
            }
        }
        private var previousStates: [CommittedState] = []
        static let previousStateLimit = 2
        static let previousStateByteLimit = 12 * 1024 * 1024
        private(set) var previousStateHits = 0

        private static func compatible(_ lhs: CacheKey, _ rhs: CacheKey) -> Bool {
            lhs.documentID == rhs.documentID && lhs.size == rhs.size && lhs.scale == rhs.scale
        }

        /// Publish a committed snapshot, retaining the replaced one for Undo/Redo.
        private func commit(ink: InkSnapshot, image: CGImage?, strokes: [StrokeVersion], key nextKey: CacheKey) {
            if let oldKey = key, let oldInk = committedInk, let oldImage = committedImage,
               committedStrokes != strokes || !Self.compatible(oldKey, nextKey) {
                previousStates.insert(CommittedState(key: oldKey, ink: oldInk, image: oldImage,
                                                     strokes: committedStrokes), at: 0)
            }
            committedInk = ink
            committedImage = image
            committedStrokes = strokes
            key = nextKey
            // Never keep images for another document or resolution, or a duplicate of the current state.
            previousStates.removeAll { !Self.compatible($0.key, nextKey) || $0.strokes == strokes }
            var total = 0
            previousStates = Array(previousStates.prefix(Self.previousStateLimit)).filter { state in
                guard total + state.bytes <= Self.previousStateByteLimit else { return false }
                total += state.bytes
                return true
            }
        }

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
            /// Pixel fill of incremental grains; nil when the gesture uses Core Graphics.
            var pixelFill: WatchStrokeDrawing.DryPixelFill? = nil
            var travel: Float = 0
            var renderedContours: [SIMD2<Int>: UInt64] = [:]
            var screenTiles: [SIMD2<Int>: ScreenTile] = [:]
            /// Display bitmap at the latest tile merge; shown under `screenTiles` instead
            /// of the committed image once tiles were merged.
            var screenBackground: CGImage?
            /// Snapped shape moved by the finger: `stroke` stays the exactly drawn reference
            /// and frames show its image transformed (`previewImage`, no tiles).
            var shapePreview: WatchStrokeDrawing.DryShapePreview?
            var previewImage: CGImage?
        }

        /// Most tile images shown over the background. On the watch the main thread pays
        /// for every image in each published frame (HUD 2026-11-06: ~100 ms per frame at
        /// 140 tiles), so beyond this the tiles merge into one background image.
        private static let maxScreenTiles = 16

        private static let dryTileSize: CGFloat = 32
        private typealias DryBatch = (tile: SIMD2<Int>, rect: CGRect, commands: [WatchDrawingCommand], revision: UInt64?)

        /// Pencil and crayon: redraw only the 32 px tiles the new samples reach.
        /// `exact`: never show a transformed shape preview (lift).
        private func renderDry(_ stroke: Stroke, base: InkSnapshot, key: CacheKey, exact: Bool = false) -> CGImage? {
            let previous = activeDry?.stroke
            let extends = previous.map {
                stroke.extends($0)
            } ?? false
            if !extends, !exact, previous?.id == stroke.id, let image = shapePreviewFrame(stroke, key: key) {
                activeImage = image
                return image
            }
            if !extends {
                let began = RenderDiagnostics.begin()
                guard beginDry(stroke, base: base) else { return nil }
                RenderDiagnostics.dryBegan(began)
            }
            guard var dry = activeDry else { return nil }
            if extends && previous?.geometryRevision == stroke.geometryRevision {
                return usesScreenTiles ? committedImage : dry.display.makeImage()
            }
            let frameStarted = RenderDiagnostics.begin()
            let previousCount = extends ? (previous?.points.count ?? 0) : 0
            // New segments can change old feather probes at crossings. Include
            // the nib radius, feather distance, grain overhang and the last join.
            var start = extends ? max(0, (previous?.points.count ?? 0) - 2) : 0
            if stroke.style.instrument == .crayon, previous != nil {
                let travel = dry.travel
                if travel < 4 { start = 0 } // Opening contact changes opacity globally.
            }
            dry.geometry.append(stroke)
            let prepared = RenderDiagnostics.begin()
            let counters = (dry.geometry.grainBuildCount, dry.geometry.grainCacheHits,
                            dry.geometry.coverageProbeCount, dry.geometry.contourBuildCount)
            let canvas = CGRect(x: 0, y: 0, width: dry.frame.width, height: dry.frame.height)
            if let field = dry.geometry.grainField {
                guard renderIncrementalDry(stroke, field: field, previous: previous, into: &dry,
                                           key: key, canvas: canvas, stages: (frameStarted, prepared),
                                           counters: counters, previousCount: previousCount) else { return nil }
            } else {
                let tiles = Self.dryTiles(for: stroke, from: start, scale: key.scale, canvas: canvas)
                guard let batches = dryBatches(stroke, tiles: tiles, dry: dry, scale: key.scale, canvas: canvas)
                else { return nil }
                let grained = RenderDiagnostics.begin()
                var drawn = grained
                if !batches.isEmpty {
                    guard drawDry(stroke, batches: batches, into: &dry, scale: key.scale, canvas: canvas) else { return nil }
                    drawn = RenderDiagnostics.begin()
                    // Copy only changed rows into small snapshots. No full-canvas
                    // CGImage snapshot is needed while a dry gesture is on screen.
                    guard publishDryTiles(batches.map { $0.tile }, of: &dry, scale: key.scale, canvas: canvas)
                    else { return nil }
                }
                // One record per frame, so a frame longer than the HUD window stays consistent.
                RenderDiagnostics.dryFrame(stages: [frameStarted, prepared, prepared, grained, drawn,
                                                    RenderDiagnostics.begin()],
                                           incremental: false,
                                           samples: stroke.points.count - previousCount,
                                           tiles: batches.count,
                                           grainsBuilt: dry.geometry.grainBuildCount - counters.0,
                                           grainHits: dry.geometry.grainCacheHits - counters.1,
                                           probes: dry.geometry.coverageProbeCount - counters.2,
                                           contours: dry.geometry.contourBuildCount - counters.3,
                                           full: previousCount == 0)
            }
            dry.stroke = stroke
            dry.travel = dry.geometry.travel
            activeDry = dry
            activeImage = usesScreenTiles ? committedImage : dry.display.makeImage()
            return activeImage
        }

        /// A snapped shape turned or scaled by the finger: the exactly drawn shape moved as an
        /// image over the committed ink. nil when `stroke` is not such a move of the drawn one.
        private func shapePreviewFrame(_ stroke: Stroke, key: CacheKey) -> CGImage? {
            guard var dry = activeDry, let field = dry.geometry.grainField, dry.pixelFill != nil,
                  let background = committedImage,
                  WatchStrokeDrawing.DryShapePreview.similarity(from: dry.stroke, to: stroke) != nil
            else { return nil }
            if dry.shapePreview?.reference.geometryRevision != dry.stroke.geometryRevision {
                let started = RenderDiagnostics.begin()
                dry.shapePreview = WatchStrokeDrawing.DryShapePreview(
                    reference: dry.stroke, field: field, geometry: dry.geometry,
                    width: dry.frame.width, height: dry.frame.height, scale: key.scale, floatOutput: false)
                RenderDiagnostics.end(.shapeLayer, started)
            }
            guard let preview = dry.shapePreview else { return nil }
            let started = RenderDiagnostics.begin()
            guard let image = preview.frame(for: stroke, over: background, scale: key.scale) else { return nil }
            RenderDiagnostics.end(.shapePreview, started)
            dry.previewImage = image
            activeDry = dry
            return image
        }

        /// Incremental grains: redraw only the rectangles around grains that changed, in one
        /// pass of 9 band fills, then publish the 32 px tiles they touch.
        private func renderIncrementalDry(_ stroke: Stroke, field: WatchStrokeDrawing.DryGrainField,
                                          previous: Stroke?, into dry: inout ActiveDry, key: CacheKey,
                                          canvas: CGRect, stages: (UInt64, UInt64),
                                          counters: (Int, Int, Int, Int), previousCount: Int) -> Bool {
            field.update(dry.geometry, stroke: stroke)
            let updated = RenderDiagnostics.begin()
            // Opening pastel contact changes the opacity of every drawn grain.
            let contactChanges = stroke.style.instrument == .crayon && previous != nil && dry.travel < 4
            let scale = key.scale
            let pixels = field.dirtyRects(all: contactChanges).compactMap { paper -> CGRect? in
                let rect = paper.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(canvas)
                return rect.isNull || rect.isEmpty ? nil : rect
            }
            // Pixel fill handles the plain live stroke; lasso exclusions and transforms keep CG.
            if let fill = dry.pixelFill, stroke.transform == .identity, stroke.excludedAreas.isEmpty {
                return renderPixelDry(stroke, field: field, fill: fill, pixels: pixels, into: &dry,
                                      scale: scale, canvas: canvas, stages: (stages.0, stages.1, updated),
                                      counters: counters, previousCount: previousCount)
            }
            // One pass over all changed rectangles: each grain near any of them is added to
            // the band paths once, then 9 fills under their union clip.
            let toPaper = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            var commands: [WatchDrawingCommand] = []
            if !pixels.isEmpty {
                let region = pixels.reduce(CGRect.null) { $0.union($1) }.applying(toPaper)
                // A transformed live stroke (not expected) falls back to the bounding region.
                if stroke.transform == .identity { field.gatherAreas = pixels.map { $0.applying(toPaper) } }
                commands = WatchStrokeDrawing.commands(for: stroke, region: region, dryGeometry: dry.geometry)
                field.gatherAreas = nil
                guard !Task.isCancelled else { return false }
            }
            let grained = RenderDiagnostics.begin()
            var drawn = grained
            let tileSize = Self.dryTileSize
            var tiles = Set<SIMD2<Int>>()
            if !pixels.isEmpty {
                guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
                let frame = dry.frame
                let clip = CGMutablePath()
                for rect in pixels {
                    clip.addRect(CGRect(x: rect.minX, y: CGFloat(frame.height) - rect.maxY,
                                        width: rect.width, height: rect.height))
                }
                frame.saveGState()
                frame.addPath(clip); frame.clip()
                frame.clear(canvas)
                frame.draw(dry.base, in: canvas)
                frame.translateBy(x: 0, y: CGFloat(frame.height))
                frame.scaleBy(x: scale, y: -scale)
                let opacity = stroke.style.effectiveOpacity
                if opacity < 1 {
                    frame.setAlpha(CGFloat(opacity))
                    frame.beginTransparencyLayer(auxiliaryInfo: nil)
                }
                for command in commands { WatchBitmapRenderer.draw(command, in: frame, space: space) }
                if opacity < 1 { frame.endTransparencyLayer() }
                frame.restoreGState()
                drawn = RenderDiagnostics.begin()
                for rect in pixels {
                    for y in Int(floor(rect.minY / tileSize))...Int(floor((rect.maxY - 0.001) / tileSize)) {
                        for x in Int(floor(rect.minX / tileSize))...Int(floor((rect.maxX - 0.001) / tileSize)) {
                            tiles.insert(SIMD2(x, y))
                        }
                    }
                }
                guard publishDryTiles(Array(tiles), of: &dry, scale: scale, canvas: canvas) else { return false }
            }
            RenderDiagnostics.dryFrame(stages: [stages.0, stages.1, updated, grained, drawn, RenderDiagnostics.begin()],
                                       incremental: true,
                                       samples: stroke.points.count - previousCount,
                                       tiles: tiles.count,
                                       grainsBuilt: dry.geometry.grainBuildCount - counters.0,
                                       grainHits: dry.geometry.grainCacheHits - counters.1,
                                       probes: dry.geometry.coverageProbeCount - counters.2,
                                       contours: dry.geometry.contourBuildCount - counters.3,
                                       full: previousCount == 0)
            return true
        }

        /// Pixel fill of incremental grains: each changed 32 px tile recomputes the box around
        /// its changed rectangles from the committed ink and every grain reaching it.
        private func renderPixelDry(_ stroke: Stroke, field: WatchStrokeDrawing.DryGrainField,
                                    fill: WatchStrokeDrawing.DryPixelFill, pixels: [CGRect],
                                    into dry: inout ActiveDry, scale: CGFloat, canvas: CGRect,
                                    stages: (UInt64, UInt64, UInt64), counters: (Int, Int, Int, Int),
                                    previousCount: Int) -> Bool {
            guard let result = fill.fillChanged(pixels, field: field, stroke: stroke, geometry: dry.geometry,
                                                frame: dry.frame, scale: scale) else { return false }
            let (tiles, grains, rasterNS, compositeNS) = result
            let grained = stages.2 &+ rasterNS
            let drawn = grained &+ compositeNS
            guard publishDryTiles(tiles, of: &dry, scale: scale, canvas: canvas) else { return false }
            RenderDiagnostics.dryFrame(stages: [stages.0, stages.1, stages.2, grained, drawn, RenderDiagnostics.begin()],
                                       incremental: true, pixel: true,
                                       samples: stroke.points.count - previousCount,
                                       tiles: tiles.count,
                                       grainsBuilt: dry.geometry.grainBuildCount - counters.0,
                                       grainHits: grains,
                                       probes: dry.geometry.coverageProbeCount - counters.2,
                                       contours: dry.geometry.contourBuildCount - counters.3,
                                       full: previousCount == 0)
            return true
        }

        /// A new dry gesture copies committed ink into its float frame and display bitmap.
        private func beginDry(_ stroke: Stroke, base: InkSnapshot) -> Bool {
            guard let frame = WatchBitmapRenderer.makeFloatContext(width: base.image.width,
                                                                   height: base.image.height) else { return false }
            frame.draw(base.image, in: CGRect(x: 0, y: 0, width: base.image.width, height: base.image.height))
            guard let display = WatchBitmapRenderer.makeDisplayContext(width: frame.width, height: frame.height) else { return false }
            display.setFillColor(CGColor(gray: 1, alpha: 1))
            display.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            display.draw(base.image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let geometry = WatchStrokeDrawing.DryGeometry()
            // The renderer is chosen once per gesture, so a toggle never mixes the two.
            var pixelFill: WatchStrokeDrawing.DryPixelFill?
            if RenderStageSwitches.isOn(.incrementalDryGrains) {
                geometry.grainField = WatchStrokeDrawing.DryGrainField()
                // The frame holds exactly the committed ink here: the fill's base.
                if RenderStageSwitches.isOn(.pixelDryFill) {
                    pixelFill = WatchStrokeDrawing.DryPixelFill(frame: frame)
                }
            }
            activeDry = ActiveDry(stroke: stroke, base: base.image, frame: frame, display: display,
                                  geometry: geometry, pixelFill: pixelFill)
            activeDryBuildCount += 1
            activeImage = nil
            return true
        }

        /// Tiles inside the swept nib envelope of the samples from `start` on.
        private static func dryTiles(for stroke: Stroke, from start: Int, scale: CGFloat,
                                     canvas: CGRect) -> Set<SIMD2<Int>> {
            let padding = CGFloat(stroke.style.width) / 2 + 5
            let tileSize = dryTileSize
            var tiles = Set<SIMD2<Int>>()
            for i in start..<stroke.points.count {
                let p = stroke.points[i].position
                let q = i > start ? stroke.points[i - 1].position : p
                var rect = CGRect(x: CGFloat(min(p.x, q.x)), y: CGFloat(min(p.y, q.y)),
                                  width: CGFloat(abs(p.x - q.x)) + 0.001,
                                  height: CGFloat(abs(p.y - q.y)) + 0.001)
                rect = rect.insetBy(dx: -padding, dy: -padding)
                    .applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(canvas)
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
                            let half = Float(tileSize / (2 * scale))
                            let center = SIMD2<Float>(Float((CGFloat(x) + 0.5) * tileSize / scale),
                                                      Float((CGFloat(y) + 0.5) * tileSize / scale)) - q
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
            return tiles
        }

        /// Commands for each tile whose contours changed since it was last drawn; nil if cancelled.
        private func dryBatches(_ stroke: Stroke, tiles: Set<SIMD2<Int>>, dry: ActiveDry,
                                scale: CGFloat, canvas: CGRect) -> [DryBatch]? {
            let tileSize = Self.dryTileSize
            lastDryDirtyArea = 0
            var batches: [DryBatch] = []
            for tile in tiles {
                let dirty = CGRect(x: CGFloat(tile.x) * tileSize, y: CGFloat(tile.y) * tileSize,
                                   width: tileSize, height: tileSize).intersection(canvas)
                let region = dirty.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                let commands = WatchStrokeDrawing.commands(for: stroke, region: region, dryGeometry: dry.geometry)
                guard !Task.isCancelled else { return nil }
                let revision = dry.geometry.contourRevision(in: region)
                if let revision, dry.renderedContours[tile] == revision { continue }
                lastDryDirtyArea += dirty.width * dirty.height
                batches.append((tile, dirty, commands, revision))
            }
            return batches
        }

        /// Restore committed ink inside the changed tiles and draw the stroke over it.
        private func drawDry(_ stroke: Stroke, batches: [DryBatch], into dry: inout ActiveDry,
                             scale: CGFloat, canvas: CGRect) -> Bool {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
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
            frame.scaleBy(x: scale, y: -scale)
            let opacity = stroke.style.instrument == .eraser ? 1 : stroke.style.effectiveOpacity
            if opacity < 1 {
                frame.setAlpha(CGFloat(opacity))
                frame.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            for batch in batches {
                frame.saveGState()
                frame.clip(to: batch.rect.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)))
                for command in batch.commands { WatchBitmapRenderer.draw(command, in: frame, space: space) }
                frame.restoreGState()
                dry.renderedContours[batch.tile] = batch.revision
            }
            if opacity < 1 { frame.endTransparencyLayer() }
            frame.restoreGState()
            return true
        }

        /// Flatten changed tiles into the display bitmap and the on-screen tile set.
        private func publishDryTiles(_ changedTiles: [SIMD2<Int>], of dry: inout ActiveDry,
                                     scale: CGFloat, canvas: CGRect) -> Bool {
            let tileSize = Self.dryTileSize
            for tile in changedTiles {
                let dirty = CGRect(x: CGFloat(tile.x) * tileSize, y: CGFloat(tile.y) * tileSize,
                                   width: tileSize, height: tileSize).intersection(canvas)
                guard let patch = WatchBitmapRenderer.snapshot(dry.frame, rect: dirty, floating: true),
                      let flat = WatchBitmapRenderer.flatten(InkSnapshot(image: patch), paperWhite: 1) else { return false }
                let destination = CGRect(x: dirty.minX, y: CGFloat(dry.frame.height) - dirty.maxY,
                                         width: dirty.width, height: dirty.height)
                dry.display.draw(flat, in: destination)
                dry.screenTiles[tile] = ScreenTile(id: tile,
                    rect: dirty.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)), image: flat)
            }
            // The display bitmap already holds every flattened tile: one image replaces them.
            if usesScreenTiles, dry.screenTiles.count > Self.maxScreenTiles {
                if let merged = dry.display.makeImage() {
                    dry.screenBackground = merged
                    dry.screenTiles.removeAll(keepingCapacity: true)
                }
            }
            return true
        }

        private struct ActiveInk {
            var stroke: Stroke
            // Keep presentation cost independent of the area covered by a long stroke.
            // Only dirty patches are flattened into this persistent display bitmap.
            let display: CGContext?
            let usesScreenTiles: Bool
            let id: UInt64?
            let coverage: WatchStrokeCoverage
            let base: CGContext
            let frame: CGContext
        }

        /// One frame: bring committed ink up to `nextKey`, then draw the live stroke over it.
        func render(strokes: [Stroke], activeStroke: Stroke?, key nextKey: CacheKey,
                    activeStrokeID: UInt64? = nil) -> CGImage? {
            let updated = RenderDiagnostics.measure(.committed) {
                updateCommitted(strokes: strokes, key: nextKey)
            }
            guard updated, let committedInk else { return nil }
            return RenderDiagnostics.measure(.live) {
                renderActive(activeStroke, over: committedInk, key: nextKey, activeStrokeID: activeStrokeID)
            }
        }

        // MARK: Committed ink stages

        /// Stages run in order until one publishes a committed snapshot for `nextKey`.
        /// Returns false only when the final replay fails.
        private func updateCommitted(strokes: [Stroke], key nextKey: CacheKey) -> Bool {
            guard key != nextKey else { return true }
            promoteLiveCoverage(strokes: strokes, key: nextKey)
            if key != nextKey {
                let promoting = RenderDiagnostics.begin()
                let previewed = activeDry?.previewImage != nil
                promoteLiveDry(strokes: strokes, key: nextKey)
                if key == nextKey { RenderDiagnostics.shapeCommitted(previewed ? "exact" : "extend", promoting) }
            }
            guard key != nextKey else { return true }
            retainGeometry(for: strokes, key: nextKey)
            restorePreviousState(strokes: strokes, key: nextKey)
            guard key != nextKey else { return true }
            // Lift of a snapped shape that could not be promoted: whole artwork replayed.
            let replaying = RenderDiagnostics.begin()
            defer { RenderDiagnostics.shapeCommitted("REPLAY \(strokes.count)", replaying) }
            return replayCommitted(strokes: strokes, key: nextKey)
        }

        /// Lift of a marker or watercolor stroke: complete its live coverage buffer
        /// as committed ink instead of replaying the stroke.
        private func promoteLiveCoverage(strokes: [Stroke], key nextKey: CacheKey) {
            guard let oldKey = key, Self.compatible(oldKey, nextKey),
                  strokes.count == committedStrokes.count + 1,
                  strokes.dropLast().map(StrokeVersion.init) == committedStrokes,
                  let final = strokes.last, let ink = activeInk,
                  final.extends(ink.stroke), !final.locksTransparency,
                  final.transform == .identity, final.excludedAreas.isEmpty,
                  final.erasures.isEmpty, final.raster == nil,
                  ink.coverage.canAppend(final) else { return }
            do {
                let dirty = try ink.coverage.append(final)
                ink.coverage.composite(dirty: dirty, over: ink.base, into: ink.frame)
                if let image = ink.frame.makeImage(),
                   let display = WatchBitmapRenderer.flatten(InkSnapshot(image: image), paperWhite: 1),
                   !Task.isCancelled {
                    commit(ink: InkSnapshot(image: image), image: display,
                           strokes: strokes.map(StrokeVersion.init), key: nextKey)
                    appendCount += 1
                    activeInk = nil
                    activeImage = nil
                }
            } catch {
                // Fall back to the regular replay if the live buffer cannot be completed.
                activeInk = nil
            }
        }

        /// Lift of a pencil or crayon stroke: finish its dry frame as committed ink.
        private func promoteLiveDry(strokes: [Stroke], key nextKey: CacheKey) {
            let versions = strokes.map(StrokeVersion.init)
            guard let oldKey = key, Self.compatible(oldKey, nextKey),
                  versions.count == committedStrokes.count + 1,
                  versions.starts(with: committedStrokes), let final = strokes.last,
                  let dry = activeDry, dry.stroke.id == final.id, dry.stroke.style == final.style,
                  // A previewed shape is drawn exactly here, once, from a fresh buffer.
                  final.extends(dry.stroke) || dry.previewImage != nil, let base = committedInk,
                  let display = renderDry(final, base: base, key: nextKey, exact: true),
                  let ink = activeDry?.frame.makeImage(), !Task.isCancelled else { return }
            commit(ink: InkSnapshot(image: ink),
                   image: usesScreenTiles ? activeDry?.display.makeImage() : display,
                   strokes: versions, key: nextKey)
            appendCount += 1
            activeDry = nil
            activeImage = nil
        }

        /// Bound ownership to current artwork; undo can regenerate removed entries.
        private func retainGeometry(for strokes: [Stroke], key nextKey: CacheKey) {
            if key?.documentID != nextKey.documentID { geometry.removeAll() }
            let ids = Set(strokes.map(\.id))
            geometry = geometry.filter { ids.contains($0.key) }
        }

        /// Undo/Redo back to a retained state: publish it without replay.
        private func restorePreviousState(strokes: [Stroke], key nextKey: CacheKey) {
            let versions = strokes.map(StrokeVersion.init)
            guard let index = previousStates.firstIndex(where: {
                Self.compatible($0.key, nextKey) && $0.strokes == versions
            }) else { return }
            let state = previousStates[index]
            commit(ink: state.ink, image: state.image, strokes: versions, key: nextKey)
            previousStateHits += 1
            activeInk = nil
            activeDry = nil
            activeImage = nil
        }

        /// Reuse only an unchanged prefix at the same resolution and canvas size, either
        /// the current snapshot or a retained earlier one (a new stroke after Undo).
        private func appendBase(for versions: [StrokeVersion], key nextKey: CacheKey) -> (ink: InkSnapshot, count: Int)? {
            if let ink = committedInk, let key, Self.compatible(key, nextKey),
               versions.count > committedStrokes.count, versions.starts(with: committedStrokes) {
                return (ink, committedStrokes.count)
            }
            return previousStates
                .filter { Self.compatible($0.key, nextKey) && versions.count > $0.strokes.count
                          && versions.starts(with: $0.strokes) }
                .max { $0.strokes.count < $1.strokes.count }
                .map { (ink: $0.ink, count: $0.strokes.count) }
        }

        /// Rasterize the strokes not yet in committed ink (all of them without a base).
        /// Requests may skip intermediate commits, so this appends the whole unseen suffix.
        private func replayCommitted(strokes: [Stroke], key nextKey: CacheKey) -> Bool {
            let versions = strokes.map(StrokeVersion.init)
            let base = appendBase(for: versions, key: nextKey)
            let canAppend = base != nil
            let pendingStrokes = base.map { Array(strokes.dropFirst($0.count)) } ?? strokes
            // Promoted live strokes need no vector cache until a full replay
            // (undo, resize, export) actually requires their geometry.
            for stroke in pendingStrokes where geometry[stroke.id]?.revision != stroke.geometryRevision {
                guard !Task.isCancelled,
                      let entry = try? StrokeGeometry(stroke), !Task.isCancelled else { return false }
                geometry[stroke.id] = entry
                geometryBuildCount += 1
            }
            guard let ink = WatchBitmapRenderer.renderInk(strokes: pendingStrokes, size: nextKey.size,
                                                         scale: nextKey.scale,
                                                         base: base?.ink,
                                                         geometry: geometry, masks: masks),
                  let image = WatchBitmapRenderer.flatten(ink, paperWhite: 1),
                  !Task.isCancelled else { return false }
            // Publish the snapshot and its prefix together only after success.
            commit(ink: ink, image: image, strokes: versions, key: nextKey)
            if canAppend { appendCount += 1 } else { rebuildCount += 1 }
            committedRasterizedStrokeCount += pendingStrokes.count
            activeInk = nil
            activeDry = nil
            activeImage = nil
            return true
        }

        // MARK: Live stroke stages

        private func renderActive(_ activeStroke: Stroke?, over committedInk: InkSnapshot,
                                  key nextKey: CacheKey, activeStrokeID: UInt64?) -> CGImage? {
            guard let activeStroke else {
                activeInk = nil
                activeDry = nil
                activeImage = nil
                activePen = nil
                return committedImage
            }
            let instrument = activeStroke.style.instrument
            if instrument == .pen, let image = renderPen(activeStroke, over: committedInk, key: nextKey) {
                activeInk = nil
                activeDry = nil
                return image
            }
            activePen = nil
            if instrument == .pencil || instrument == .crayon {
                activeInk = nil
                return renderDry(activeStroke, base: committedInk, key: nextKey)
            }
            activeDry = nil
            if instrument == .marker || instrument == .watercolor {
                return renderCoverage(activeStroke, over: committedInk, key: nextKey, activeStrokeID: activeStrokeID)
            }
            return replayActive(activeStroke, over: committedInk, key: nextKey)
        }

        /// Marker and watercolor: extend a persistent coverage buffer by the new samples.
        private func renderCoverage(_ activeStroke: Stroke, over committedInk: InkSnapshot,
                                    key nextKey: CacheKey, activeStrokeID: UInt64?) -> CGImage? {
            if activeStrokeID == nil || activeInk?.id != activeStrokeID ||
                activeInk?.usesScreenTiles != usesScreenTiles ||
                activeInk?.coverage.canAppend(activeStroke) != true {
                guard beginCoverage(activeStroke, over: committedInk, key: nextKey,
                                    activeStrokeID: activeStrokeID) else { return nil }
            }
            guard var ink = activeInk else { return nil }
            do {
                let dirty = try ink.coverage.append(activeStroke)
                if !dirty.isNull, !dirty.isEmpty {
                    ink.coverage.composite(dirty: dirty, over: ink.base, into: ink.frame)
                    let image: CGImage?
                    if let display = ink.display {
                        image = Self.flattenTiles(of: ink.frame, dirty: dirty, into: display)
                            ? display.makeImage() : nil
                    } else {
                        image = ink.frame.makeImage().flatMap {
                            WatchBitmapRenderer.flatten(InkSnapshot(image: $0), paperWhite: 1)
                        }
                    }
                    guard let image else {
                        self.activeInk = nil
                        return nil
                    }
                    activeImage = image
                }
                ink.stroke = activeStroke
                self.activeInk = ink
                return activeImage
            } catch {
                self.activeInk = nil
                activeImage = nil
                return nil
            }
        }

        private func beginCoverage(_ activeStroke: Stroke, over committedInk: InkSnapshot,
                                   key nextKey: CacheKey, activeStrokeID: UInt64?) -> Bool {
            let width = committedInk.image.width
            let height = committedInk.image.height
            guard let base = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                  let frame = WatchBitmapRenderer.makeFloatContext(width: width, height: height)
            else { return false }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            base.draw(committedInk.image, in: bounds)
            frame.draw(committedInk.image, in: bounds)
            let display: CGContext?
            if usesScreenTiles {
                guard let bitmap = WatchBitmapRenderer.makeDisplayContext(width: width, height: height),
                      let committedImage else { return false }
                bitmap.draw(committedImage, in: bounds)
                display = bitmap
            } else {
                display = nil
            }
            activeInk = ActiveInk(stroke: activeStroke, display: display,
                usesScreenTiles: usesScreenTiles, id: activeStrokeID,
                coverage: WatchStrokeCoverage(style: activeStroke.style, width: width,
                                              height: height, scale: nextKey.scale),
                base: base, frame: frame)
            activeImage = committedImage
            activeCoverageBuildCount += 1
            return true
        }

        /// Flatten only the 32 px tiles of `frame` touched by `dirty` into `display`.
        private static func flattenTiles(of frame: CGContext, dirty: CGRect, into display: CGContext) -> Bool {
            let tileSize: CGFloat = 32
            let canvas = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            for y in Int(floor(dirty.minY / tileSize))...Int(floor((dirty.maxY - 1) / tileSize)) {
                for x in Int(floor(dirty.minX / tileSize))...Int(floor((dirty.maxX - 1) / tileSize)) {
                    let rect = CGRect(x: CGFloat(x) * tileSize, y: CGFloat(y) * tileSize,
                                      width: tileSize, height: tileSize).intersection(canvas)
                    guard let patch = WatchBitmapRenderer.snapshot(frame, rect: rect, floating: true),
                          let flat = WatchBitmapRenderer.flatten(InkSnapshot(image: patch), paperWhite: 1)
                    else { return false }
                    let destination = CGRect(x: rect.minX, y: CGFloat(frame.height) - rect.maxY,
                                             width: rect.width, height: rect.height)
                    display.draw(flat, in: destination)
                }
            }
            return true
        }

        private var activePen: LivePenInk?
        /// Display bitmap of `activePen` for screen tiles, flattened by dirty tiles.
        private var activePenDisplay: CGContext?

        /// Pen: extend the live buffer by the new samples; nil falls back to replay.
        private func renderPen(_ activeStroke: Stroke, over committedInk: InkSnapshot,
                               key nextKey: CacheKey) -> CGImage? {
            guard LivePenInk.supports(activeStroke) else {
                activePen = nil
                activePenDisplay = nil
                return nil
            }
            let pen: LivePenInk
            var dirty: CGRect?
            if let current = activePen, current.base === committedInk.image, current.scale == nextKey.scale,
               (activePenDisplay != nil) == usesScreenTiles {
                pen = current
                dirty = current.update(activeStroke)
            } else {
                guard let created = LivePenInk(stroke: activeStroke, base: committedInk.image,
                                               scale: nextKey.scale) else { return nil }
                pen = created
                activePenDisplay = nil
                if usesScreenTiles {
                    guard let display = WatchBitmapRenderer.makeDisplayContext(
                        width: created.frame.width, height: created.frame.height) else { return nil }
                    activePenDisplay = display
                }
                dirty = CGRect(x: 0, y: 0, width: created.frame.width, height: created.frame.height)
            }
            guard let dirty else {
                activePen = nil
                activePenDisplay = nil
                return nil
            }
            activePen = pen
            let full = CGRect(x: 0, y: 0, width: pen.frame.width, height: pen.frame.height)
            if let display = activePenDisplay {
                if dirty == full {
                    guard let ink = pen.frame.makeImage(),
                          let flat = WatchBitmapRenderer.flatten(InkSnapshot(image: ink), paperWhite: 1)
                    else { return nil }
                    display.draw(flat, in: full)
                } else if !dirty.isNull, !dirty.isEmpty {
                    guard Self.flattenTiles(of: pen.frame, dirty: dirty, into: display) else { return nil }
                }
                activeImage = display.makeImage()
                return activeImage
            }
            if dirty.isNull || dirty.isEmpty, let activeImage { return activeImage }
            guard let ink = pen.frame.makeImage() else { return nil }
            activeImage = WatchBitmapRenderer.flatten(InkSnapshot(image: ink), paperWhite: 1)
            return activeImage
        }

        /// Other instruments: replay the whole live stroke over committed ink.
        private func replayActive(_ activeStroke: Stroke, over committedInk: InkSnapshot,
                                  key nextKey: CacheKey) -> CGImage? {
            activeInk = nil
            activeImage = nil
            guard let frame = WatchBitmapRenderer.renderInk(strokes: [activeStroke], size: nextKey.size,
                                                            scale: nextKey.scale, base: committedInk)
            else { return nil }
            return WatchBitmapRenderer.flatten(frame, paperWhite: 1)
        }
    }
}

nonisolated extension WatchBitmapRenderer {
    /// Live Pen stroke over committed ink, extended by its new samples only.
    /// Replaying the whole stroke each frame made its cost grow with stroke length.
    /// Until the opening width settles (`BrushGeometry.penRadiiSettled`) every update
    /// redraws the stroke; afterwards radii of drawn samples never change, so only
    /// new segments and discs are added. They are drawn opaque into a coverage mask,
    /// and only the changed rectangle is composited as `base + ink × coverage × density`.
    /// That equals `renderInk`'s single fill inside a transparency layer, so translucent
    /// ink gets no darker seams. The committed stroke is replayed whole on lift.
    final class LivePenInk {
        let frame: CGContext
        let base: CGImage
        let scale: CGFloat
        private(set) var stroke: Stroke
        private var settled = false
        private let backdrop: CGContext
        private let coverage: CGContext
        private let scratch: UnsafeMutablePointer<Float>

        static func supports(_ stroke: Stroke) -> Bool {
            stroke.style.instrument == .pen && !stroke.points.isEmpty
                && !stroke.locksTransparency && stroke.transform == .identity
                && stroke.excludedAreas.isEmpty && stroke.erasures.isEmpty && stroke.raster == nil
        }

        init?(stroke: Stroke, base: CGImage, scale: CGFloat) {
            let width = base.width, height = base.height
            guard Self.supports(stroke), width > 0, height > 0,
                  let frame = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                  let backdrop = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                  let coverage = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                           bitmapInfo: CGImageAlphaInfo.none.rawValue
                                               | CGBitmapInfo.floatComponents.rawValue
                                               | CGBitmapInfo.byteOrder32Little.rawValue),
                  frame.data != nil, backdrop.data != nil, coverage.data != nil
            else { return nil }
            backdrop.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.frame = frame
            self.backdrop = backdrop
            self.coverage = coverage
            self.base = base
            self.scale = scale
            self.stroke = stroke
            scratch = .allocate(capacity: width * 2)
            scratch.initialize(repeating: 0, count: width * 2)
            redraw(stroke)
        }

        deinit { scratch.deallocate() }

        private var canvas: CGRect { CGRect(x: 0, y: 0, width: frame.width, height: frame.height) }

        /// Pixel rectangle (rows top to bottom) changed by `stroke`; the whole frame
        /// when it had to be redrawn. nil when this buffer cannot show `stroke`.
        func update(_ next: Stroke) -> CGRect? {
            guard Self.supports(next), next.id == stroke.id else { return nil }
            guard settled, next.extends(stroke) else {
                redraw(next)
                return canvas
            }
            let drawn = stroke.points.count
            stroke = next
            guard next.points.count > drawn, drawn > 0 else { return .null }
            let radii = BrushGeometry.radii(for: next)
            let path = BrushGeometry.roundPath(points: next.points[(drawn - 1)...].map(\.position),
                                               radii: Array(radii[(drawn - 1)...]), skipsFirstDisc: true)
            fillCoverage(path)
            // Paper space to pixels: y already runs down in both.
            let dirty = path.boundingBoxOfPath.applying(CGAffineTransform(scaleX: scale, y: scale))
                .insetBy(dx: -2, dy: -2).integral.intersection(canvas)
            composite(dirty)
            return dirty
        }

        private func redraw(_ next: Stroke) {
            stroke = next
            settled = BrushGeometry.penRadiiSettled(next)
            coverage.data?.initializeMemory(as: UInt8.self, repeating: 0,
                                            count: coverage.bytesPerRow * coverage.height)
            fillCoverage(BrushGeometry.roundPath(for: next))
            composite(canvas)
        }

        /// Same transform as `renderInk`; coverage only, the ink is applied in `composite`.
        private func fillCoverage(_ path: CGPath) {
            coverage.saveGState()
            coverage.translateBy(x: 0, y: CGFloat(coverage.height))
            coverage.scaleBy(x: scale, y: -scale)
            coverage.setFillColor(gray: 1, alpha: 1)
            coverage.addPath(path)
            coverage.fillPath()
            coverage.restoreGState()
        }

        /// Premultiplied normal blend: out = ink·a + base·(1−a), a = coverage × ink alpha × density.
        private func composite(_ rect: CGRect) {
            guard !rect.isNull, !rect.isEmpty,
                  let output = frame.data?.assumingMemoryBound(to: Float.self),
                  let below = backdrop.data?.assumingMemoryBound(to: Float.self),
                  let mask = coverage.data?.assumingMemoryBound(to: Float.self) else { return }
            let frameStride = frame.bytesPerRow / MemoryLayout<Float>.stride
            let backdropStride = backdrop.bytesPerRow / MemoryLayout<Float>.stride
            let maskStride = coverage.bytesPerRow / MemoryLayout<Float>.stride
            let x = Int(rect.minX), count = Int(rect.width)
            let n = vDSP_Length(count)
            let alpha = scratch, remaining = scratch + frame.width
            let ink = stroke.style.color
            var inkAlpha = min(1, max(0, ink.w * stroke.style.effectiveOpacity))
            var one: Float = 1, minusOne: Float = -1
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let source = below + y * backdropStride + x * 4
                let destination = output + y * frameStride + x * 4
                vDSP_vsmul(mask + y * maskStride + x, 1, &inkAlpha, alpha, 1, n)
                vDSP_vsmsa(alpha, 1, &minusOne, &one, remaining, 1, n)
                for channel in 0..<3 {
                    var color = ink[channel]
                    vDSP_vmul(source + channel, 4, remaining, 1, destination + channel, 4, n)
                    vDSP_vsma(alpha, 1, &color, destination + channel, 4, destination + channel, 4, n)
                }
                vDSP_vmul(source + 3, 4, remaining, 1, destination + 3, 4, n)
                vDSP_vadd(destination + 3, 4, alpha, 1, destination + 3, 4, n)
            }
        }
    }
}
