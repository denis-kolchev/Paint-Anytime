import SwiftUI
import simd
import ImageIO

nonisolated extension WatchBitmapRenderer {
    /// Layers are isolated so erasers never punch through neighbouring artwork.
    final class LayerCache {
        var size: CGSize = .zero
        var scale: CGFloat = 0
        fileprivate var inks: [UUID: (revisions: [UUID], ink: InkSnapshot)] = [:] {
            didSet { if inks.isEmpty { previousInks.removeAll() } }
        }
        /// Snapshots replaced by later commits, newest first. Undo and Redo return to one
        /// of these exactly, so the first frame after them needs no replay of the layer.
        private var previousInks: [(layerID: UUID, revisions: [UUID], ink: InkSnapshot)] = []
        static let previousInksPerLayer = 2
        static let previousInkByteLimit = 12 * 1024 * 1024
        private(set) var previousInkHits = 0

        private static func bytes(_ ink: InkSnapshot) -> Int { ink.image.bytesPerRow * ink.image.height }

        /// Commit a snapshot as the layer's current ink, keeping the replaced one for Undo.
        fileprivate func store(_ ink: InkSnapshot, revisions: [UUID], for layerID: UUID) {
            if let previous = inks[layerID], previous.revisions != revisions {
                previousInks.removeAll { $0.layerID == layerID && $0.revisions == previous.revisions }
                previousInks.insert((layerID, previous.revisions, previous.ink), at: 0)
            }
            inks[layerID] = (revisions, ink)
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
            if let current = inks[layerID], revisions.starts(with: current.revisions) { return current }
            return previousInks
                .filter { $0.layerID == layerID && revisions.count > $0.revisions.count && revisions.starts(with: $0.revisions) }
                .max { $0.revisions.count < $1.revisions.count }
                .map { ($0.revisions, $0.ink) }
        }

        fileprivate func retainLayers(_ ids: Set<UUID>) {
            inks = inks.filter { ids.contains($0.key) }
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
               live.ink.scale == scale, live.ink.frame.width == base.image.width,
               live.ink.frame.height == base.image.height, live.ink.update(stroke) != nil {
                // Same gesture: extended.
            } else {
                guard let ink = WatchBitmapRenderer.LivePenInk(stroke: stroke, base: base.image, scale: scale) else {
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
            if !exact, let live = liveDry, live.layerID == layerID, live.revisions == revisions,
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
                let rect = paper.applying(CGAffineTransform(scaleX: scale, y: scale)).integral.intersection(canvas)
                return rect.isNull || rect.isEmpty ? nil : rect
            }
            guard let result = live.fill.fillChanged(pixels, field: live.field, stroke: stroke,
                                                     geometry: live.geometry, frame: live.frame, scale: scale)
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
                    coverage: WatchStrokeCoverage(style: stroke.style, width: width, height: height, scale: scale))
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
    static func render(document: CanvasDocument, size: CGSize, scale: CGFloat,
                       activeStroke: Stroke? = nil, selectedLayerID: UUID? = nil,
                       cache: LayerCache? = nil, selection: WatchSelectionPreview? = nil) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0,
              size.width * scale <= 8192, size.height * scale <= 8192,
              let output = makeDisplayContext(width: Int(ceil(size.width * scale)),
                                              height: Int(ceil(size.height * scale))) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let background = document.effectiveBackgroundColor
        fillPaper(output, color: background, bounds: bounds)
        if let cache { prepare(cache, for: document, size: size, scale: scale) }
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
        for (index, layer) in visible.enumerated() {
            if index == prefixCount, !reusedComposite, let cache {
                RenderDiagnostics.measure(.composite) { storeComposite(compositeKey, from: output, in: cache) }
            }
            if reusedComposite && index < prefixCount { continue }
            let revisions = layer.strokes.map(\.geometryRevision)
            guard let committed = RenderDiagnostics.measure(.committed, {
                committedInk(for: layer, revisions: revisions, size: size, scale: scale,
                             cache: cache, selection: selection)
            }) else { return nil }
            var ink = committed
            if layer.id == selectedLayerID, let activeStroke {
                guard let live = RenderDiagnostics.measure(.live, {
                    liveInk(activeStroke, over: committed, layerID: layer.id, revisions: revisions,
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

    // MARK: Layer pipeline stages

    private static func fillPaper(_ output: CGContext, color c: SIMD4<Float>, bounds: CGRect) {
        output.setFillColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)))
        output.fill(bounds)
    }

    /// Drop images for another raster size and for layers that no longer exist.
    private static func prepare(_ cache: LayerCache, for document: CanvasDocument, size: CGSize, scale: CGFloat) {
        if cache.size != size || cache.scale != scale {
            cache.inks.removeAll()
            cache.composite = nil
            cache.clearLive()
        }
        cache.size = size
        cache.scale = scale
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
    private static func committedInk(for layer: CanvasLayer, revisions: [UUID], size: CGSize, scale: CGFloat,
                                     cache: LayerCache?, selection: WatchSelectionPreview?) -> InkSnapshot? {
        if selection?.layerID == layer.id {
            // Replay the selected layer in its original order. Other layers stay cached.
            return renderInk(strokes: layer.strokes, size: size, scale: scale, selection: selection)
        }
        if let entry = cache?.inks[layer.id], entry.revisions == revisions {
            return entry.ink
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
            guard let ink = renderInk(strokes: pending, size: size, scale: scale,
                                      base: previous?.ink, masks: cache?.masks) else { return nil }
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
                                revisions: [UUID], size: CGSize, scale: CGFloat,
                                cache: LayerCache?) -> InkSnapshot? {
        if let live = cache?.renderLive(activeStroke, layerID: layerID, revisions: revisions,
                                        base: committed, scale: scale) {
            return live
        }
        return renderInk(strokes: [activeStroke], size: size, scale: scale, base: committed)
    }

    private static func drawLayer(_ ink: InkSnapshot, opacity: Float, in output: CGContext, bounds: CGRect) {
        output.saveGState()
        output.setAlpha(CGFloat(opacity))
        output.draw(ink.image, in: bounds)
        output.restoreGState()
    }


    static func fillImage(layer: CanvasLayer, size: CGSize, cache: LayerCache) -> CGImage? {
        let scale: CGFloat = 2
        if cache.size != size || cache.scale != scale {
            cache.inks.removeAll()
        }
        cache.size = size
        cache.scale = scale
        cache.inks = cache.inks.filter { $0.key == layer.id }
        let revisions = layer.strokes.map(\.geometryRevision)
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
