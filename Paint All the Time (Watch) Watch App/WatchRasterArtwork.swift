import SwiftUI
import Combine

/// Present a fully materialized Core Graphics bitmap, using the same brush
/// geometry as export without SwiftUI's Canvas/ImageRenderer preparation path.
struct WatchRasterArtwork: View {
    var document: CanvasDocument? = nil
    var selectedLayerID: UUID? = nil
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
            RasterFrame(document: document, selectedLayerID: selectedLayerID, strokes: strokes, activeStroke: activeStroke,
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
        let document: CanvasDocument?
        let selectedLayerID: UUID?
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
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(frames.frame != nil)")
            Group {
                if let frame = frames.frame {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: frame.background, scale: key.scale)
                            .resizable()
                            .frame(width: key.size.width, height: key.size.height)
                        ForEach(frame.tiles) { tile in
                            Image(decorative: tile.image, scale: key.scale)
                                .resizable()
                                .frame(width: tile.rect.width, height: tile.rect.height)
                                .offset(x: tile.rect.minX, y: tile.rect.minY)
                        }
                    }
                    .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
                    .clipped()
                } else {
                    Color.white
                }
            }
            .task(id: Request(key: key, activeStrokeRevision: activeStrokeRevision)) { @MainActor in
                frames.submit(document: document, selectedLayerID: selectedLayerID, strokes: strokes, activeStroke: activeStroke,
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
    @Published private(set) var frame: WatchBitmapRenderer.ScreenFrame?
    private let renderer = WatchArtworkRenderer()
    private struct Job {
        let document: CanvasDocument?
        let selectedLayerID: UUID?
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let key: WatchBitmapRenderer.CacheKey
        let activeStrokeID: UInt64
    }
    private var pending: Job?
    private var latest: Job?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func submit(document: CanvasDocument?, selectedLayerID: UUID?, strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64) {
        let job = Job(document: document, selectedLayerID: selectedLayerID, strokes: strokes, activeStroke: activeStroke, key: key, activeStrokeID: activeStrokeID)
        pending = job
        latest = job
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.pending, !Task.isCancelled {
                self.pending = nil
                let next: WatchBitmapRenderer.ScreenFrame?
                if let document = job.document {
                    next = await self.renderer.layeredFrame(document: document, activeStroke: job.activeStroke,
                        selectedLayerID: job.selectedLayerID, key: job.key)
                } else {
                    next = await self.renderer.screenFrame(strokes: job.strokes, activeStroke: job.activeStroke,
                                                     key: job.key, activeStrokeID: job.activeStrokeID)
                }
                guard !Task.isCancelled, self.generation == token else { return }
                // An older prefix of this gesture is useful. An old document,
                // cancelled gesture or viewport must never replace the new one.
                if let latest = self.latest, latest.key == job.key,
                   latest.activeStrokeID == job.activeStrokeID,
                   latest.activeStroke?.id == job.activeStroke?.id, let next {
                    self.frame = next
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
