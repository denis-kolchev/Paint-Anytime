import Foundation
import CoreGraphics

nonisolated struct WatchLassoSelection {
    var document: CanvasDocument
    let layerID: UUID
    var strokes: [Stroke]
    let selectedIDs: Set<UUID>
    // Bounds retain their local width and height; rotation never enlarges them.
    var bounds: CGRect
    var rotation: CGFloat = 0
}
