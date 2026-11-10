import SwiftUI

/// The saved-drawings thumbnail grid. Reports every tile's frame, including
/// offscreen zoom destinations, through `GalleryThumbnailFramesKey`.
struct SavedDrawingsGrid: View {
    let drawings: [CanvasExport]
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
        } else if drawings.isEmpty {
            ContentUnavailableView(L10n.text("No drawings"), systemImage: "photo.on.rectangle")
        } else {
            GalleryThumbnailGrid(columns: columns, spacing: spacing, side: side, leading: leadingSlots) {
                ForEach(drawings) { drawing in
                    Button {
                        onTap(drawing)
                    } label: {
                        GalleryThumbnailView(request: GalleryImageRequest(
                            url: drawing.url, shortSidePixels: thumbnailPixels, displayScale: displayScale),
                            loadsImage: loadsImages,
                            visibility: gridStorage.visibility(for: drawing.id),
                            isFavorite: drawing.isFavorite,
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
