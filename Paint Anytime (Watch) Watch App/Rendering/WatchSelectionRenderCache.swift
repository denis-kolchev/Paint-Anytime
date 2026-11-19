import SwiftUI
import simd
import ImageIO

nonisolated extension WatchBitmapRenderer {
    /// Preserve the selected layer's isolation and the order of static artwork
    /// above/below it. The selected strokes move as one texture.
    ///
    /// With a `SelectionViewport` the textures follow the screen, as editors that move a
    /// cached selection do (Fabric.js object caches, viewport-bounded rasters): the
    /// selection at the resolution the screen shows it, within `foregroundPixelBudget`;
    /// the static scene for the visible area plus a margin only, at the zoom tiles'
    /// resolution, within `staticPixelBudget` per image. Before, every texture covered
    /// the whole paper at ≤ 2 px per point and the zoomed view lost its sharpness on grab.
    final class SelectionRenderCache {
        /// Pixels of the moving selection: 3 MiB in 8-bit RGBA (12 MiB of float ink while
        /// it is prepared). About twice the watch screen, so a selection larger than the
        /// view still has screen resolution when dragged into it.
        static let foregroundPixelBudget: CGFloat = 786_432
        /// Pixels of each static image (2 MiB). The view plus margin needs about 330 k.
        static let staticPixelBudget: CGFloat = 524_288
        /// The low-resolution static scene shown outside `staticRect` (1 MiB).
        static let underlayPixelBudget: CGFloat = 262_144

        private var sessionID: UUID?
        private var key: CacheKey?
        private var viewport: SelectionViewport?
        private var background: CGImage?
        private var foreground: CGImage?
        private var region = CGRect.zero
        private var foregroundScale: CGFloat = 1
        private var layerBelow: CGImage?
        private var layerAbove: CGImage?
        private var upperLayers: CGImage?
        private var staticRect = CGRect.zero
        private var staticScale: CGFloat = 1
        private var underlay: CGImage?
        private var isApproximate = false
        private var opacity: Float = 1
        /// Why the last preparation produced no textures, for the diagnostics line.
        private var refusal = "—"
        private let layers = LayerCache()

        private struct StaticSelectionKey: Equatable {
            let document: CanvasDocument
            let layerID: UUID
            let insertionIndex: Int
            let paper: CGSize
            let rect: CGRect
            let scale: CGFloat
        }
        private var staticKey: StaticSelectionKey?
        private var staticBackground: CGImage?
        private var staticBelow: CGImage?
        private var staticAbove: CGImage?
        private var staticUpper: CGImage?

        private struct ForegroundKey: Equatable {
            let strokes: [Stroke]
            let scale: CGFloat
        }
        private var foregroundKey: ForegroundKey?
        private var cachedForeground: CGImage?
        private var cachedRegion = CGRect.zero

        private struct UnderlayKey: Equatable {
            let document: CanvasDocument
            let paper: CGSize
            let scale: CGFloat
        }
        private var underlayKey: UnderlayKey?
        private var cachedUnderlay: CGImage?
        /// The static scene of the current preparation, for `prepareUnderlay`.
        private var staticDocument: CanvasDocument?

        func clear() {
            sessionID = nil
            key = nil
            viewport = nil
            background = nil
            foreground = nil
            layerBelow = nil
            layerAbove = nil
            upperLayers = nil
            underlay = nil
            staticDocument = nil
            layers.clearCommittedImages()
        }

        /// The textures describe the same scene whatever the paper raster's scale, so a
        /// raster scale change (zoom settling) neither prepares again nor hides them.
        static func sameScene(_ lhs: CacheKey, _ rhs: CacheKey) -> Bool {
            lhs.documentID == rhs.documentID && lhs.documentRevision == rhs.documentRevision
                && lhs.size == rhs.size && lhs.origin == rhs.origin && lhs.isRegion == rhs.isRegion
        }

        func render(_ preview: WatchSelectionPreview, key nextKey: CacheKey, viewport nextViewport: SelectionViewport? = nil,
                    allowReplay: Bool = true) -> ScreenFrame? {
            let sameKey = key.map { nextViewport == nil ? $0 == nextKey : Self.sameScene($0, nextKey) } ?? false
            if sessionID != preview.sessionID || !sameKey || viewport != nextViewport {
                clear()
                sessionID = preview.sessionID
                key = nextKey
                viewport = nextViewport
                prepare(preview, key: nextKey, viewport: nextViewport)
                // A superseded preparation must run again on the next request, not leave
                // this session on the replay path.
                if foreground == nil || background == nil, Task.isCancelled { sessionID = nil }
            }
            guard let background, let foreground else {
                RenderDiagnostics.setSelectionPath("replay · \(refusal)")
                guard allowReplay else { return nil }
                guard let image = WatchBitmapRenderer.render(document: preview.document, size: nextKey.size,
                    scale: nextKey.scale, cache: layers, selection: preview) else { return nil }
                return ScreenFrame(background: image, tiles: [])
            }
            // Publish the immutable textures once. The view applies the live
            // matrix without allocating/resampling a full canvas bitmap per update.
            return ScreenFrame(background: background, tiles: [], selection: SelectionTexture(
                image: foreground, rect: region, scale: foregroundScale, sessionID: preview.sessionID,
                key: key ?? nextKey, transform: preview.transform, layerBelow: layerBelow,
                layerAbove: layerAbove, upperLayers: upperLayers, opacity: opacity,
                staticRect: staticRect, staticScale: staticScale, underlay: underlay,
                isApproximate: isApproximate))
        }

        /// Second stage: the low-resolution whole-paper static scene, shown outside the
        /// static textures' area after a zoom-out. Nil when nothing changed (no textures,
        /// another session, or they already cover the paper).
        func prepareUnderlay(_ preview: WatchSelectionPreview, key nextKey: CacheKey,
                             viewport nextViewport: SelectionViewport?) -> ScreenFrame? {
            guard sessionID == preview.sessionID, let key, Self.sameScene(key, nextKey), viewport == nextViewport,
                  underlay == nil, foreground != nil, let staticDocument else { return nil }
            let paper = CGRect(origin: .zero, size: key.size)
            guard !staticRect.contains(paper.insetBy(dx: 0.5, dy: 0.5)) else { return nil }
            let area = key.size.width * key.size.height
            guard area > 0 else { return nil }
            let scale = min(staticScale, (Self.underlayPixelBudget / area).squareRoot(),
                            2048 / max(key.size.width, key.size.height))
            guard scale.isFinite, scale > 0 else { return nil }
            let wanted = UnderlayKey(document: staticDocument, paper: key.size, scale: scale)
            if underlayKey == wanted, let cachedUnderlay {
                underlay = cachedUnderlay
            } else {
                underlayKey = nil
                cachedUnderlay = nil
                guard let image = WatchBitmapRenderer.render(document: staticDocument, size: key.size, scale: scale),
                      !Task.isCancelled else { return nil }
                underlayKey = wanted
                cachedUnderlay = image
                underlay = image
            }
            return render(preview, key: key, viewport: viewport, allowReplay: false)
        }

        /// Steps of √2, like the zoom tiles, so the static textures share their pixel grid.
        private static func ladderScale(_ scale: CGFloat) -> CGFloat {
            pow(2, (log2(scale) * 2).rounded() / 2)
        }

        private func prepare(_ preview: WatchSelectionPreview, key: CacheKey, viewport: SelectionViewport?) {
            let visible = preview.document.layers.filter { $0.isVisible && $0.opacity > 0 }
            guard let index = visible.firstIndex(where: { $0.id == preview.layerID }) else {
                refusal = "layer hidden"; return
            }
            let layer = visible[index]
            guard let start = layer.strokes.firstIndex(where: { preview.selectedIDs.contains($0.id) }),
                  let end = layer.strokes.lastIndex(where: { preview.selectedIDs.contains($0.id) }) else {
                refusal = "no strokes"; return
            }
            func independent(_ stroke: Stroke) -> Bool {
                !stroke.locksTransparency && stroke.style.instrument != .eraser &&
                    ((stroke.style.instrument != .marker && stroke.style.instrument != .watercolor) ||
                     stroke.style.blendingMode == .normal)
            }
            // Exact: one contiguous run, nothing after it reading the moved ink. Otherwise
            // the textures still move (an invisible or stale preview is worse than an
            // approximate one); the committed render is exact. Unselected strokes between
            // selected ones go above them, later dependent blends composite normally.
            let contiguous = layer.strokes[start...end].allSatisfy { preview.selectedIDs.contains($0.id) }
            let dependent = layer.strokes[start...].first { !independent($0) }
            isApproximate = !contiguous || dependent != nil
            let reason = !contiguous ? "gaps" : dependent.map { $0.locksTransparency ? "alpha lock"
                : $0.style.instrument == .eraser ? "eraser" : "blend" } ?? ""
            let selected = layer.strokes.filter { preview.selectedIDs.contains($0.id) }
            let below = Array(layer.strokes[..<start])
            let above = layer.strokes[(start + 1)...].filter { !preview.selectedIDs.contains($0.id) }
            var extent = preview.bounds
            for stroke in selected {
                guard !Task.isCancelled else { refusal = "cancelled"; return }
                guard let geometry = try? StrokeGeometry(stroke) else { refusal = "geometry"; return }
                extent = extent.union(geometry.bounds)
            }
            guard !extent.isNull, !extent.isEmpty, extent.width.isFinite, extent.height.isFinite,
                  key.size.width > 0, key.size.height > 0 else { refusal = "empty"; return }
            let paper = CGRect(origin: .zero, size: key.size)

            // Resolutions and the static area.
            let scale: CGFloat
            var area = paper
            var fixedScale: CGFloat
            if let viewport, viewport.scale.isFinite, viewport.scale > 0 {
                scale = min(viewport.scale, (Self.foregroundPixelBudget / (extent.width * extent.height)).squareRoot(),
                            4096 / max(extent.width, extent.height))
                let view = viewport.rect.intersection(paper)
                if !view.isNull, !view.isEmpty { area = view }
                fixedScale = Self.ladderScale(viewport.scale)
                while fixedScale > 0.125, area.width * area.height * fixedScale * fixedScale > Self.staticPixelBudget {
                    fixedScale = Self.ladderScale(fixedScale / 2.squareRoot())
                }
            } else {
                // Interaction needs a screen-sized bitmap, not export/zoom resolution.
                // Cap each retained image at roughly 1 MiB in 8-bit RGBA.
                let largestArea = max(extent.width * extent.height, key.size.width * key.size.height)
                let longestSide = max(max(extent.width, extent.height), max(key.size.width, key.size.height))
                scale = min(key.scale, 2, sqrt(262_144 / largestArea), 2048 / longestSide)
                fixedScale = scale
            }
            guard scale.isFinite, scale > 0, fixedScale.isFinite, fixedScale > 0 else { refusal = "scale"; return }
            // Whole pixels of `fixedScale` from the paper's corner: the zoom tiles' grid.
            let paperPixels = CGRect(x: 0, y: 0, width: ceil(key.size.width * fixedScale),
                                     height: ceil(key.size.height * fixedScale))
            let fixedPixels = area.applying(CGAffineTransform(scaleX: fixedScale, y: fixedScale)).integral
                .intersection(paperPixels)
            guard !fixedPixels.isNull, !fixedPixels.isEmpty else { refusal = "empty"; return }
            let fixedRect = fixedPixels.applying(CGAffineTransform(scaleX: 1 / fixedScale, y: 1 / fixedScale))

            // Keep float buffers only during preparation; upload compact textures.
            func compact(_ image: CGImage?) -> CGImage? {
                guard let image, let context = makeDisplayContext(width: image.width, height: image.height) else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return context.makeImage()
            }

            // The moving selection; reused while only the view moves.
            let nextForegroundKey = ForegroundKey(strokes: selected, scale: scale)
            if foregroundKey != nextForegroundKey || cachedForeground == nil {
                foregroundKey = nil
                cachedForeground = nil
                let pixels = extent.insetBy(dx: -2 / scale, dy: -2 / scale)
                    .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
                let region = pixels.applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                let local = selected.map { source in
                    var stroke = source
                    stroke.transform = StrokeTransform(source.transform.affine.concatenating(
                        CGAffineTransform(translationX: -region.minX, y: -region.minY)))
                    return stroke
                }
                guard let image = compact(layerThumbnail(strokes: local, size: region.size, scale: scale)) else {
                    refusal = "foreground"; return
                }
                foregroundKey = nextForegroundKey
                cachedForeground = image
                cachedRegion = region
            }

            // Only the selected objects change during successive moves. Reuse
            // the expensive static artwork even when the document revision and
            // selection session advance after committing a transform.
            var staticDocument = preview.document
            if let layerIndex = staticDocument.layers.firstIndex(where: { $0.id == preview.layerID }) {
                staticDocument.layers[layerIndex].strokes.removeAll { preview.selectedIDs.contains($0.id) }
            }
            let nextStaticKey = StaticSelectionKey(document: staticDocument, layerID: preview.layerID,
                insertionIndex: start, paper: key.size, rect: fixedRect, scale: fixedScale)
            if staticKey != nextStaticKey || staticBackground == nil {
                // Drop the old textures before allocating a different static scene.
                staticKey = nil
                staticBackground = nil
                staticBelow = nil
                staticAbove = nil
                staticUpper = nil
                let isRegion = fixedRect != paper
                func ink(_ strokes: [Stroke]) -> CGImage? {
                    compact(renderInk(strokes: strokes, size: fixedRect.size, scale: fixedScale,
                                      origin: fixedRect.origin, cullsOutside: isRegion)?.image)
                }
                var lowerImage: CGImage?
                if !below.isEmpty {
                    guard let image = ink(below) else { refusal = "below"; return }
                    lowerImage = image
                }
                var aboveImage: CGImage?
                if !above.isEmpty {
                    guard let image = ink(above) else { refusal = "above"; return }
                    aboveImage = image
                }
                var lower = preview.document
                lower.layers = Array(visible[..<index])
                guard let backgroundImage = WatchBitmapRenderer.render(document: lower, size: fixedRect.size,
                    scale: fixedScale, origin: fixedRect.origin, isRegion: isRegion, paper: key.size) else {
                    refusal = "background"; return
                }
                var upper: CGImage?
                if index + 1 < visible.count {
                    var document = preview.document
                    document.layers = Array(visible[(index + 1)...])
                    document.backgroundIsVisible = false
                    guard let image = WatchBitmapRenderer.render(document: document, size: fixedRect.size,
                        scale: fixedScale, origin: fixedRect.origin, isRegion: isRegion, paper: key.size) else {
                        refusal = "upper"; return
                    }
                    upper = image
                }
                guard !Task.isCancelled else { refusal = "cancelled"; return }
                staticKey = nextStaticKey
                staticBackground = backgroundImage
                staticBelow = lowerImage
                staticAbove = aboveImage
                staticUpper = upper
            }
            self.staticDocument = staticDocument
            self.region = cachedRegion
            self.foreground = cachedForeground
            self.foregroundScale = scale
            self.background = staticBackground
            self.layerBelow = staticBelow
            self.layerAbove = staticAbove
            self.upperLayers = staticUpper
            self.staticRect = fixedRect
            self.staticScale = fixedScale
            self.opacity = layer.opacity
            refusal = "—"
            RenderDiagnostics.setSelectionPath((isApproximate ? "approx(\(reason))" : "exact")
                + String(format: " · sel %.2f× · static %.2f× %.0f×%.0f pt", scale, fixedScale,
                         fixedRect.width, fixedRect.height))
        }
    }
}
