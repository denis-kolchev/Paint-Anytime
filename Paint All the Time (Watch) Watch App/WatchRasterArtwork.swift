import SwiftUI

/// Present a fully materialized Core Graphics bitmap, using the same brush
/// geometry as export without SwiftUI's Canvas/ImageRenderer preparation path.
struct WatchRasterArtwork: View {
    let strokes: [Stroke]
    let zoom: Double
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = TutorialDebug.trace("raster.body")
        GeometryReader { geometry in
            let _ = TutorialDebug.trace("raster.geometry", "size=\(geometry.size)")
            RasterFrame(strokes: strokes, size: geometry.size,
                        scale: displayScale * max(1, zoom))
        }
    }

    private struct RasterFrame: View {
        let strokes: [Stroke]
        let size: CGSize
        let scale: CGFloat

        @State private var image: CGImage?

        // Equality includes all stroke data (including undo and style edits).
        // A coarse hash avoids hashing every point on each drag update.
        private struct Request: Hashable {
            let strokes: [Stroke]
            let size: CGSize
            let scale: CGFloat

            static func == (lhs: Self, rhs: Self) -> Bool {
                TutorialDebug.measure("raster.request.equal") {
                    lhs.strokes == rhs.strokes && lhs.size == rhs.size && lhs.scale == rhs.scale
                }
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(strokes.count)
                hasher.combine(size.width)
                hasher.combine(size.height)
                hasher.combine(scale)
            }
        }

        var body: some View {
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(image != nil)")
            Group {
                if !strokes.isEmpty, let image {
                    Image(decorative: image, scale: scale)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                } else {
                    Color.white
                }
            }
            .task(id: Request(strokes: strokes, size: size, scale: scale)) { @MainActor in
                // Do not synchronously ask SwiftUI to render another view from body.
                // New artwork cancels pending work; keep the previous frame meanwhile.
                TutorialDebug.trace("raster.task.beforeYield")
                await Task.yield()
                TutorialDebug.trace("raster.task.afterYield", "cancelled=\(Task.isCancelled)")
                guard !Task.isCancelled else { return }
                if strokes.isEmpty {
                    image = nil
                    return
                }
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
            guard size.width > 0, size.height > 0 else { return nil }
            TutorialDebug.trace("bitmap.render.enter", "strokes=\(strokes.count) size=\(size)")
            defer { TutorialDebug.trace("bitmap.render.exit") }
            let image = TutorialDebug.measure("bitmap.renderer") {
                WatchBitmapRenderer.render(strokes: strokes, size: size, scale: scale)
            }
            return image
        }
    }
}
