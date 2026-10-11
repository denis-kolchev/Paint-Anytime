import Combine
import Foundation

@MainActor
final class GalleryController: ObservableObject {
    @Published private(set) var drawings: [CanvasExport] = []
    @Published var errorMessage: String?

    func reload(in folder: URL? = nil) {
        do {
            drawings = try CanvasExportStore.all(in: folder)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ drawing: CanvasExport, in folder: URL? = nil) -> Bool {
        do {
            try CanvasExportStore.delete(drawing, in: folder)
            Task { await GalleryImageCache.shared.remove(drawing.url) }
            drawings.removeAll { $0.id == drawing.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loadDocument(for drawing: CanvasExport) -> CanvasDocument? {
        do { return try CanvasExportStore.loadDocument(for: drawing) }
        catch {
            errorMessage = L10n.text("This drawing was saved without stroke data and cannot be restored for editing.")
            return nil
        }
    }
}
