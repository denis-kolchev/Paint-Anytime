import SwiftUI

@main
struct LayerRenderCheck {
    @MainActor static func main() {
        let point = PointerSample(position: SIMD2<Float>(40, 40), pressure: 1, timestamp: 0)
        var style = PencilStyle()
        style.width = 20
        let ink = Stroke(points: [point], style: style)
        func assertSame(_ cached: CGImage?, _ full: CGImage?, _ message: String) {
            guard let cached, let full else { fatalError("Missing image: \(message)") }
            precondition(cached.width == full.width && cached.height == full.height)
            let lhs = cached.dataProvider!.data! as Data
            let rhs = full.dataProvider!.data! as Data
            precondition(lhs.count == rhs.count)
            precondition(zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, message)
        }
        for instrument in DrawingInstrument.allCases where instrument != .fill {
            let cache = WatchBitmapRenderer.LayerCache()
            var document = CanvasDocument(strokes: [ink])
            let size = CGSize(width: 100, height: 100)
            _ = WatchBitmapRenderer.render(document: document, size: size, scale: 2, cache: cache)
            var brush = PencilStyle.initial(for: instrument)
            brush.width = 16
            brush.opacity = 0.5
            for offset: Float in [0, 4, 8] {
                let end = PointerSample(position: SIMD2<Float>(65, 45 + offset), pressure: 0.7, timestamp: 1)
                document.layers[0].strokes.append(Stroke(points: [point, end], style: brush))
                assertSame(WatchBitmapRenderer.render(document: document, size: size, scale: 2, cache: cache),
                    WatchBitmapRenderer.render(document: document, size: size, scale: 2),
                    "Incremental layer must match replay for \(instrument)")
            }
            precondition(cache.replayedStrokeCount == 4, "Only new strokes should be rasterized")
        }
        // Layer caching must match a fresh render while avoiding historical replay.
        do {
            let layers = WatchBitmapRenderer.LayerCache()
            var document = CanvasDocument(strokes: [ink])
            document.layers.append(CanvasLayer(strokes: [ink]))
            document.layers.append(CanvasLayer(strokes: [ink]))
            document.layers[0].opacity = 0.4
            document.layers[1].opacity = 0.6
            document.layers[2].opacity = 0.3
            let selected = document.layers[1].id
            let size = CGSize(width: 100, height: 100)
            func check(_ live: Stroke? = nil, scale: CGFloat = 2) {
                assertSame(WatchBitmapRenderer.render(document: document, size: size, scale: scale,
                    activeStroke: live, selectedLayerID: selected, cache: layers),
                    WatchBitmapRenderer.render(document: document, size: size, scale: scale,
                    activeStroke: live, selectedLayerID: selected), "Layer cache must match full replay")
            }
            check(ink)
            let initialReplay = layers.replayedStrokeCount
            let initialComposite = layers.compositeBuildCount
            check(ink)
            precondition(layers.replayedStrokeCount == initialReplay, "Live frames must not replay history")
            precondition(layers.compositeBuildCount == initialComposite, "Unchanged lower layers must reuse composition")
            var eraserStyle = PencilStyle.initial(for: .eraser)
            eraserStyle.width = 10
            let eraser = Stroke(points: [point], style: eraserStyle)
            document.layers[1].strokes.append(eraser)
            check(ink)
            precondition(layers.replayedStrokeCount == initialReplay + 1, "Commit must rasterize only the appended stroke")
            precondition(layers.compositeBuildCount == initialComposite, "Active-layer edits must preserve lower composition")
            check() // Ending/cancelling the live stroke caches the complete frame.
            let idleBuilds = layers.compositeBuildCount
            check()
            precondition(layers.compositeBuildCount == idleBuilds, "Idle frames must reuse the complete composition")
            document.layers[1].strokes.removeLast()
            check(eraser) // Undo and live erasing remain isolated to their layer.
            document.layers[0].opacity = 0.7
            check(ink)
            document.layers[0].isVisible = false
            check(ink)
            document.layers.swapAt(0, 2)
            check(ink)
            document.backgroundIsVisible = false
            check(ink)
            document.layers[1].strokes = [eraser]
            check(ink)
            check(ink, scale: 1)
            document.layers.removeAll()
            check()
            print("PASS: layer append, composite reuse, undo, visibility, opacity, order, background and scale")
        }
    }
}
