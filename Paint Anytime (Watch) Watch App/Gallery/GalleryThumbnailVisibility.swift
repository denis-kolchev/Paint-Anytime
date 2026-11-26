import Foundation
import Observation

/// Only the thumbnail body observes this value, never the parent grid.
@MainActor
@Observable
final class GalleryThumbnailVisibility {
    var isNearViewport = false
    /// False until the grid reports tile frames for the first time.
    var isMeasured = false
    var contentRevision = UUID()
    @ObservationIgnored var fallback: GalleryBitmap?
}
