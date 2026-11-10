import SwiftUI

/// The resting gallery grid. It reports tile and grid frames in the
/// `phoneGalleryViewport` space for the pinch zoom.
struct PhoneGalleryGrid: View {
    let images: [URL]
    let columnCount: Int
    let leadingSlots: Int
    let width: CGFloat
    let previewCache: PhoneGalleryPreviewCache
    let imageLayout: GalleryImageLayout
    /// The zoom overlay is drawing the gallery; keep this grid as a layout host.
    let isZooming: Bool
    let pendingZoomTarget: URL?
    let open: (URL) -> Void

    private var spacing: CGFloat { PhoneGalleryZoomController.spacing }

    var body: some View {
        let tileSize = max(1, (width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount), spacing: spacing) {
            ForEach(0..<leadingSlots, id: \.self) { _ in
                Color(uiColor: .systemBackground).frame(height: tileSize).accessibilityHidden(true)
            }
            ForEach(images, id: \.self) { url in
                Button {
                    open(url)
                } label: {
                    PhoneGalleryZoomTile(source: url, destination: nil,
                                         blend: 0, side: tileSize, cache: previewCache,
                                         height: columnCount == 1 ? imageLayout.height(for: url, width: tileSize) : tileSize,
                                         preparesOtherSizes: !isZooming)
                }
                .buttonStyle(.plain)
                .id(url)
                .background {
                    if url == pendingZoomTarget {
                        GeometryReader { tile in
                            Color.clear.preference(key: PhoneGalleryTargetFrameKey.self,
                                value: PhoneGalleryLayout(columns: columnCount,
                                    frame: tile.frame(in: .named("phoneGalleryViewport"))))
                        }
                    }
                }
                .background {
                    GeometryReader { tile in
                        Color.clear.preference(key: PhoneGalleryMeasuredTilesKey.self,
                            value: [url: PhoneGalleryLayout(columns: columnCount,
                                frame: tile.frame(in: .named("phoneGalleryViewport")))])
                    }
                }
                .accessibilityLabel(Text(url.deletingPathExtension().lastPathComponent))
            }
            let trailingSlots = (columnCount - (leadingSlots + images.count) % columnCount) % columnCount
            ForEach(0..<trailingSlots, id: \.self) { _ in
                Color(uiColor: .systemBackground)
                    .frame(height: tileSize)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Keep the scroll layout and gesture host alive, but draw
        // the zoom independently of LazyVGrid's source-row culling.
        .opacity(isZooming ? 0 : 1)
        .background {
            GeometryReader { grid in
                Color.clear.preference(key: PhoneGalleryFrameKey.self,
                    value: PhoneGalleryLayout(columns: columnCount,
                        frame: grid.frame(in: .named("phoneGalleryViewport"))))
            }
        }
    }
}
