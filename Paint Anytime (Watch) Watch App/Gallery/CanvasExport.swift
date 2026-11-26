import Foundation

/// Built off the main thread when the gallery lists its folder in the background.
nonisolated struct CanvasExport: Identifiable {
    var id: URL { url }
    let url: URL
    var isFavorite: Bool = false
}
