import SwiftUI
import simd
import ImageIO

/// A dedicated actor serializes scratch-buffer and incremental layer-cache access.
actor WatchFillWorker {
    private var layers = WatchBitmapRenderer.LayerCache()
    private var previousLocks: [Bool] = []
    private let workspace = WatchBitmapRenderer.FillWorkspace()

    func fill(layer: CanvasLayer, size: CGSize, point: CGPoint, style: PencilStyle) -> Stroke? {
        guard !Task.isCancelled, layer.isVisible, style.effectiveOpacity > 0 else { return nil }
        let locks = layer.strokes.map(\.locksTransparency)
        // This flag is separate from geometryRevision. A change to earlier
        // clipping semantics invalidates the incremental prefix as well.
        if !locks.starts(with: previousLocks) { layers = WatchBitmapRenderer.LayerCache() }
        previousLocks = locks
        let start = ProcessInfo.processInfo.systemUptime
        guard let image = WatchBitmapRenderer.fillImage(layer: layer, size: size, cache: layers),
              !Task.isCancelled else { return nil }
        let prepared = ProcessInfo.processInfo.systemUptime
        let result = WatchBitmapRenderer.floodFill(image: image, scale: 2, point: point, style: style, workspace: workspace)
        #if DEBUG
        print("Fill: layer \((prepared - start) * 1000) ms, region \((ProcessInfo.processInfo.systemUptime - prepared) * 1000) ms, rectangles \(result?.fillRects?.count ?? 0)")
        #endif
        return result
    }
}
