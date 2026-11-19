import SwiftUI
import simd
import ImageIO
import Compression
import os

nonisolated extension WatchBitmapRenderer {
    /// Layers are isolated so erasers never punch through neighbouring artwork.
    final class LayerCache {
        var size: CGSize = .zero
        var scale: CGFloat = 0
        /// Canvas point at the top-left pixel; non-zero when this cache serves a viewport region.
        var origin: CGPoint = .zero
        /// Serves a viewport region: strokes outside it are skipped and empty layers hold
        /// a 1×1 ink, so the incremental live buffers (sized from the base ink) stay off.
        var isRegion = false
        /// Fill connectivity image of a canvas too large for a whole-layer float ink: an
        /// 8-bit image assembled from strips (`fillImage`). Kept until the layer changes.
        fileprivate var fillStripImage: (layerID: UUID, size: CGSize, revisions: [UUID], image: CGImage)?
        fileprivate var inks: [UUID: (revisions: [UUID], ink: InkSnapshot)] = [:] {
            didSet {
                if inks.isEmpty {
                    previousInks.removeAll()
                    compressedInks.removeAll()
                }
            }
        }
        /// Inks evicted from `inks`, LZ4-compressed: restoring one decompresses it instead of
        /// replaying every stroke of the layer (Krita compresses swapped tiles the same way).
        /// Transparent areas of a float ink are zeros and shrink to almost nothing.
        private var compressedInks: [UUID: CompressedInk] = [:]
        private struct CompressedInk {
            let revisions: [UUID]
            let data: Data
            let width: Int
            let height: Int
            let bytesPerRow: Int
            let bitsPerComponent: Int
            let bitsPerPixel: Int
            let bitmapInfo: CGBitmapInfo
            let space: CGColorSpace
            var access: UInt64
        }
        /// Compressed inks stay within a quarter of the live ink budget.
        static var compressedByteLimit: Int { inkByteLimit / 4 }
        private(set) var compressedInkHits = 0
        /// Snapshots replaced by later commits, newest first. Undo and Redo return to one
        /// of these exactly, so the first frame after them needs no replay of the layer.
        private var previousInks: [(layerID: UUID, revisions: [UUID], ink: InkSnapshot)] = []
        static let previousInksPerLayer = 2
        static let previousInkByteLimit = 12 * 1024 * 1024
        private(set) var previousInkHits = 0

        /// Current inks of all layers stay within this many bytes; least recently used go
        /// first and replay when next needed. Float RGBA is 16 B/px: at ×4 one watch-sized
        /// layer is ~13 MB, and 17 of them took the app past its ~300 MB limit.
        /// `rasterScale(displayScale:zoom:fit:canvasSize:layerCount:)` keeps zoom within it.
        ///
        /// The app's memory limit differs by watch model and watchOS version, so the
        /// budget is a share of what this device leaves the app, at most 96 MB. It is
        /// fixed at the first render: a budget following live usage would change the
        /// raster scale, and every scale change replays all layers.
        static let inkByteLimit: Int = {
            let ceiling = 96 * 1024 * 1024, minimum = 24 * 1024 * 1024
            #if targetEnvironment(simulator) || os(macOS)
            // The Simulator enforces no per-app limit and reports 0; macOS (the
            // `Tests/check-*.sh` builds) has no such call.
            return ceiling
            #else
            // On a watch 0 means the limit is already reached: keep the minimum.
            let available = os_proc_available_memory()
            return min(ceiling, max(minimum, Int(Double(available) * 0.35)))
            #endif
        }()
        private var inkAccess: [UUID: UInt64] = [:]
        private var inkClock: UInt64 = 0

        private static func bytes(_ ink: InkSnapshot) -> Int { ink.image.bytesPerRow * ink.image.height }

        /// The layer's current ink if it matches these strokes; marks it recently used.
        fileprivate func currentInk(for layerID: UUID, revisions: [UUID]) -> InkSnapshot? {
            restoreCompressed(layerID)
            guard let entry = inks[layerID], entry.revisions == revisions else { return nil }
            touchInk(layerID)
            return entry.ink
        }

        private func touchInk(_ layerID: UUID) {
            inkClock &+= 1
            inkAccess[layerID] = inkClock
        }

        /// Never evicts `layerID`, the ink just stored, so the cache never empties here.
        private func evictInks(keeping layerID: UUID) {
            var total = inks.values.reduce(0) { $0 + Self.bytes($1.ink) }
            while total > Self.inkByteLimit,
                  let oldest = inks.keys.filter({ $0 != layerID })
                      .min(by: { inkAccess[$0, default: 0] < inkAccess[$1, default: 0] }),
                  let removed = inks.removeValue(forKey: oldest) {
                total -= Self.bytes(removed.ink)
                compress(removed.ink, revisions: removed.revisions, for: oldest,
                         access: inkAccess[oldest, default: 0])
                inkAccess.removeValue(forKey: oldest)
            }
        }

        /// Keeps an evicted ink compressed when that saves at least half of it.
        private func compress(_ ink: InkSnapshot, revisions: [UUID], for layerID: UUID, access: UInt64) {
            let image = ink.image
            guard let space = image.colorSpace, let source = image.dataProvider?.data as Data? else { return }
            let count = image.bytesPerRow * image.height
            guard source.count >= count, count > 0 else { return }
            var output = Data(count: count / 2)
            let written = output.withUnsafeMutableBytes { target in
                source.withUnsafeBytes { input in
                    compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, count / 2,
                                              input.bindMemory(to: UInt8.self).baseAddress!, count,
                                              nil, COMPRESSION_LZ4)
                }
            }
            // 0: did not fit in half the size; not worth keeping.
            guard written > 0 else { return }
            output.count = written
            compressedInks[layerID] = CompressedInk(revisions: revisions, data: output, width: image.width,
                height: image.height, bytesPerRow: image.bytesPerRow,
                bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel, bitmapInfo: image.bitmapInfo,
                space: space, access: access)
            var total = compressedInks.values.reduce(0) { $0 + $1.data.count }
            while total > Self.compressedByteLimit,
                  let oldest = compressedInks.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = compressedInks.removeValue(forKey: oldest) {
                total -= removed.data.count
            }
        }

        /// Moves a compressed ink back into `inks` when the layer has no current one.
        private func restoreCompressed(_ layerID: UUID) {
            guard inks[layerID] == nil, let entry = compressedInks.removeValue(forKey: layerID) else { return }
            let count = entry.bytesPerRow * entry.height
            var pixels = Data(count: count)
            let read = pixels.withUnsafeMutableBytes { target in
                entry.data.withUnsafeBytes { input in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, count,
                                              input.bindMemory(to: UInt8.self).baseAddress!, entry.data.count,
                                              nil, COMPRESSION_LZ4)
                }
            }
            guard read == count, let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: entry.width, height: entry.height, bitsPerComponent: entry.bitsPerComponent,
                                      bitsPerPixel: entry.bitsPerPixel, bytesPerRow: entry.bytesPerRow, space: entry.space,
                                      bitmapInfo: entry.bitmapInfo, provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent)
            else { return }
            compressedInkHits += 1
            inks[layerID] = (entry.revisions, InkSnapshot(image: image))
            touchInk(layerID)
            evictInks(keeping: layerID)
        }

        /// Commit a snapshot as the layer's current ink, keeping the replaced one for Undo.
        fileprivate func store(_ ink: InkSnapshot, revisions: [UUID], for layerID: UUID) {
            if let previous = inks[layerID], previous.revisions != revisions {
                previousInks.removeAll { $0.layerID == layerID && $0.revisions == previous.revisions }
                previousInks.insert((layerID, previous.revisions, previous.ink), at: 0)
            }
            inks[layerID] = (revisions, ink)
            touchInk(layerID)
            evictInks(keeping: layerID)
            previousInks.removeAll { $0.layerID == layerID && $0.revisions == revisions }
            var kept: [UUID: Int] = [:]
            var total = 0
            previousInks = previousInks.filter { entry in
                let size = Self.bytes(entry.ink)
                guard kept[entry.layerID, default: 0] < Self.previousInksPerLayer,
                      total + size <= Self.previousInkByteLimit else { return false }
                kept[entry.layerID, default: 0] += 1
                total += size
                return true
            }
        }

        /// The exact earlier state of this layer (after Undo or Redo), if still retained.
        fileprivate func previousInk(for layerID: UUID, revisions: [UUID]) -> InkSnapshot? {
            guard let entry = previousInks.first(where: { $0.layerID == layerID && $0.revisions == revisions })
            else { return nil }
            previousInkHits += 1
            return entry.ink
        }

        /// The longest retained state whose strokes start the new ones, to append the rest.
        fileprivate func appendBase(for layerID: UUID, revisions: [UUID]) -> (revisions: [UUID], ink: InkSnapshot)? {
            restoreCompressed(layerID)
            if let current = inks[layerID], revisions.starts(with: current.revisions) { return current }
            return previousInks
                .filter { $0.layerID == layerID && revisions.count > $0.revisions.count && revisions.starts(with: $0.revisions) }
                .max { $0.revisions.count < $1.revisions.count }
                .map { ($0.revisions, $0.ink) }
        }

        /// Drops every layer's float ink (and with it the compressed and Undo copies),
        /// keeping the composite and live state: a save that needs the memory calls it
        /// through `WatchArtworkRenderer.releaseAllCachedInks()`. Layers replay when next drawn.
        func releaseInks() {
            inks.removeAll()
            inkAccess.removeAll()
        }

        /// Drops the copies that only save a replay later: compressed inks of evicted
        /// layers and the Undo/Redo snapshots. Current inks stay (memory warning).
        func releaseSpareCopies() {
            compressedInks.removeAll()
            previousInks.removeAll()
        }

        fileprivate func retainLayers(_ ids: Set<UUID>) {
            inks = inks.filter { ids.contains($0.key) }
            inkAccess = inkAccess.filter { inks[$0.key] != nil }
            compressedInks = compressedInks.filter { ids.contains($0.key) }
            previousInks.removeAll { !ids.contains($0.layerID) }
        }
        fileprivate struct CompositeKey: Equatable {
            struct Layer: Equatable {
                let id: UUID
                let revisions: [UUID]
                let opacity: Float
            }
            let background: SIMD4<Float>
            let layers: [Layer]
        }
        fileprivate var composite: (key: CompositeKey, image: CGImage)?
        /// Eraser regions survive layer rebuilds (Undo past retained snapshots, resizes).
        let masks = ErasureMaskCache()
        // The layered renderer must keep coverage between input events too.
        // Replaying the whole live stroke here makes every later frame more expensive.
        fileprivate struct LiveInk {
            let layerID: UUID
            let revisions: [UUID]
            var stroke: Stroke
            let base: CGContext
            let frame: CGContext
            let coverage: WatchStrokeCoverage
            var snapshot: InkSnapshot?
        }
        fileprivate var liveInk: LiveInk?

        /// Pencil/pastel under the finger on a layer: grains of the whole gesture in an
        /// incremental field, written into a float copy of the layer's committed ink
        /// (`DryPixelFill`). Without it every frame replays the whole stroke.
        fileprivate final class LiveDry {
            let layerID: UUID
            let revisions: [UUID]
            var stroke: Stroke
            let frame: CGContext
            let geometry: WatchStrokeDrawing.DryGeometry
            let field: WatchStrokeDrawing.DryGrainField
            let fill: WatchStrokeDrawing.DryPixelFill
            var snapshot: InkSnapshot?
            var travel: Float = 0
            var drawn = false
            /// Snapped shape moved by the finger: `stroke` stays the exactly drawn reference.
            var shapePreview: WatchStrokeDrawing.DryShapePreview?
            var isPreviewing = false

            init(layerID: UUID, revisions: [UUID], stroke: Stroke, frame: CGContext,
                 fill: WatchStrokeDrawing.DryPixelFill) {
                self.layerID = layerID
                self.revisions = revisions
                self.stroke = stroke
                self.frame = frame
                self.fill = fill
                geometry = WatchStrokeDrawing.DryGeometry()
                field = WatchStrokeDrawing.DryGrainField()
                geometry.grainField = field
            }
        }
        fileprivate var liveDry: LiveDry?

        fileprivate func clearLive() {
            liveInk = nil
            liveDry = nil
            livePen = nil
        }

        /// Pen buffer of the selected layer; not promoted on lift (the layer replays it).
        fileprivate var livePen: (layerID: UUID, revisions: [UUID], ink: WatchBitmapRenderer.LivePenInk)?

        fileprivate func renderLivePen(_ stroke: Stroke, layerID: UUID, revisions: [UUID],
                                       base: InkSnapshot, scale: CGFloat) -> InkSnapshot? {
            liveInk = nil
            liveDry = nil
            guard WatchBitmapRenderer.LivePenInk.supports(stroke) else {
                livePen = nil
                return nil
            }
            if let live = livePen, live.layerID == layerID, live.revisions == revisions,
               live.ink.scale == scale, live.ink.origin == origin, live.ink.frame.width == base.image.width,
               live.ink.frame.height == base.image.height, live.ink.update(stroke) != nil {
                // Same gesture: extended.
            } else {
                guard let ink = WatchBitmapRenderer.LivePenInk(stroke: stroke, base: base.image, scale: scale,
                                                               origin: origin) else {
                    livePen = nil
                    return nil
                }
                livePen = (layerID, revisions, ink)
            }
            return livePen?.ink.frame.makeImage().map { InkSnapshot(image: $0) }
        }

        /// Layer, prefix and stroke of the live buffer, for promotion on lift.
        fileprivate var liveOwner: (layerID: UUID, revisions: [UUID], stroke: Stroke)? {
            if let liveDry { return (liveDry.layerID, liveDry.revisions, liveDry.stroke) }
            if let liveInk { return (liveInk.layerID, liveInk.revisions, liveInk.stroke) }
            return nil
        }

        /// A snapped shape turned or scaled by the finger: the exactly drawn shape moved as an
        /// image over the layer's committed ink. nil when `stroke` is not such a move.
        private func shapePreviewInk(_ stroke: Stroke, live: LiveDry, base: InkSnapshot,
                                     scale: CGFloat) -> InkSnapshot? {
            guard live.drawn, WatchStrokeDrawing.DryShapePreview.similarity(from: live.stroke, to: stroke) != nil
            else { return nil }
            if live.shapePreview?.reference.geometryRevision != live.stroke.geometryRevision {
                let started = RenderDiagnostics.begin()
                live.shapePreview = WatchStrokeDrawing.DryShapePreview(
                    reference: live.stroke, field: live.field, geometry: live.geometry,
                    width: live.frame.width, height: live.frame.height, scale: scale, floatOutput: true)
                RenderDiagnostics.end(.shapeLayer, started)
            }
            guard let preview = live.shapePreview else { return nil }
            let started = RenderDiagnostics.begin()
            guard let image = preview.frame(for: stroke, over: base.image, scale: scale) else { return nil }
            RenderDiagnostics.end(.shapePreview, started)
            live.isPreviewing = true
            return InkSnapshot(image: image)
        }

        /// Pencil/pastel live ink; nil falls back to replaying the stroke.
        /// `exact`: never show a transformed shape preview (lift).
        fileprivate func renderLiveDry(_ stroke: Stroke, layerID: UUID, revisions: [UUID],
                                       base: InkSnapshot, scale: CGFloat, exact: Bool = false) -> InkSnapshot? {
            liveInk = nil
            // The snapped-shape preview maps canvas points without a region offset; a
            // region redraws the adjusted shape incrementally from a fresh buffer instead.
            if !exact, !isRegion, let live = liveDry, live.layerID == layerID, live.revisions == revisions,
               live.stroke.id == stroke.id, !stroke.extends(live.stroke),
               let ink = shapePreviewInk(stroke, live: live, base: base, scale: scale) {
                return ink
            }
            if let live = liveDry, live.layerID == layerID, live.revisions == revisions,
               live.stroke.id == stroke.id, stroke.extends(live.stroke) {
                // Same gesture: continue.
            } else {
                let began = RenderDiagnostics.begin()
                defer { if liveDry != nil { RenderDiagnostics.dryBegan(began) } }
                // The new path needs both switches; the lock and lasso cut keep the replay.
                guard RenderStageSwitches.isOn(.incrementalDryGrains), RenderStageSwitches.isOn(.pixelDryFill),
                      !stroke.locksTransparency, stroke.transform == .identity, stroke.excludedAreas.isEmpty,
                      stroke.erasures.isEmpty, stroke.raster == nil,
                      let frame = WatchBitmapRenderer.makeFloatContext(width: base.image.width, height: base.image.height)
                else {
                    liveDry = nil
                    return nil
                }
                frame.draw(base.image, in: CGRect(x: 0, y: 0, width: base.image.width, height: base.image.height))
                guard let fill = WatchStrokeDrawing.DryPixelFill(frame: frame) else {
                    liveDry = nil
                    return nil
                }
                liveDry = LiveDry(layerID: layerID, revisions: revisions, stroke: stroke, frame: frame, fill: fill)
            }
            guard let live = liveDry else { return nil }
            if live.drawn, live.stroke.geometryRevision == stroke.geometryRevision, let snapshot = live.snapshot {
                return snapshot
            }
            let started = RenderDiagnostics.begin()
            let previousCount = live.drawn ? live.stroke.points.count : 0
            let counters = (live.geometry.grainBuildCount, live.geometry.coverageProbeCount,
                            live.geometry.contourBuildCount)
            // Opening pastel contact changes the opacity of every drawn grain.
            let contactChanges = stroke.style.instrument == .crayon && live.drawn && live.travel < 4
            live.geometry.append(stroke)
            let prepared = RenderDiagnostics.begin()
            live.field.update(live.geometry, stroke: stroke)
            let updated = RenderDiagnostics.begin()
            let canvas = CGRect(x: 0, y: 0, width: live.frame.width, height: live.frame.height)
            let pixels = live.field.dirtyRects(all: contactChanges).compactMap { paper -> CGRect? in
                let rect = paper.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                            tx: -origin.x * scale, ty: -origin.y * scale))
                    .integral.intersection(canvas)
                return rect.isNull || rect.isEmpty ? nil : rect
            }
            guard let result = live.fill.fillChanged(pixels, field: live.field, stroke: stroke,
                                                     geometry: live.geometry, frame: live.frame, scale: scale,
                                                     origin: origin)
            else {
                liveDry = nil
                return nil
            }
            if !result.tiles.isEmpty || live.snapshot == nil {
                guard let image = live.frame.makeImage() else {
                    liveDry = nil
                    return nil
                }
                live.snapshot = InkSnapshot(image: image)
            }
            live.stroke = stroke
            live.travel = live.geometry.travel
            live.drawn = true
            let grained = updated &+ result.rasterNS
            RenderDiagnostics.dryFrame(stages: [started, prepared, updated, grained, grained &+ result.compositeNS,
                                                RenderDiagnostics.begin()],
                                       incremental: true, pixel: true,
                                       samples: stroke.points.count - previousCount,
                                       tiles: result.tiles.count,
                                       grainsBuilt: live.geometry.grainBuildCount - counters.0,
                                       grainHits: result.grains,
                                       probes: live.geometry.coverageProbeCount - counters.1,
                                       contours: live.geometry.contourBuildCount - counters.2,
                                       full: previousCount == 0)
            return live.snapshot
        }

        fileprivate func renderLive(_ stroke: Stroke, layerID: UUID, revisions: [UUID],
                                    base: InkSnapshot, scale: CGFloat, exact: Bool = false) -> InkSnapshot? {
            // The incremental buffers size themselves from the base ink. In a region, a
            // layer without ink there holds a 1×1 ink: start from a blank raster instead.
            guard let base = rasterSized(base) else {
                clearLive()
                return nil
            }
            if stroke.style.instrument == .pencil || stroke.style.instrument == .crayon {
                return renderLiveDry(stroke, layerID: layerID, revisions: revisions, base: base,
                                     scale: scale, exact: exact)
            }
            if stroke.style.instrument == .pen, !exact {
                return renderLivePen(stroke, layerID: layerID, revisions: revisions, base: base, scale: scale)
            }
            livePen = nil
            liveDry = nil
            guard (stroke.style.instrument == .watercolor || stroke.style.instrument == .marker),
                  !stroke.locksTransparency, stroke.transform == .identity,
                  stroke.excludedAreas.isEmpty, stroke.erasures.isEmpty, stroke.raster == nil else {
                liveInk = nil
                return nil
            }
            if liveInk?.layerID != layerID || liveInk?.revisions != revisions ||
                liveInk.map({ !stroke.extends($0.stroke) || !$0.coverage.canAppend(stroke) }) != false {
                let width = base.image.width, height = base.image.height
                guard let backdrop = WatchBitmapRenderer.makeFloatContext(width: width, height: height),
                      let frame = WatchBitmapRenderer.makeFloatContext(width: width, height: height) else {
                    liveInk = nil
                    return nil
                }
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                backdrop.draw(base.image, in: bounds)
                frame.draw(base.image, in: bounds)
                liveInk = LiveInk(layerID: layerID, revisions: revisions, stroke: stroke,
                    base: backdrop, frame: frame,
                    coverage: WatchStrokeCoverage(style: stroke.style, width: width, height: height, scale: scale,
                                                  origin: origin))
            }
            guard var live = liveInk else { return nil }
            do {
                let dirty = try live.coverage.append(stroke)
                if !dirty.isNull, !dirty.isEmpty {
                    live.coverage.composite(dirty: dirty, over: live.base, into: live.frame)
                    live.snapshot = nil
                }
                if live.snapshot == nil {
                    guard let image = live.frame.makeImage() else {
                        liveInk = nil
                        return nil
                    }
                    live.snapshot = InkSnapshot(image: image)
                }
                live.stroke = stroke
                liveInk = live
                return live.snapshot
            } catch {
                liveInk = nil
                return nil
            }
        }

        /// `base` at this cache's raster size; a blank one for the 1×1 ink of a region
        /// layer that has no ink inside the region.
        private func rasterSized(_ base: InkSnapshot) -> InkSnapshot? {
            let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
            if base.image.width == width && base.image.height == height { return base }
            guard isRegion, width > 0, height > 0,
                  let blank = WatchBitmapRenderer.makeFloatContext(width: width, height: height)?.makeImage()
            else { return nil }
            return InkSnapshot(image: blank)
        }

        /// Discard committed images while preserving live-stroke ownership and counters.
        func clearCommittedImages() {
            inks.removeAll()
            composite = nil
        }

        private(set) var replayedStrokeCount = 0
        private(set) var compositeBuildCount = 0

        fileprivate func didReplay(_ count: Int) { replayedStrokeCount += count }
        fileprivate func didBuildComposite() { compositeBuildCount += 1 }
    }

    /// Layered frame: paper, the cached composite of lower layers, then each layer's
    /// committed ink (with the live stroke on the selected layer) in sequential blend order.
    static func render(document: CanvasDocument, size: CGSize, scale: CGFloat, origin: CGPoint = .zero,
                       isRegion: Bool = false,
                       activeStroke: Stroke? = nil, selectedLayerID: UUID? = nil,
                       cache: LayerCache? = nil, selection: WatchSelectionPreview? = nil,
                       paper: CGSize? = nil) -> CGImage? {
        // One-off whole-canvas renders (save, share, eyedropper, previews) of a large canvas
        // go through horizontal strips: each layer's float ink (16 B/px) then exists for
        // one strip at a time instead of for the whole paper.
        if cache == nil, !isRegion, origin == .zero, activeStroke == nil, selection == nil,
           size.width > 0, size.height > 0, scale > 0,
           ceil(size.width * scale) * ceil(size.height * scale) > stripRenderPixelThreshold {
            return renderInStrips(document: document, size: size, scale: scale)
        }
        guard size.width > 0, size.height > 0, scale > 0,
              size.width * scale <= 8192, size.height * scale <= 8192,
              let output = makeDisplayContext(width: Int(ceil(size.width * scale)),
                                              height: Int(ceil(size.height * scale))) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let background = document.effectiveBackgroundColor
        fillPaper(output, color: background, bounds: bounds)
        if let cache { prepare(cache, for: document, size: size, scale: scale, origin: origin, isRegion: isRegion) }
        let visible = document.layers.filter { $0.isVisible && $0.opacity > 0 }
        // Preserve the exact sequential blend order and 8-bit rounding. Cache the
        // paper and layers below the live layer, or the entire frame when idle.
        let liveLayerID = selection?.layerID ?? (activeStroke == nil ? nil : selectedLayerID)
        let prefixCount = visible.firstIndex { $0.id == liveLayerID } ?? visible.count
        let compositeKey = LayerCache.CompositeKey(background: background, layers: visible.prefix(prefixCount).map {
            .init(id: $0.id, revisions: $0.strokes.map(\.geometryRevision), opacity: $0.opacity)
        })
        let reusedComposite = RenderDiagnostics.measure(.composite) {
            reuseComposite(compositeKey, cache: cache, in: output, bounds: bounds)
        }
        // One-off renders of a save report their layers (`RenderProgress`); cached
        // canvas renders never run under one.
        // Only zoom tiles (regions with a cache) read blurs from the low-resolution source.
        // Whole-canvas renders hold all a blur reads, and save strips render their blur
        // margins, so the paper view and saved files keep blurs filtered as before.
        let blurPaper: CGSize? = isRegion && cache != nil ? (paper ?? document.canvasSize) : nil
        let progress = cache == nil ? RenderProgress.current : nil
        progress?.expect(visible.reduce(0) { $0 + RenderProgress.units(of: $1) })
        for (index, layer) in visible.enumerated() {
            defer { progress?.complete(RenderProgress.units(of: layer)) }
            if index == prefixCount, !reusedComposite, let cache {
                RenderDiagnostics.measure(.composite) { storeComposite(compositeKey, from: output, in: cache) }
            }
            if reusedComposite && index < prefixCount { continue }
            let revisions = layer.strokes.map(\.geometryRevision)
            guard let committed = RenderDiagnostics.measure(.committed, {
                committedInk(for: layer, revisions: revisions, size: size, scale: scale, origin: origin,
                             culls: isRegion,
                             cache: cache, selection: selection, paper: blurPaper)
            }) else { return nil }
            var ink = committed
            if layer.id == selectedLayerID, let activeStroke {
                guard let live = RenderDiagnostics.measure(.live, {
                    liveInk(activeStroke, over: committed, layerID: layer.id, revisions: revisions, origin: origin,
                            culls: isRegion,
                            size: size, scale: scale, cache: cache)
                }) else { return nil }
                ink = live
            }
            RenderDiagnostics.measure(.composite) {
                drawLayer(ink, opacity: layer.opacity, in: output, bounds: bounds)
            }
        }
        if activeStroke == nil || !visible.contains(where: { $0.id == selectedLayerID }) || selection != nil {
            cache?.clearLive()
        }
        return RenderDiagnostics.measure(.composite) {
            guard let image = output.makeImage() else { return nil }
            if prefixCount == visible.count, !reusedComposite, let cache {
                cache.composite = (compositeKey, image)
                cache.didBuildComposite()
            }
            return image
        }
    }

    /// Whole renders above this many pixels use strips. 1024 × 1024 px canvases (the limit
    /// before 2048 px) keep the single pass they always had, pixel for pixel.
    static let stripRenderPixelThreshold: CGFloat = 1024 * 1024 + 1
    /// Pixels of one strip, before its blur margins: ~8 MiB of float ink per layer.
    static let stripPixels: CGFloat = 512 * 1024

    /// A blur stroke's vertical extent and how far beyond its pixels it reads.
    private struct StripBlur {
        let minY: CGFloat
        let maxY: CGFloat
        let margin: CGFloat
    }

    /// Each visible layer's blurs in drawing order (layers with none left out).
    private static func stripBlurs(_ document: CanvasDocument) -> [[StripBlur]] {
        document.layers.filter { $0.isVisible && $0.opacity > 0 }.compactMap { layer in
            let blurs = layer.strokes.compactMap { stroke -> StripBlur? in
                guard stroke.style.instrument == .blur else { return nil }
                let reach = WatchBitmapRenderer.reach(of: stroke)
                guard !reach.isNull, reach.minY.isFinite, reach.maxY.isFinite else { return nil }
                return StripBlur(minY: reach.minY, maxY: reach.maxY, margin: blurMargin(of: [stroke]))
            }
            return blurs.isEmpty ? nil : blurs
        }
    }

    /// Canvas rows (points) a strip must render so that blur, which reads neighbouring
    /// pixels, sees what the full canvas would. A blur reads only its own layer's ink as
    /// drawn before it, so each layer is walked from its last blur back to its first:
    /// a blur reaching the rows needed so far adds its read margin where it overlaps
    /// them. The strip renders the union over layers. Pooling every blur of every layer
    /// (or summing their margins) made each strip of a drawing with many blurs the whole
    /// canvas, and saving it ran out of memory.
    private static func stripRows(_ band: ClosedRange<CGFloat>, layers: [[StripBlur]]) -> ClosedRange<CGFloat> {
        var low = band.lowerBound, high = band.upperBound
        for blurs in layers {
            var layerLow = band.lowerBound, layerHigh = band.upperBound
            for blur in blurs.reversed() where blur.maxY > layerLow && blur.minY < layerHigh {
                let overlapLow = max(layerLow, blur.minY), overlapHigh = min(layerHigh, blur.maxY)
                layerLow = min(layerLow, overlapLow - blur.margin)
                layerHigh = max(layerHigh, overlapHigh + blur.margin)
            }
            low = min(low, layerLow)
            high = max(high, layerHigh)
        }
        return low...high
    }

    /// Bytes a whole-canvas render of `document` needs at its peak, beyond the memory
    /// already in use: the 8-bit output, and one strip's float ink, eraser mask, working
    /// and transparency-layer buffers (~4 float buffers). Used to decide whether a save
    /// must first release the canvas's caches.
    static func estimatedRenderPeakBytes(document: CanvasDocument, size: CGSize, scale: CGFloat) -> Int {
        let width = ceil(size.width * scale), height = ceil(size.height * scale)
        guard width > 0, height > 0 else { return 0 }
        var stripPixelsAtPeak = width * height
        if width * height > stripRenderPixelThreshold {
            let rows = max(64, (stripPixels / width).rounded(.down))
            let layers = stripBlurs(document)
            var tallest: CGFloat = 0, top: CGFloat = 0
            while top < height {
                let bottom = min(height, top + rows)
                let needed = stripRows(top / scale...bottom / scale, layers: layers)
                let rendered = min(height, ceil(needed.upperBound * scale)) - max(0, floor(needed.lowerBound * scale))
                tallest = max(tallest, rendered)
                top = bottom
            }
            stripPixelsAtPeak = width * tallest
        }
        return Int(width * height * 4 + stripPixelsAtPeak * 16 * 4)
    }

    /// The same image as a single pass, assembled from viewport regions: regions match
    /// the full canvas pixel for pixel away from interior edges (`check-viewport-region`),
    /// and each strip renders the rows its blurs read (`stripRows`), then keeps only its own.
    /// No layer cache: like the single pass, one layer's float ink exists at a time
    /// (a cache kept every layer's ink of the strip, up to its whole budget).
    static func renderInStrips(document: CanvasDocument, size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              let output = makeDisplayContext(width: width, height: height) else { return nil }
        output.interpolationQuality = .none
        output.setBlendMode(.copy)
        let rows = max(64, Int(stripPixels) / width)
        let stripCount = (height + rows - 1) / rows
        RenderProgress.current?.expect(document.layers.filter { $0.isVisible && $0.opacity > 0 }
            .reduce(0) { $0 + RenderProgress.units(of: $1) } * Double(stripCount))
        let blurs = stripBlurs(document)
        var top = 0
        while top < height {
            if Task.isCancelled { return nil }
            let bottom = min(height, top + rows)
            let needed = stripRows(CGFloat(top) / scale...CGFloat(bottom) / scale, layers: blurs)
            let renderTop = max(0, min(top, Int(floor(needed.lowerBound * scale))))
            let renderBottom = min(height, max(bottom, Int(ceil(needed.upperBound * scale))))
            // Whole pixels of the full raster; slightly under the pixel count so
            // `ceil(size × scale)` cannot add a row (as `RegionTiling.tile`).
            let origin = CGPoint(x: 0, y: CGFloat(renderTop) / scale)
            let stripSize = CGSize(width: size.width, height: (CGFloat(renderBottom - renderTop) - 0.001) / scale)
            let image: CGImage? = autoreleasepool {
                guard let strip = render(document: document, size: stripSize, scale: scale, origin: origin,
                                         isRegion: true, paper: size),
                      strip.width == width, strip.height == renderBottom - renderTop else { return nil }
                return strip.cropping(to: CGRect(x: 0, y: top - renderTop, width: width, height: bottom - top))
            }
            guard let image else { return nil }
            // Core Graphics' origin is bottom-left; rows count from the top.
            output.draw(image, in: CGRect(x: 0, y: height - bottom, width: width, height: bottom - top))
            top = bottom
        }
        return output.makeImage()
    }

    // MARK: Layer pipeline stages

    private static func fillPaper(_ output: CGContext, color c: SIMD4<Float>, bounds: CGRect) {
        output.setFillColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)))
        output.fill(bounds)
    }

    /// Drop images for another raster size and for layers that no longer exist.
    private static func prepare(_ cache: LayerCache, for document: CanvasDocument, size: CGSize, scale: CGFloat,
                                origin: CGPoint, isRegion: Bool) {
        if cache.size != size || cache.scale != scale || cache.origin != origin || cache.isRegion != isRegion {
            cache.inks.removeAll()
            cache.composite = nil
            cache.clearLive()
        }
        cache.size = size
        cache.scale = scale
        cache.origin = origin
        cache.isRegion = isRegion
        cache.retainLayers(Set(document.layers.map(\.id)))
    }

    /// Paper and unchanged lower layers in one copy, when the cached composite matches.
    private static func reuseComposite(_ key: LayerCache.CompositeKey, cache: LayerCache?,
                                       in output: CGContext, bounds: CGRect) -> Bool {
        guard let composite = cache?.composite, composite.key == key else { return false }
        output.setBlendMode(.copy)
        output.draw(composite.image, in: bounds)
        output.setBlendMode(.normal)
        return true
    }

    private static func storeComposite(_ key: LayerCache.CompositeKey, from output: CGContext, in cache: LayerCache) {
        guard let image = output.makeImage() else { return }
        cache.composite = (key, image)
        cache.didBuildComposite()
    }

    /// The layer's committed ink: a lasso replay, a cache hit, an Undo snapshot,
    /// the promoted live stroke, or a replay of the strokes past the cached prefix.
    /// `paper`: the full canvas, for blurs that read beyond a region (`BlurSourceContext`).
    private static func committedInk(for layer: CanvasLayer, revisions: [UUID], size: CGSize, scale: CGFloat,
                                     origin: CGPoint, culls: Bool,
                                     cache: LayerCache?, selection: WatchSelectionPreview?,
                                     paper: CGSize? = nil) -> InkSnapshot? {
        if selection?.layerID == layer.id {
            // Replay the selected layer in its original order. Other layers stay cached.
            return renderInk(strokes: layer.strokes, size: size, scale: scale, selection: selection, origin: origin,
                             cullsOutside: culls)
        }
        if let ink = cache?.currentInk(for: layer.id, revisions: revisions) {
            return ink
        }
        if let cache, let earlier = cache.previousInk(for: layer.id, revisions: revisions) {
            cache.store(earlier, revisions: revisions, for: layer.id)
            return earlier
        }
        let previous = cache?.appendBase(for: layer.id, revisions: revisions)
        let committed: InkSnapshot
        let promoting = RenderDiagnostics.begin()
        let previewed = cache?.liveDry?.isPreviewing == true
        if let promoted = promotedLiveInk(layer, previous: previous, cache: cache, scale: scale) {
            RenderDiagnostics.shapeCommitted(previewed ? "layer exact" : "layer extend", promoting)
            committed = promoted
            cache?.clearLive()
        } else {
            let replaying = RenderDiagnostics.begin()
            defer { RenderDiagnostics.shapeCommitted("layer REPLAY", replaying) }
            let pending = previous.map { Array(layer.strokes.dropFirst($0.revisions.count)) } ?? layer.strokes
            let blurSource = paper.map {
                BlurSourceContext(before: Array(layer.strokes.prefix(layer.strokes.count - pending.count)), paper: $0)
            }
            guard let ink = renderInk(strokes: pending, size: size, scale: scale,
                                      base: previous?.ink, masks: cache?.masks, origin: origin,
                                      cullsOutside: culls, blurSource: blurSource) else { return nil }
            cache?.didReplay(pending.count)
            committed = ink
        }
        cache?.store(committed, revisions: revisions, for: layer.id)
        return committed
    }

    /// The one new stroke is the live stroke this layer already holds in its buffer.
    private static func promotedLiveInk(_ layer: CanvasLayer, previous: (revisions: [UUID], ink: InkSnapshot)?,
                                        cache: LayerCache?, scale: CGFloat) -> InkSnapshot? {
        guard let previous, let cache, let live = cache.liveOwner,
              layer.strokes.count == previous.revisions.count + 1, let final = layer.strokes.last,
              live.layerID == layer.id, live.revisions == previous.revisions,
              // A previewed shape is drawn exactly here, once, from a fresh buffer.
              final.extends(live.stroke) || (final.id == live.stroke.id && cache.liveDry?.isPreviewing == true)
        else { return nil }
        return cache.renderLive(final, layerID: layer.id, revisions: previous.revisions,
                                base: previous.ink, scale: scale, exact: true)
    }

    /// The live stroke over the layer's committed ink, incrementally when possible.
    private static func liveInk(_ activeStroke: Stroke, over committed: InkSnapshot, layerID: UUID,
                                revisions: [UUID], origin: CGPoint, culls: Bool, size: CGSize, scale: CGFloat,
                                cache: LayerCache?) -> InkSnapshot? {
        if let live = cache?.renderLive(activeStroke, layerID: layerID, revisions: revisions,
                                        base: committed, scale: scale) {
            return live
        }
        return renderInk(strokes: [activeStroke], size: size, scale: scale, base: committed, origin: origin,
                         cullsOutside: culls)
    }

    private static func drawLayer(_ ink: InkSnapshot, opacity: Float, in output: CGContext, bounds: CGRect) {
        output.saveGState()
        output.setAlpha(CGFloat(opacity))
        output.draw(ink.image, in: bounds)
        output.restoreGState()
    }


    static func fillImage(layer: CanvasLayer, size: CGSize, cache: LayerCache) -> CGImage? {
        let scale: CGFloat = 2
        let revisions = layer.strokes.map(\.geometryRevision)
        if ceil(size.width * scale) * ceil(size.height * scale) > stripRenderPixelThreshold {
            // A 2048 px canvas's float ink is 64 MiB, kept for incremental fills. Render
            // the layer alone, opaque and over no paper, in strips instead: 16 MiB at
            // 8 bits, re-rendered whole after each change (no incremental append).
            cache.inks.removeAll()
            if let kept = cache.fillStripImage, kept.layerID == layer.id, kept.size == size,
               kept.revisions == revisions { return kept.image }
            cache.fillStripImage = nil
            var single = layer
            single.isVisible = true
            single.opacity = 1
            var document = CanvasDocument()
            document.layers = [single]
            document.backgroundIsVisible = false
            guard let image = renderInStrips(document: document, size: size, scale: scale),
                  !Task.isCancelled else { return nil }
            cache.fillStripImage = (layer.id, size, revisions, image)
            return image
        }
        cache.fillStripImage = nil
        if cache.size != size || cache.scale != scale {
            cache.inks.removeAll()
        }
        cache.size = size
        cache.scale = scale
        cache.inks = cache.inks.filter { $0.key == layer.id }
        let previous = cache.inks[layer.id]
        if previous?.revisions == revisions { return previous?.ink.image }
        let canAppend = previous.map { revisions.starts(with: $0.revisions) } ?? false
        let strokes = canAppend ? Array(layer.strokes.dropFirst(previous!.revisions.count)) : layer.strokes
        guard let ink = renderInk(strokes: strokes, size: size, scale: scale,
                                  base: canAppend ? previous?.ink : nil, masks: cache.masks),
              !Task.isCancelled else { return nil }
        cache.inks[layer.id] = (revisions, ink)
        return ink.image
    }
}
