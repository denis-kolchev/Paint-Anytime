import SwiftUI
import simd
import ImageIO

nonisolated extension WatchBitmapRenderer {
    /// Layers are isolated so erasers never punch through neighbouring artwork.
    final class LayerCache {
        var size: CGSize = .zero
        var scale: CGFloat = 0
        fileprivate var inks: [UUID: (revisions: [UUID], ink: InkSnapshot)] = [:]
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

    static func render(document: CanvasDocument, size: CGSize, scale: CGFloat,
                       activeStroke: Stroke? = nil, selectedLayerID: UUID? = nil,
                       cache: LayerCache? = nil, selection: WatchSelectionPreview? = nil) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0,
              size.width * scale <= 8192, size.height * scale <= 8192,
              let output = makeDisplayContext(width: Int(ceil(size.width * scale)),
                                              height: Int(ceil(size.height * scale))) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let c = document.effectiveBackgroundColor
        output.setFillColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)))
        output.fill(bounds)
        if let cache {
            if cache.size != size || cache.scale != scale {
                cache.inks.removeAll()
                cache.composite = nil
                cache.liveInk = nil
            }
            cache.size = size
            cache.scale = scale
            cache.inks = cache.inks.filter { id, _ in document.layers.contains { $0.id == id } }
        }
        let visible = document.layers.filter { $0.isVisible && $0.opacity > 0 }
        // Preserve the exact sequential blend order and 8-bit rounding. Cache the
        // paper and layers below the live layer, or the entire frame when idle.
        let liveLayerID = selection?.layerID ?? (activeStroke == nil ? nil : selectedLayerID)
        let liveIndex = visible.firstIndex { $0.id == liveLayerID }
        let prefixCount = liveIndex ?? visible.count
        let compositeKey = LayerCache.CompositeKey(background: c, layers: visible.prefix(prefixCount).map {
            .init(id: $0.id, revisions: $0.strokes.map(\.geometryRevision), opacity: $0.opacity)
        })
        let reusedComposite = cache?.composite?.key == compositeKey
        if reusedComposite, let image = cache?.composite?.image {
            output.setBlendMode(.copy)
            output.draw(image, in: bounds)
            output.setBlendMode(.normal)
        }
        for (index, layer) in visible.enumerated() {
            if index == prefixCount, !reusedComposite, let cache, let image = output.makeImage() {
                cache.composite = (compositeKey, image)
                cache.didBuildComposite()
            }
            if reusedComposite && index < prefixCount { continue }
            let revisions = layer.strokes.map(\.geometryRevision)
            let committed: InkSnapshot
            if selection?.layerID == layer.id {
                // Replay the selected layer in its original order. Other layers stay cached.
                guard let ink = renderInk(strokes: layer.strokes, size: size, scale: scale,
                                          selection: selection) else { return nil }
                committed = ink
            } else if let entry = cache?.inks[layer.id], entry.revisions == revisions {
                committed = entry.ink
            } else {
                let previous = cache?.inks[layer.id]
                let canAppend = previous.map { revisions.starts(with: $0.revisions) } ?? false
                let pending = canAppend ? Array(layer.strokes.dropFirst(previous!.revisions.count)) : layer.strokes
                if canAppend, pending.count == 1, let final = pending.first,
                   let cache, let live = cache.liveInk, let previous,
                   live.layerID == layer.id, live.revisions == previous.revisions,
                   final.extends(live.stroke),
                   let promoted = cache.renderLive(final, layerID: layer.id, revisions: previous.revisions,
                                                   base: previous.ink, scale: scale) {
                    committed = promoted
                    cache.liveInk = nil
                } else {
                    guard let ink = renderInk(strokes: pending, size: size, scale: scale,
                                              base: canAppend ? previous?.ink : nil) else { return nil }
                    cache?.didReplay(pending.count)
                    committed = ink
                }
                cache?.inks[layer.id] = (revisions, committed)
            }
            var ink = committed
            if layer.id == selectedLayerID, let activeStroke {
                if let live = cache?.renderLive(activeStroke, layerID: layer.id, revisions: revisions,
                                                base: committed, scale: scale) {
                    ink = live
                } else {
                    guard let live = renderInk(strokes: [activeStroke], size: size, scale: scale, base: committed) else { return nil }
                    ink = live
                }
            }
            output.saveGState()
            output.setAlpha(CGFloat(layer.opacity))
            output.draw(ink.image, in: bounds)
            output.restoreGState()
        }
        if activeStroke == nil || !visible.contains(where: { $0.id == selectedLayerID }) || selection != nil {
            cache?.liveInk = nil
        }
        guard let image = output.makeImage() else { return nil }
        if prefixCount == visible.count, !reusedComposite, let cache {
            cache.composite = (compositeKey, image)
            cache.didBuildComposite()
        }
        return image
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
                                  base: canAppend ? previous?.ink : nil), !Task.isCancelled else { return nil }
        cache.inks[layer.id] = (revisions, ink)
        return ink.image
    }
}
