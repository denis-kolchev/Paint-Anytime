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

        fileprivate func renderLive(_ stroke: Stroke, layerID: UUID, revisions: [UUID],
                                    base: InkSnapshot, scale: CGFloat) -> InkSnapshot? {
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
            cache?.liveInk = nil
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
            cache.liveInk = nil
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
        if let promoted = promotedLiveInk(layer, previous: previous, cache: cache, scale: scale) {
            committed = promoted
            cache?.liveInk = nil
        } else {
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
        guard let previous, let cache, let live = cache.liveInk,
              layer.strokes.count == previous.revisions.count + 1, let final = layer.strokes.last,
              live.layerID == layer.id, live.revisions == previous.revisions,
              final.extends(live.stroke) else { return nil }
        return cache.renderLive(final, layerID: layer.id, revisions: previous.revisions,
                                base: previous.ink, scale: scale)
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
