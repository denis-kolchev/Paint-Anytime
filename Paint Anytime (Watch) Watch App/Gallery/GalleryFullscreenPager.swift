import SwiftUI

/// The 1:1 photo pager over the saved-drawings grid. The gallery owns the
/// selection; this view reports page changes, taps and page visibility.
struct GalleryFullscreenPager: View {
    let drawings: [CanvasExport]
    let selectedID: URL?
    let size: CGSize
    let canvasOriginX: CGFloat
    let canvasOriginY: CGFloat
    let thumbnailPixels: Int
    let displayScale: CGFloat
    /// Neighbor pages may load: no grid zoom, or one that ends in this pager.
    let loadsNearbyPages: Bool
    let isTransitioning: Bool
    let transitionBitmap: GalleryBitmap?
    /// The tutorial keeps the system safe areas.
    let respectsSafeArea: Bool
    let onSelect: (URL?) -> Void
    let onDisplayedBitmap: (CanvasExport, GalleryBitmap) -> Void
    let onTap: () -> Void
    /// Visibility in 0...1 for a page, or nil once the page disappears.
    let onVisibilityChange: (URL, Double?) -> Void

    var body: some View {
        let selectedIndex = drawings.firstIndex(where: { $0.id == selectedID }) ?? 0
        TabView(selection: Binding<URL?>(get: { selectedID }, set: onSelect)) {
            ForEach(Array(drawings.enumerated()), id: \.element.id) { index, drawing in
                GalleryFullscreenPage(url: drawing.url, size: size, canvasOriginY: canvasOriginY,
                                      thumbnailPixels: thumbnailPixels,
                                      displayScale: displayScale,
                                      isNearby: abs(index - selectedIndex) <= 1 && loadsNearbyPages,
                                      loadsOriginal: abs(index - selectedIndex) <= 1 && loadsNearbyPages,
                                      fallback: transitionBitmap?.url == drawing.url ? transitionBitmap : nil,
                                      respectsSafeArea: respectsSafeArea,
                                      fitsViewport: true,
                                      isSelected: drawing.id == selectedID,
                                      onDisplayedBitmap: { bitmap in
                                          onDisplayedBitmap(drawing, bitmap)
                                      })
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .onGeometryChange(for: Double.self) { page in
                        let distance = abs(page.frame(in: .global).minX - canvasOriginX)
                        return max(0, 1 - Double(distance / max(size.width, 1)))
                    } action: { visibility in
                        // Read each native page directly; no preference propagation through TabView.
                        onVisibilityChange(drawing.id, visibility)
                    }
                    .onDisappear {
                        onVisibilityChange(drawing.id, nil)
                    }
                    .tag(Optional(drawing.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(.container, edges: respectsSafeArea ? [] : .all)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .position(x: size.width / 2, y: size.height / 2)
        .task(id: isTransitioning ? nil : selectedID) {
            guard !isTransitioning else { return }
            // Warm adjacent originals even if TabView has not mounted those pages yet.
            for index in [selectedIndex, selectedIndex - 1, selectedIndex + 1] {
                guard !Task.isCancelled else { return }
                guard drawings.indices.contains(index) else { continue }
                _ = await GalleryImageCache.shared.load(GalleryImageRequest(
                    url: drawings[index].url, shortSidePixels: nil, displayScale: displayScale))
            }
        }
    }
}
