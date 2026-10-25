import SwiftUI
import Combine

/// Present a fully materialized Core Graphics bitmap, using the same brush
/// geometry as export without SwiftUI's Canvas/ImageRenderer preparation path.
struct WatchRasterArtwork: View {
    var document: CanvasDocument? = nil
    var selectedLayerID: UUID? = nil
    var selectionPreview: WatchSelectionPreview? = nil
    var selectionSeed: WatchSelectionPreview? = nil
    let strokes: [Stroke]
    let activeStroke: Stroke?
    let documentID: ObjectIdentifier
    let documentRevision: UInt64
    var clearDocumentRevision: UInt64? = nil
    let activeStrokeRevision: UInt64
    let activeStrokeID: UInt64
    var onFramePrepared: (Bool) -> Void = { _ in }
    let zoom: Double
    @State private var rasterZoom: Double = 1
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let _ = TutorialDebug.trace("raster.body")
        GeometryReader { geometry in
            let _ = TutorialDebug.trace("raster.geometry", "size=\(geometry.size)")
            RasterFrame(clearDocumentRevision: clearDocumentRevision, onFramePrepared: onFramePrepared, document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, selectionSeed: selectionSeed, strokes: strokes, activeStroke: activeStroke,
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
        var clearDocumentRevision: UInt64?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var clearOpacity = 1.0
        var onFramePrepared: (Bool) -> Void
        let document: CanvasDocument?
        let selectedLayerID: UUID?
        let selectionPreview: WatchSelectionPreview?
        let selectionSeed: WatchSelectionPreview?
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let activeStrokeRevision: UInt64
        let activeStrokeID: UInt64
        let key: WatchBitmapRenderer.CacheKey

        @StateObject private var frames = CanvasFrameQueue()
        @State private var finishedTransform: CGAffineTransform?

        private var displayFrame: WatchBitmapRenderer.ScreenFrame? {
            if let preview = selectionPreview, let prepared = frames.preparedFrame,
               prepared.selection?.sessionID == preview.sessionID, prepared.selection?.key == key {
                return prepared
            }
            return frames.frame
        }

        private var hasSelectionTexture: Bool {
            guard let texture = displayFrame?.selection, let selectionPreview else { return false }
            return texture.sessionID == selectionPreview.sessionID && texture.key == key
        }

        private func displayedTransform(_ texture: WatchBitmapRenderer.SelectionTexture) -> CGAffineTransform {
            if let selectionPreview, selectionPreview.sessionID == texture.sessionID {
                return selectionPreview.transform
            }
            // Hold the last interactive frame until the committed/cancelled frame
            // is ready, rather than snapping back while it is being rendered.
            return finishedTransform ?? texture.transform
        }

        private func staticTexture(_ image: CGImage) -> some View {
            Image(decorative: image, scale: key.scale)
                .resizable()
                .frame(width: key.size.width, height: key.size.height)
        }

        // No stroke arrays or point comparisons in task identity.
        private struct Request: Equatable {
            let key: WatchBitmapRenderer.CacheKey
            let activeStrokeRevision: UInt64
            let sessionID: UUID?
            let transform: CGAffineTransform?
        }

        private func artwork(_ frame: WatchBitmapRenderer.ScreenFrame) -> some View {
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.background, scale: key.scale)
                    .resizable()
                    .frame(width: key.size.width, height: key.size.height)
                if let texture = frame.selection {
                    ZStack(alignment: .topLeading) {
                        if let image = texture.layerBelow {
                            staticTexture(image)
                        }
                        Image(decorative: texture.image, scale: texture.key.scale)
                            .resizable()
                            .frame(width: texture.rect.width, height: texture.rect.height)
                            .offset(x: texture.rect.minX, y: texture.rect.minY)
                            .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
                            .transformEffect(displayedTransform(texture))
                        if let image = texture.layerAbove {
                            staticTexture(image)
                        }
                    }
                    .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
                    .clipped()
                    .compositingGroup()
                    .opacity(Double(texture.opacity))
                    if let image = texture.upperLayers {
                        staticTexture(image)
                    }
                }
                ForEach(frame.tiles) { tile in
                    Image(decorative: tile.image, scale: key.scale)
                        .resizable()
                        .frame(width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            .frame(width: key.size.width, height: key.size.height, alignment: .topLeading)
            .clipped()
        }

        var body: some View {
            let _ = TutorialDebug.trace("raster.frame.body", "strokes=\(strokes.count) imageReady=\(frames.frame != nil)")
            Group {
                if let frame = displayFrame {
                    artwork(frame)
                } else {
                    Color.white
                }
            }
            .task(id: Request(key: key, activeStrokeRevision: activeStrokeRevision, sessionID: selectionPreview?.sessionID, transform: hasSelectionTexture ? nil : selectionPreview?.transform)) { @MainActor in
                if hasSelectionTexture { return }
                frames.submit(document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, strokes: strokes, activeStroke: activeStroke,
                              key: key, activeStrokeID: activeStrokeID,
                              animatesClear: activeStroke == nil && key.documentRevision == clearDocumentRevision)
            }
            .task(id: Request(key: key, activeStrokeRevision: 0, sessionID: selectionSeed?.sessionID, transform: nil)) {
                await frames.prepareSelection(selectionSeed, key: key)
            }
            .onChange(of: selectionPreview?.transform) { old, new in
                if new == nil, let old {
                    finishedTransform = old
                }
            }
            .onChange(of: selectionPreview?.sessionID) { old, new in
                if new == nil, let old {
                    frames.holdPreparedSelection(sessionID: old)
                }
            }
            .transaction { $0.animation = nil }
            .overlay {
                if let transition = frames.clearTransition {
                    artwork(transition.frame)
                        .compositingGroup()
                        .opacity(clearOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .task(id: frames.clearTransition?.id) {
                guard let transition = frames.clearTransition else { return }
                clearOpacity = 1
                await Task.yield()
                guard !Task.isCancelled else { return }
                let duration = reduceMotion ? 0.15 : 0.3
                withAnimation(.easeInOut(duration: duration)) { clearOpacity = 0 }
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                if frames.clearTransition?.id == transition.id { frames.clearTransition = nil }
            }
            .onChange(of: frames.preparedResult) { _, result in
                guard let result, result.key == key else { return }
                onFramePrepared(result.succeeded)
            }
            .onDisappear { frames.stop() }
        }

    }
}

/// Finish the in-flight frame, replacing only the pending request. Continuous
/// input therefore cannot starve publication by cancelling every render.
@MainActor
private final class CanvasFrameQueue: ObservableObject {
    struct ClearTransition {
        let id = UUID()
        let frame: WatchBitmapRenderer.ScreenFrame
    }
    @Published var clearTransition: ClearTransition?
    struct PreparedResult: Equatable {
        let key: WatchBitmapRenderer.CacheKey
        let succeeded: Bool
    }
    @Published private(set) var preparedResult: PreparedResult?
    @Published private(set) var frame: WatchBitmapRenderer.ScreenFrame?
    @Published private(set) var preparedFrame: WatchBitmapRenderer.ScreenFrame?
    private let renderer = WatchArtworkRenderer()
    private var preparationID = UUID()

    func prepareSelection(_ seed: WatchSelectionPreview?, key: WatchBitmapRenderer.CacheKey) async {
        let token = UUID()
        preparationID = token
        // Keep the previous interactive texture until its committed frame arrives.
        // A new seed is published as soon as the finger is released, and clearing
        // here could discard that texture before the view has a chance to hold it.
        guard let seed else { return }
        let next = await renderer.prepareSelectionFrame(seed, key: key)
        guard !Task.isCancelled, preparationID == token, next?.selection != nil else { return }
        preparedFrame = next
    }

    func holdPreparedSelection(sessionID: UUID) {
        // Invalidate outstanding preview jobs so they cannot overwrite the held
        // final transform while the committed document is being rendered.
        if latest?.selectionPreview?.sessionID == sessionID {
            latest = nil
            pending = nil
        }
        if let preparedFrame, preparedFrame.selection?.sessionID == sessionID {
            frame = preparedFrame
        }
    }

    private struct Job {
        let document: CanvasDocument?
        let selectedLayerID: UUID?
        let selectionPreview: WatchSelectionPreview?
        let strokes: [Stroke]
        let activeStroke: Stroke?
        let key: WatchBitmapRenderer.CacheKey
        let activeStrokeID: UInt64
        let animatesClear: Bool
    }
    private var pending: Job?
    private var latest: Job?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func submit(document: CanvasDocument?, selectedLayerID: UUID?, selectionPreview: WatchSelectionPreview?, strokes: [Stroke], activeStroke: Stroke?, key: WatchBitmapRenderer.CacheKey,
                activeStrokeID: UInt64, animatesClear: Bool = false) {
        if !animatesClear { clearTransition = nil }
        let job = Job(document: document, selectedLayerID: selectedLayerID, selectionPreview: selectionPreview, strokes: strokes, activeStroke: activeStroke, key: key, activeStrokeID: activeStrokeID, animatesClear: animatesClear)
        pending = job
        latest = job
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            while let job = self.pending, !Task.isCancelled {
                self.pending = nil
                let next: WatchBitmapRenderer.ScreenFrame?
                if let preview = job.selectionPreview {
                    next = await self.renderer.selectionFrame(preview, key: job.key)
                } else if let document = job.document {
                    next = await self.renderer.layeredFrame(document: document, activeStroke: job.activeStroke,
                        selectedLayerID: job.selectedLayerID, key: job.key)
                } else {
                    next = await self.renderer.screenFrame(strokes: job.strokes, activeStroke: job.activeStroke,
                                                     key: job.key, activeStrokeID: job.activeStrokeID)
                }
                guard !Task.isCancelled, self.generation == token else { return }
                // An older prefix of this gesture is useful. An old document,
                // cancelled gesture or viewport must never replace the new one.
                if let latest = self.latest,
                   ((latest.key == job.key && latest.selectionPreview?.sessionID == job.selectionPreview?.sessionID) || Self.sameSelectionDrag(latest, job)),
                   latest.activeStrokeID == job.activeStrokeID,
                   latest.activeStroke?.id == job.activeStroke?.id, let next {
                    if job.animatesClear, self.preparedResult?.key.documentRevision != job.key.documentRevision, let previous = self.frame {
                        self.clearTransition = ClearTransition(frame: previous)
                    }
                    self.frame = next
                    self.preparedResult = PreparedResult(key: job.key, succeeded: true)
                    if let texture = next.selection, let pending = self.pending,
                       pending.key == texture.key,
                       pending.selectionPreview?.sessionID == texture.sessionID {
                        self.pending = nil
                    }
                } else if next == nil, self.latest?.key == job.key {
                    self.preparedResult = PreparedResult(key: job.key, succeeded: false)
                }
            }
            if self.generation == token { self.worker = nil }
        }
    }

    private static func sameSelectionDrag(_ latest: Job, _ rendered: Job) -> Bool {
        // A slower frame from the current drag is still useful while the finger
        // moves. Never publish it after commit, cancellation, or another drag.
        latest.selectionPreview != nil && latest.selectionPreview?.sessionID == rendered.selectionPreview?.sessionID
            && latest.key.documentID == rendered.key.documentID
            && latest.key.size == rendered.key.size && latest.key.scale == rendered.key.scale
    }

    func stop() {
        generation &+= 1
        preparationID = UUID()
        preparedFrame = nil
        worker?.cancel()
        worker = nil
        pending = nil
        latest = nil
    }
}
