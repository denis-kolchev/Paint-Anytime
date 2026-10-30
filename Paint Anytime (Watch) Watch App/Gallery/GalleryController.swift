import Combine
import Foundation

@MainActor
final class GalleryController: ObservableObject {
    @Published private(set) var drawings: [CanvasExport] = []
    @Published var errorMessage: String?

    func reload(in folder: URL? = nil) {
        do {
            var loaded = try CanvasExportStore.all(in: folder)
            drawings = loaded
            if folder == nil {
                // The same switch, bundled fixtures, installation rules and image
                // list as WatchPhotoInbox on iPhone. Only Watch metadata is added.
                let samples = try DebugGallerySamples.images()
                if !samples.isEmpty {
                    loaded += try CanvasExportStore.exports(for: samples, in: DebugGallerySamples.directory())
                }
            }
            drawings = loaded.sorted { DebugGallerySamples.orderedBefore($0.url, $1.url) }
            if folder == nil { try? CanvasExportStore.refreshWidgets() }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ drawing: CanvasExport, in folder: URL? = nil) -> Bool {
        defer { if folder == nil { WatchPhotoTransfer.shared.publishDeletions() } }
        do {
            try CanvasExportStore.delete(drawing, in: DebugGallerySamples.contains(drawing.url) ? DebugGallerySamples.directory() : folder)
            Task { await GalleryImageCache.shared.remove(drawing.url) }
            drawings.removeAll { $0.id == drawing.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setFavorite(_ isFavorite: Bool, for drawing: CanvasExport, in folder: URL? = nil) {
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
