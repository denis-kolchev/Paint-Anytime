import Observation

/// Only the thumbnail body observes this value, never the parent grid.
@MainActor
@Observable
final class GalleryThumbnailVisibility {
    var isNearViewport = false
    @ObservationIgnored var fallback: GalleryBitmap?
}
