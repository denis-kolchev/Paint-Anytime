import SwiftUI

@main
struct HistoryFrameChecks {
    @MainActor static func main() async {
        let renderer = WatchArtworkRenderer()
        let identity = NSObject()
        func key(_ revision: UInt64, scale: CGFloat = 2) -> WatchBitmapRenderer.CacheKey {
            .init(documentID: ObjectIdentifier(identity), documentRevision: revision,
                  size: CGSize(width: 100, height: 100), scale: scale)
        }
        func stroke(_ x: Float) -> Stroke {
            Stroke(points: [PointerSample(position: SIMD2(x, 40), pressure: 1, timestamp: 0)], style: PencilStyle())
        }
        let first = stroke(20), second = stroke(50)
        let before = await renderer.screenFrame(strokes: [first], activeStroke: nil, key: key(1), activeStrokeID: 0)!
        let after = await renderer.screenFrame(strokes: [first, second], activeStroke: nil, key: key(2), activeStrokeID: 0)!
        let undo = await renderer.screenFrame(strokes: [first], activeStroke: nil, key: key(3), activeStrokeID: 0)!
        let redo = await renderer.screenFrame(strokes: [first, second], activeStroke: nil, key: key(4), activeStrokeID: 0)!
        precondition(before.background === undo.background && after.background === redo.background,
                     "Undo and Redo must reuse the actual prepared images")
        let hits = await renderer.historyFrameHits
        precondition(hits == 2)
        // Drawing after Undo must use the restored document, not the renderer's
        // newer incremental state that was bypassed by a display-cache hit.
        _ = await renderer.screenFrame(strokes: [first], activeStroke: nil, key: key(5), activeStrokeID: 0)
        let branch = await renderer.screenFrame(strokes: [first, stroke(80)], activeStroke: nil, key: key(6), activeStrokeID: 0)!
        let expected = WatchBitmapRenderer.render(strokes: [first, stroke(80)], size: CGSize(width: 100, height: 100), scale: 2)!
        precondition(CFEqual(branch.background.dataProvider!.data, expected.dataProvider!.data), "Branch after Undo must render correctly")

        var document = CanvasDocument(strokes: [first, second])
        let original = await renderer.layeredFrame(document: document, activeStroke: nil, selectedLayerID: nil, key: key(7))!
        document.layers[0].opacity = 0.4
        let faded = await renderer.layeredFrame(document: document, activeStroke: nil, selectedLayerID: nil, key: key(8))!
        precondition(original.background !== faded.background)
        document.layers[0].opacity = 1
        let restored = await renderer.layeredFrame(document: document, activeStroke: nil, selectedLayerID: nil, key: key(9))!
        precondition(original.background === restored.background, "Layer property Undo must recall its frame")
        document.backgroundIsVisible = false
        let transparent = await renderer.layeredFrame(document: document, activeStroke: nil, selectedLayerID: nil, key: key(10))!
        precondition(transparent.background !== original.background, "Background changes must invalidate history identity")
        let resized = await renderer.layeredFrame(document: document, activeStroke: nil, selectedLayerID: nil, key: key(11, scale: 3))!
        precondition(resized.background.width == 300, "Old resolution must never be recalled")
        for index in 0..<20 {
            _ = await renderer.screenFrame(strokes: [stroke(Float(index))], activeStroke: nil,
                key: key(UInt64(20 + index), scale: 4), activeStrokeID: 0)
            let bytes = await renderer.historyFrameBytes
            precondition(bytes <= 6 * 1024 * 1024, "History cache must stay within budget")
        }
        print("PASS: Undo/Redo image reuse, branching, layer/background invalidation, resolution and memory budget")
    }
}
