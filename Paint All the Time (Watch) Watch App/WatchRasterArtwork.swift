import SwiftUI
import Combine

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

        @StateObject private var frames = CanvasFrameQueue()

        // No stroke arrays or point comparisons in task identity.
        private struct Request: Equatable {
            let key: WatchBitmapRenderer.CacheKey
            let activeStrokeRevision: UInt64
        }

        var body: some View {
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(frames.image != nil)")
            Group {
                if let image = frames.image {
                    Image(decorative: image, scale: key.scale)
                        .resizable()
                        .frame(width: key.size.width, height: key.size.height)
                } else {
                    Color.white
                }
            }
            .task(id: Request(key: key, activeStrokeRevision: activeStrokeRevision)) { @MainActor in
                frames.submit(strokes: strokes, activeStroke: activeStroke,
                              key: key, activeStrokeID: activeStrokeID)
            }
            .onDisappear { frames.stop() }
        }

    }
}

/// Finish the in-flight frame, replacing only the pending request. Continuous
/// input therefore cannot starve publication by cancelling every render.
@MainActor
private final class CanvasFrameQueue: ObservableObject {
    @Published private(set) var image: CGImage?
    private let renderer = WatchArtworkRenderer()
    private struct Job {
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let key: WatchBitmapRenderer.CacheKey
        let activeStrokeID: UInt64
    }
    private var pending: Job?
    private var latest: Job?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func submit(strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64) {
        let job = Job(strokes: strokes, activeStroke: activeStroke, key: key, activeStrokeID: activeStrokeID)
        pending = job
        latest = job
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.pending, !Task.isCancelled {
                self.pending = nil
                let next = await self.renderer.render(strokes: job.strokes, activeStroke: job.activeStroke,
                                                     key: job.key, activeStrokeID: job.activeStrokeID)
                guard !Task.isCancelled, self.generation == token else { return }
                // An older prefix of this gesture is useful. An old document,
                // cancelled gesture or viewport must never replace the new one.
                if let latest = self.latest, latest.key == job.key,
                   latest.activeStrokeID == job.activeStrokeID,
                   latest.activeStroke?.id == job.activeStroke?.id, let next {
                    self.image = next
                }
            }
            if self.generation == token { self.worker = nil }
        }
    }

    func stop() {
        generation &+= 1
        worker?.cancel()
        worker = nil
        pending = nil
        latest = nil
    }
}
