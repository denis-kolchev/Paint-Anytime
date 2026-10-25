import SwiftUI
import simd
import ImageIO

nonisolated extension WatchBitmapRenderer {
    /// Preserve the selected layer's isolation and the order of static artwork
    /// above/below it. Contiguous normal-blended selections can move as one texture.
    final class SelectionRenderCache {
        private var sessionID: UUID?
        private var key: CacheKey?
        private var background: CGImage?
        private var foreground: CGImage?
        private var region = CGRect.zero
        private var layerBelow: CGImage?
        private var layerAbove: CGImage?
        private var upperLayers: CGImage?
        private var opacity: Float = 1
        private let layers = LayerCache()
        private struct StaticSelectionKey: Equatable {
            let document: CanvasDocument
            let layerID: UUID
            let insertionIndex: Int
            let size: CGSize
            let scale: CGFloat
        }
        private var staticKey: StaticSelectionKey?
        private var staticBackground: CGImage?
        private var staticBelow: CGImage?
        private var staticAbove: CGImage?
        private var staticUpper: CGImage?

        func clear() {
            sessionID = nil
            key = nil
            background = nil
            foreground = nil
            layerBelow = nil
            layerAbove = nil
            upperLayers = nil
            layers.clearCommittedImages()
        }

        func render(_ preview: WatchSelectionPreview, key nextKey: CacheKey, allowReplay: Bool = true) -> ScreenFrame? {
            if sessionID != preview.sessionID || key != nextKey {
                clear()
                sessionID = preview.sessionID
                key = nextKey
                prepare(preview, key: nextKey)
            }
            guard let background, let foreground else {
                guard allowReplay else { return nil }
                guard let image = WatchBitmapRenderer.render(document: preview.document, size: nextKey.size,
                    scale: nextKey.scale, cache: layers, selection: preview) else { return nil }
                return ScreenFrame(background: image, tiles: [])
            }
            // Publish the two immutable textures once. The view applies the live
            // matrix without allocating/resampling a full canvas bitmap per update.
            return ScreenFrame(background: background, tiles: [], selection: SelectionTexture(
                image: foreground, rect: region, sessionID: preview.sessionID,
                key: nextKey, transform: preview.transform, layerBelow: layerBelow,
                layerAbove: layerAbove, upperLayers: upperLayers, opacity: opacity))
        }

        private func prepare(_ preview: WatchSelectionPreview, key: CacheKey) {
            let visible = preview.document.layers.filter { $0.isVisible && $0.opacity > 0 }
            guard let index = visible.firstIndex(where: { $0.id == preview.layerID }) else { return }
            let layer = visible[index]
            guard let start = layer.strokes.firstIndex(where: { preview.selectedIDs.contains($0.id) }),
                  let end = layer.strokes.lastIndex(where: { preview.selectedIDs.contains($0.id) }),
                  layer.strokes[start...end].allSatisfy({ preview.selectedIDs.contains($0.id) }) else { return }
            func independent(_ stroke: Stroke) -> Bool {
                !stroke.locksTransparency && stroke.style.instrument != .eraser &&
                    ((stroke.style.instrument != .marker && stroke.style.instrument != .watercolor) ||
                     stroke.style.blendingMode == .normal)
            }
            // Later dependent blends must see the moved ink: those use exact replay.
            guard layer.strokes[start...].allSatisfy(independent) else { return }
            var extent = preview.bounds
            for stroke in layer.strokes[start...end] {
                guard !Task.isCancelled, let geometry = try? StrokeGeometry(stroke) else { return }
                extent = extent.union(geometry.bounds)
            }
            guard !extent.isNull, !extent.isEmpty, extent.width.isFinite, extent.height.isFinite,
                  key.size.width > 0, key.size.height > 0 else { return }
            // Interaction needs a screen-sized bitmap, not export/zoom resolution.
            // Cap each retained image at roughly 1 MiB in 8-bit RGBA.
            let largestArea = max(extent.width * extent.height, key.size.width * key.size.height)
            let longestSide = max(max(extent.width, extent.height), max(key.size.width, key.size.height))
            let scale = min(key.scale, 2, sqrt(262_144 / largestArea), 2048 / longestSide)
            guard scale.isFinite, scale > 0 else { return }
            let pixels = extent.insetBy(dx: -2 / scale, dy: -2 / scale)
                .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            let region = pixels.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            let local = layer.strokes[start...end].map { source in
                var stroke = source
                stroke.transform = StrokeTransform(source.transform.affine.concatenating(
                    CGAffineTransform(translationX: -region.minX, y: -region.minY)))
                return stroke
            }
            // Keep float buffers only during preparation; upload compact textures.
            func compact(_ image: CGImage?) -> CGImage? {
                guard let image, let context = makeDisplayContext(width: image.width, height: image.height) else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return context.makeImage()
            }
            guard let foreground = compact(layerThumbnail(strokes: local, size: region.size, scale: scale)) else { return }
            // Only the selected objects change during successive moves. Reuse
            // the expensive static artwork even when the document revision and
            // selection session advance after committing a transform.
            var staticDocument = preview.document
            if let layerIndex = staticDocument.layers.firstIndex(where: { $0.id == preview.layerID }) {
                staticDocument.layers[layerIndex].strokes.removeSubrange(start...end)
            }
            let nextStaticKey = StaticSelectionKey(document: staticDocument,
                layerID: preview.layerID, insertionIndex: start, size: key.size, scale: scale)
            if staticKey == nextStaticKey, let staticBackground {
                self.region = region
                self.background = staticBackground
                self.foreground = foreground
                self.layerBelow = staticBelow
                self.layerAbove = staticAbove
                self.upperLayers = staticUpper
                self.opacity = layer.opacity
                return
            }
            // Drop the old textures before allocating a different static scene.
            staticKey = nil
            staticBackground = nil
            staticBelow = nil
            staticAbove = nil
            staticUpper = nil
            var below: CGImage?
            if start > 0 {
                guard let image = compact(layerThumbnail(strokes: Array(layer.strokes[..<start]), size: key.size, scale: scale)) else { return }
                below = image
            }
            var above: CGImage?
            if end + 1 < layer.strokes.count {
                guard let image = compact(layerThumbnail(strokes: Array(layer.strokes[(end + 1)...]), size: key.size, scale: scale)) else { return }
                above = image
            }
            var lower = preview.document
            lower.layers = Array(visible[..<index])
            guard let background = WatchBitmapRenderer.render(document: lower, size: key.size, scale: scale) else { return }
            var upper: CGImage?
            if index + 1 < visible.count {
                var document = preview.document
                document.layers = Array(visible[(index + 1)...])
                document.backgroundIsVisible = false
                guard let image = WatchBitmapRenderer.render(document: document, size: key.size, scale: scale) else { return }
                upper = image
            }
            guard !Task.isCancelled else { return }
            self.region = region
            self.background = background
            self.foreground = foreground
            self.layerBelow = below
            self.layerAbove = above
            self.upperLayers = upper
            self.opacity = layer.opacity
            staticKey = nextStaticKey
            staticBackground = background
            staticBelow = below
            staticAbove = above
            staticUpper = upper
        }
    }
}
