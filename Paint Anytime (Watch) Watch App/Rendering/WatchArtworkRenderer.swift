import SwiftUI
import simd
import ImageIO

/// Serial ownership keeps mutable bitmap contexts off the UI actor and prevents
/// overlapping requests from modifying the same incremental cache.
actor WatchArtworkRenderer {
    private let cache = WatchBitmapRenderer.Cache()
    private let layers = WatchBitmapRenderer.LayerCache()
    private let selection = WatchBitmapRenderer.SelectionRenderCache()

    /// Every live renderer (the paper and each zoom tile), so a save short of memory can
    /// make them all drop their layer inks. Each cache budgets as if alone, so together
    /// they can hold most of what the app may use.
    private static let registry = Registry()

    private final class Registry: @unchecked Sendable {
        private struct Weak { weak var renderer: WatchArtworkRenderer? }
        private let lock = NSLock()
        private var entries: [Weak] = []

        func add(_ renderer: WatchArtworkRenderer) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.renderer == nil }
            entries.append(Weak(renderer: renderer))
        }

        var all: [WatchArtworkRenderer] {
            lock.lock(); defer { lock.unlock() }
            return entries.compactMap(\.renderer)
        }
    }

    init() {
        Self.registry.add(self)
        _ = Self.memoryPressure
    }

    /// The system's memory warnings, for every cache of the canvas at once. Until now
    /// only a save released memory; zooming or drawing could reach the limit and the
    /// app was killed without trying. Warning: drop what only saves work later (blur
    /// blocks, compressed and Undo copies). Critical: also every renderer's layer inks;
    /// frames on screen stay and layers replay when next drawn.
    private static let memoryPressure: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let critical = event.contains(.critical)
            BlurSourceCache.shared.removeAll()
            Task {
                for renderer in WatchArtworkRenderer.registry.all {
                    await renderer.releaseForMemoryPressure(critical: critical)
                }
            }
        }
        source.resume()
        return source
    }()

    private func releaseForMemoryPressure(critical: Bool) {
        if critical { layers.releaseInks() } else { layers.releaseSpareCopies() }
        historyFrames.removeAll()
    }

    /// Frees the layer inks of every live renderer, each on its own actor; frames on
    /// screen stay. The canvas replays layers when it next draws.
    static func releaseAllCachedInks() async {
        BlurSourceCache.shared.removeAll()
        for renderer in registry.all { await renderer.releaseCachedInks() }
    }

    private func releaseCachedInks() {
        layers.releaseInks()
    }

    // Revisions advance on Undo/Redo too. Identify the actual artwork using
    // immutable geometry versions, without comparing point arrays or PNG data.
    private struct HistoryKey: Equatable {
        struct StrokeKey: Equatable {
            let id: UUID
            let revision: UUID
            let locksTransparency: Bool
            init(_ stroke: Stroke) {
                id = stroke.id
                revision = stroke.geometryRevision
                locksTransparency = stroke.locksTransparency
            }
        }
        struct LayerKey: Equatable {
            let id: UUID?
            let opacity: Float
            let strokes: [StrokeKey]
        }
        let documentID: ObjectIdentifier
        let size: CGSize
        let scale: CGFloat
        let origin: CGPoint
        let background: SIMD4<Float>
        let layers: [LayerKey]
    }
    private struct HistoryFrame {
        let key: HistoryKey
        let frame: WatchBitmapRenderer.ScreenFrame
        let bytes: Int
    }
    private var historyFrames: [HistoryFrame] = []
    private let historyByteLimit = 6 * 1024 * 1024
    private(set) var historyFrameHits = 0
    var historyFrameBytes: Int { historyFrames.reduce(0) { $0 + $1.bytes } }

    private func historyKey(document: CanvasDocument?, strokes: [Stroke], key: WatchBitmapRenderer.CacheKey) -> HistoryKey {
        let layers: [HistoryKey.LayerKey]
        if let document {
            layers = document.layers.filter { $0.isVisible && $0.opacity > 0 }.map {
                .init(id: $0.id, opacity: $0.opacity, strokes: $0.strokes.map(HistoryKey.StrokeKey.init))
            }
        } else {
            layers = [.init(id: nil, opacity: 1, strokes: strokes.map(HistoryKey.StrokeKey.init))]
        }
        return HistoryKey(documentID: key.documentID, size: key.size, scale: key.scale, origin: key.origin,
            background: document?.effectiveBackgroundColor ?? SIMD4(1, 1, 1, 1), layers: layers)
    }

    /// History stage of a committed frame (Undo/Redo back to a retained frame).
    private func recall(_ state: HistoryKey?) -> WatchBitmapRenderer.ScreenFrame? {
        guard let state else { return nil }
        return RenderDiagnostics.measure(.history) { recalledFrame(state) }
    }

    private func recalledFrame(_ key: HistoryKey) -> WatchBitmapRenderer.ScreenFrame? {
        // Never retain images for another document or raster resolution.
        historyFrames.removeAll {
            $0.key.documentID != key.documentID || $0.key.size != key.size || $0.key.scale != key.scale
                || $0.key.origin != key.origin
        }
        guard let index = historyFrames.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = historyFrames.remove(at: index)
        historyFrames.append(entry)
        historyFrameHits += 1
        return entry.frame
    }

    private func rememberFrame(_ frame: WatchBitmapRenderer.ScreenFrame, key: HistoryKey) {
        // Only complete committed frames belong to history, never live tiles or
        // lasso textures. Keep at most six frames within a strict byte budget.
        guard frame.selection == nil, frame.tiles.isEmpty else { return }
        let bytes = frame.background.bytesPerRow * frame.background.height
        guard bytes <= historyByteLimit else { return }
        historyFrames.removeAll { $0.key == key }
        while !historyFrames.isEmpty && (historyFrames.count >= 6 || historyFrameBytes + bytes > historyByteLimit) {
            historyFrames.removeFirst()
        }
        historyFrames.append(HistoryFrame(key: key, frame: frame, bytes: bytes))
    }

    func prepareSelectionFrame(_ preview: WatchSelectionPreview, key: WatchBitmapRenderer.CacheKey,
                               viewport: WatchBitmapRenderer.SelectionViewport? = nil) -> WatchBitmapRenderer.ScreenFrame? {
        selection.render(preview, key: key, viewport: viewport, allowReplay: false)
    }

    /// The prepared textures plus the low-resolution scene outside their area, or nil
    /// when that is not needed or the textures changed meanwhile.
    func prepareSelectionUnderlay(_ preview: WatchSelectionPreview, key: WatchBitmapRenderer.CacheKey,
                                  viewport: WatchBitmapRenderer.SelectionViewport?) -> WatchBitmapRenderer.ScreenFrame? {
        selection.prepareUnderlay(preview, key: key, viewport: viewport)
    }

    func selectionFrame(_ preview: WatchSelectionPreview, key: WatchBitmapRenderer.CacheKey,
                        viewport: WatchBitmapRenderer.SelectionViewport? = nil) -> WatchBitmapRenderer.ScreenFrame? {
        let started = RenderDiagnostics.begin()
        defer { RenderDiagnostics.workEnded(started) }
        return selection.render(preview, key: key, viewport: viewport)
    }

    func layeredFrame(document: CanvasDocument, activeStroke: Stroke?, selectedLayerID: UUID?,
                      key: WatchBitmapRenderer.CacheKey) -> WatchBitmapRenderer.ScreenFrame? {
        let started = RenderDiagnostics.begin()
        defer { RenderDiagnostics.workEnded(started) }
        guard !Task.isCancelled else { return nil }
        selection.clear()
        // Region tiles skip history frames: each tile has its own renderer, and six frames
        // per tile would multiply. Undo there replays from the layer cache's previous inks.
        let state = activeStroke == nil && !key.isRegion ? historyKey(document: document, strokes: [], key: key) : nil
        if let frame = recall(state) { return frame }
        guard let image = WatchBitmapRenderer.render(document: document, size: key.size, scale: key.scale,
            origin: key.origin, isRegion: key.isRegion, activeStroke: activeStroke, selectedLayerID: selectedLayerID, cache: layers,
            paper: key.paper), !Task.isCancelled else { return nil }
        let frame = WatchBitmapRenderer.ScreenFrame(background: image, tiles: [])
        if let state { rememberFrame(frame, key: state) }
        return frame
    }

    func screenFrame(strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                     activeStrokeID: UInt64) -> WatchBitmapRenderer.ScreenFrame? {
        let started = RenderDiagnostics.begin()
        defer { RenderDiagnostics.workEnded(started) }
        guard !Task.isCancelled else { return nil }
        selection.clear()
        let state = activeStroke == nil ? historyKey(document: nil, strokes: strokes, key: key) : nil
        if let frame = recall(state) { return frame }
        guard let frame = cache.screenFrame(strokes: strokes, activeStroke: activeStroke,
            key: key, activeStrokeID: activeStrokeID), !Task.isCancelled else { return nil }
        if let state { rememberFrame(frame, key: state) }
        return frame
    }


    func render(strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64) -> CGImage? {
        assert(!Thread.isMainThread, "Bitmap rendering must stay off the main thread")
        guard !Task.isCancelled, key.size.width > 0, key.size.height > 0 else { return nil }
        let image = cache.render(strokes: strokes, activeStroke: activeStroke,
                                 key: key, activeStrokeID: activeStrokeID)
        return Task.isCancelled ? nil : image
    }
}
