import SwiftUI

/// The saved-drawings thumbnail grid. Reports every tile's frame, including
/// offscreen zoom destinations, through `GalleryThumbnailFramesKey`.
struct SavedDrawingsGrid: View {
    let drawings: [CanvasExport]
    var isLoaded = true
    let errorMessage: String?
    let columns: Int
    let spacing: CGFloat
    let side: CGFloat
    let leadingSlots: Int
    let thumbnailPixels: Int
    let displayScale: CGFloat
    let loadsImages: Bool
    let isSelecting: Bool
    let selectedURLs: Set<URL>
    /// The tutorial allows opening and zooming tiles.
    let allowsOpening: Bool
    /// Not observed: bitmap reports must not invalidate the grid.
    let gridStorage: GalleryGridStorage
    let onTap: (CanvasExport) -> Void

    var body: some View {
        if let errorMessage {
            Text(errorMessage).foregroundStyle(.red).padding()
        } else if !isLoaded {
            // The list is still being read off the main thread.
            Color.clear
        } else if drawings.isEmpty {
            ContentUnavailableView(L10n.text("No drawings"), systemImage: "photo.on.rectangle")
        } else {
            GalleryThumbnailGrid(columns: columns, spacing: spacing, side: side, leading: leadingSlots) {
                ForEach(Array(drawings.enumerated()), id: \.element.id) { index, drawing in
                    // Only tiles near the viewport build a button and thumbnail; the rest
                    // are empty slots of the same size. Building all 90 took ~320 ms.
                    GalleryTileSlot(visibility: gridStorage.visibility(for: drawing.id),
                                    buildsBeforeMeasurement: index + leadingSlots < columns * 8) {
                        Button {
                            onTap(drawing)
                        } label: {
                            GalleryThumbnailView(request: GalleryImageRequest(
                                url: drawing.url, shortSidePixels: thumbnailPixels, displayScale: displayScale),
                                loadsImage: loadsImages,
                                visibility: gridStorage.visibility(for: drawing.id),
                                isFavorite: drawing.isFavorite,
                                // Before the first frame report, assume the opening screens are visible.
                                showsPreviewBeforeMeasurement: index + leadingSlots < columns * 8,
                                onDisplayedBitmap: { bitmap in
                                    gridStorage.bitmaps[drawing.id] = bitmap
                                })
                                .frame(width: side, height: side)
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    if isSelecting {
                                        GallerySelectionMark(isSelected: selectedURLs.contains(drawing.url), side: side)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowsOpening)
                        .accessibilityLabel(L10n.text("Open drawing"))
                        .accessibilityAddTraits(isSelecting && selectedURLs.contains(drawing.url) ? .isSelected : [])
                    }
                    .id(drawing.id)
                }
            }
            .background {
                GeometryReader { gridGeometry in
                    // The layout is regular: one measured origin is enough for
                    // every tile, including offscreen zoom destinations.
                    let origin = gridGeometry.frame(in: .named("drawingGallery")).origin
                    Color.clear.preference(key: GalleryThumbnailFramesKey.self,
                        value: Dictionary(uniqueKeysWithValues: drawings.enumerated().map { index, drawing in
                            let slot = index + leadingSlots
                            return (drawing.id, CGRect(
                                x: origin.x + CGFloat(slot % columns) * (side + spacing),
                                y: origin.y + CGFloat(slot / columns) * (side + spacing),
                                width: side, height: side))
                        }))
                }
            }
            .padding(.bottom, 12)
        }
    }
}

/// Observes one tile's proximity, so scrolling rebuilds only the tiles that cross the
/// prefetch margin, never the grid. Far slots stay laid out for scrolling and zoom.
struct GalleryTileSlot<Content: View>: View {
    let visibility: GalleryThumbnailVisibility
    let buildsBeforeMeasurement: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if visibility.isNearViewport || (!visibility.isMeasured && buildsBeforeMeasurement) {
            content()
        } else {
            Color.clear
        }
    }
}
