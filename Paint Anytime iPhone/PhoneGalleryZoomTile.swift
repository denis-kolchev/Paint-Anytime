import SwiftUI

/// A slot stays in the same place relative to the focal image at every density.
@MainActor
struct PhoneGalleryZoomTile: View {
    let source: URL?
    let destination: URL?
    let blend: Double
    let side: CGFloat
    let cache: PhoneGalleryPreviewCache
    var renderedScale: CGFloat = 1
    var preparesOtherSizes = false
    @Environment(\.displayScale) private var displayScale

    private var previewSize: Int {
        PhoneGalleryPreviewCache.size(for: side * renderedScale * displayScale)
    }

    var body: some View {
        ZStack {
            // An empty slot is an opaque background-colored tile, so it takes
            // part in the same dissolve as an ordinary image in either direction.
            Color(uiColor: .systemBackground)
            if let source {
                DrawingPreview(url: source, maximumSize: previewSize, fillsFrame: true, cache: cache,
                               preparesOtherSizes: preparesOtherSizes)
                    .id(source)
            }
            if destination != source {
                ZStack {
                    Color(uiColor: .systemBackground)
                    if let destination {
                        DrawingPreview(url: destination, maximumSize: previewSize, fillsFrame: true, cache: cache,
                                       preparesOtherSizes: preparesOtherSizes)
                            .id(destination)
                    }
                }
                // Composite the destination once, including its opaque backing.
                // This also covers source -> empty and empty -> destination.
                .compositingGroup()
                .opacity(blend)
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}
