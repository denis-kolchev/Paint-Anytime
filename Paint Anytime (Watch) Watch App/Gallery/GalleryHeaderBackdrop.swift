import SwiftUI

/// One persistent material above both native tiles and the zoom compositor.
/// Observe animation progress here, without invalidating the gallery container.
struct GalleryHeaderBackdrop: View {
    let height: CGFloat
    let zoom: GalleryGridZoom
    let showsFullscreen: Bool

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: height)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.5),
                    .init(color: .black.opacity(0.75), location: 0.7),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .opacity(zoom.active
                ? Double(min(1, max(0, 2 - zoom.position)))
                : (showsFullscreen ? 0 : 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
