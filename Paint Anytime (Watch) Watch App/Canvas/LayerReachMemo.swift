import CoreGraphics

/// Canvas bounds each visible layer may draw in, kept per document revision. The
/// viewport region asks on every pan frame how many layers hold ink inside it; the
/// answer needs every stroke's samples, which change only with the document.
@MainActor
final class LayerReachMemo {
    private var revision: UInt64?
    private var bounds: [CGRect] = []

    /// Null for layers that are hidden, fully transparent or without visible ink.
    func bounds(for document: CanvasDocument, revision: UInt64) -> [CGRect] {
        if self.revision == revision { return bounds }
        bounds = document.layers.map { layer in
            guard layer.isVisible, layer.opacity > 0 else { return .null }
            return layer.strokes.reduce(CGRect.null) { $0.union(WatchBitmapRenderer.reach(of: $1)) }
        }
        self.revision = revision
        return bounds
    }
}
