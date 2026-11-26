import SwiftUI

/// Tile frames in the `drawingGallery` space, reported by the saved-drawings grid.
struct GalleryThumbnailFramesKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] { [:] }

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
