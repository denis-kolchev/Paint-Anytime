import Combine
import Foundation

@MainActor
final class GalleryController: ObservableObject {
    @Published private(set) var drawings: [CanvasExport] = []
    @Published var errorMessage: String?

    /// False until the first listing arrives, so an empty grid is not shown as "No drawings".
    @Published private(set) var hasLoaded = false
    private var loadTask: Task<Void, Never>?

    func reload(in folder: URL? = nil) {
        loadTask?.cancel()
        do { apply(try CanvasExportStore.all(in: folder), folder: folder) }
        catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    /// Lists the folder off the main thread (~80 ms with 90 drawings on watch).
    /// Debug fixtures, when enabled, are still added on the main actor.
    func reloadInBackground(in folder: URL? = nil) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CanvasExportStore.all(in: folder) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let exports): self.apply(exports, folder: folder)
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.hasLoaded = true
            }
        }
    }

    private func apply(_ exports: [CanvasExport], folder: URL?) {
        do {
            var loaded = exports
            if folder == nil {
                // The same switch, bundled fixtures, installation rules and image
                // list as WatchPhotoInbox on iPhone. Only Watch metadata is added.
                let samples = try DebugGallerySamples.images(
                    includingTutorial: RenderDebugSettings.shared.showsTutorialSamples)
                if !samples.isEmpty {
                    loaded += try CanvasExportStore.exports(for: samples, in: DebugGallerySamples.directory())
                }
            }
            // No widget refresh here: saves, deletions, favorites, imports, launch and
            // activation already publish. Doing it on every open cost ~230 ms on the main thread.
            drawings = loaded.sorted { DebugGallerySamples.orderedBefore($0.url, $1.url) }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        hasLoaded = true
        MenuGalleryTransitionDiagnostics.shared.mark("list ready", awaitsFrame: true)
    }

    func delete(_ drawing: CanvasExport, in folder: URL? = nil) -> Bool {
        defer { if folder == nil { WatchPhotoTransfer.shared.publishContext() } }
        do {
            try CanvasExportStore.delete(drawing, in: DebugGallerySamples.contains(drawing.url) ? DebugGallerySamples.directory() : folder)
            Task { await GalleryImageCache.shared.remove(drawing.url) }
            GalleryPreviewStore.shared.remove(drawing.url)
            drawings.removeAll { $0.id == drawing.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setFavorite(_ isFavorite: Bool, for drawing: CanvasExport, in folder: URL? = nil) {
        // The iPhone widgets show the watch's favorites.
        defer { if folder == nil { WatchPhotoTransfer.shared.publishContext() } }
        do {
            try CanvasExportStore.setFavorite(isFavorite, for: drawing, in: DebugGallerySamples.contains(drawing.url) ? DebugGallerySamples.directory() : folder)
            if let index = drawings.firstIndex(where: { $0.id == drawing.id }) {
                drawings[index].isFavorite = isFavorite
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func loadDocument(for drawing: CanvasExport) async -> CanvasDocument? {
        let url = drawing.url
        do {
            let document = try await Task.detached(priority: .userInitiated) {
                try CanvasExportStore.loadDocument(at: url)
            }.value
            guard !Task.isCancelled else { return nil }
            return document
        }
        catch {
            guard !Task.isCancelled else { return nil }
            errorMessage = L10n.text("This drawing was saved without stroke data and cannot be restored for editing.")
            return nil
        }
    }
}
