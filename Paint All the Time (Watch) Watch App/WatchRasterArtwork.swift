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
    @State private var rasterZoom: Double = 1
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = TutorialDebug.trace("raster.body")
        GeometryReader { geometry in
            let _ = TutorialDebug.trace("raster.geometry", "size=\(geometry.size)")
            RasterFrame(strokes: strokes, activeStroke: activeStroke,
                        activeStrokeRevision: activeStrokeRevision, activeStrokeID: activeStrokeID,
                        key: WatchBitmapRenderer.CacheKey(documentID: documentID,
                            documentRevision: documentRevision, size: geometry.size,
                            // Keep the previous resolution until Crown input settles.
                            scale: WatchBitmapRenderer.rasterScale(displayScale: displayScale, zoom: rasterZoom)))
        }
        .task(id: zoom) {
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                rasterZoom = max(1, zoom)
            } catch {
                // A new zoom value restarts the quiet period.
            }
        }
    }

    private struct RasterFrame: View {
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let activeStrokeRevision: UInt64
        let activeStrokeID: UInt64
        let key: WatchBitmapRenderer.CacheKey

        @State private var image: CGImage?
        @State private var renderer = WatchArtworkRenderer()

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
                // Cancellation also follows this task into the renderer actor.
                // Queued obsolete requests are skipped; the last image stays visible.
                let next = await renderer.render(strokes: strokes, activeStroke: activeStroke,
                                                 key: key, activeStrokeID: activeStrokeID)
                guard !Task.isCancelled else { return }
                if let next {
                    TutorialDebug.trace("raster.image.beforeWrite")
                    image = next
                    TutorialDebug.trace("raster.image.afterWrite")
                }
            }
        }

    }
}
