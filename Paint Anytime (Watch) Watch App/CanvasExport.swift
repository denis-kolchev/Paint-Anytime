import Foundation

struct CanvasExport: Identifiable {
    var id: URL { url }
    let url: URL
    var isFavorite: Bool = false
    var isEditable: Bool {
        !url.lastPathComponent.hasPrefix(CanvasExportStore.tutorialPreviewPrefix)
    }
}
