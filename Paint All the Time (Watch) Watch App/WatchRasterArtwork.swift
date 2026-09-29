import SwiftUI

/// Present a fully materialized Core Graphics bitmap, using the same brush
/// geometry as export without SwiftUI's Canvas/ImageRenderer preparation path.
struct WatchRasterArtwork: View {
    let strokes: [Stroke]
    let activeStroke: Stroke?
    let documentID: ObjectIdentifier
    let documentRevision: UInt64
    let activeStrokeRevision: UInt64
    let activeStrokeID: UInt64
    let zoom: Double
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = TutorialDebug.trace("raster.body")
        GeometryReader { geometry in
            let _ = TutorialDebug.trace("raster.geometry", "size=\(geometry.size)")
            RasterFrame(strokes: strokes, activeStroke: activeStroke,
                        activeStrokeRevision: activeStrokeRevision, activeStrokeID: activeStrokeID,
                        key: WatchBitmapRenderer.CacheKey(documentID: documentID,
                            documentRevision: documentRevision, size: geometry.size,
                            scale: displayScale * max(1, zoom)))
        }
    }

    private struct RasterFrame: View {
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let activeStrokeRevision: UInt64
        let activeStrokeID: UInt64
        let key: WatchBitmapRenderer.CacheKey

        @State private var image: CGImage?
        @State private var cache = WatchBitmapRenderer.Cache()

        // No stroke arrays or point comparisons in task identity.
        private struct Request: Equatable {
            let key: WatchBitmapRenderer.CacheKey
            let activeStrokeRevision: UInt64
        }

        var body: some View {
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(image != nil)")
            Group {
                if let image {
                    Image(decorative: image, scale: key.scale)
                        .resizable()
                        .frame(width: key.size.width, height: key.size.height)
                } else {
                    Color.white
                }
            }
            .task(id: Request(key: key, activeStrokeRevision: activeStrokeRevision)) { @MainActor in
                // Do not synchronously ask SwiftUI to render another view from body.
                // New artwork cancels pending work; keep the previous frame meanwhile.
                TutorialDebug.trace("raster.task.beforeYield")
                await Task.yield()
                TutorialDebug.trace("raster.task.afterYield", "cancelled=\(Task.isCancelled)")
                guard !Task.isCancelled else { return }
                let next = render()
                guard !Task.isCancelled else { return }
                if let next {
                    TutorialDebug.trace("raster.image.beforeWrite")
                    image = next
                    TutorialDebug.trace("raster.image.afterWrite")
                }
            }
        }

        @MainActor
        private func render() -> CGImage? {
            guard key.size.width > 0, key.size.height > 0 else { return nil }
            TutorialDebug.trace("bitmap.render.enter", "strokes=\(strokes.count) size=\(key.size)")
            defer { TutorialDebug.trace("bitmap.render.exit") }
            let image = TutorialDebug.measure("bitmap.renderer") {
                cache.render(strokes: strokes, activeStroke: activeStroke, key: key, activeStrokeID: activeStrokeID)
            }
            return image
        }
    }
}
