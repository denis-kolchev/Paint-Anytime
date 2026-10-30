import SwiftUI

/// A slot stays in the same place relative to the focal image at every density.
@MainActor
struct PhoneGalleryZoomTile: View {
    let source: URL?
    let destination: URL?
    let blend: Double
    let side: CGFloat
    let cache: PhoneGalleryPreviewCache
    var height: CGFloat? = nil
    var renderedScale: CGFloat = 1
    var preparesOtherSizes = false
    var preservesSource = false
    var fixedPreviewSize: Int? = nil
    var frozenPreviews: [URL: UIImage] = [:]
    @Environment(\.displayScale) private var displayScale

    private var previewSize: Int {
        fixedPreviewSize ?? PhoneGalleryPreviewCache.size(for: max(side, height ?? side) * renderedScale * displayScale)
    }

    private var imageURLs: [URL] {
        var urls: [URL] = []
        if let source { urls.append(source) }
        if let destination, destination != source { urls.append(destination) }
        return urls
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            // Keep the same view and loaded preview when a photograph changes
            // from destination to source at the three-column boundary (or back).
            ForEach(imageURLs, id: \.self) { url in
                let isDestination = url == destination && destination != source
                Group {
                    if let image = frozenPreviews[url] {
                        // The gesture snapshot already owns this image. Render it
                        // directly without loader tasks or displayed-cache state.
                        let viewport = CGSize(width: side, height: height ?? side)
                        let scale = max(viewport.width / max(image.size.width, 1),
                                        viewport.height / max(image.size.height, 1))
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(width: viewport.width, height: viewport.height)
                            .background {
                                if isDestination { Color(uiColor: .systemBackground) }
                            }
                            .clipped()
                    } else {
                        DrawingPreview(url: url, maximumSize: previewSize, fillsFrame: true, cache: cache,
                                       preparesOtherSizes: preparesOtherSizes,
                                       isTransitionDestination: isDestination,
                                       frozenPreview: frozenPreviews[url],
                                       viewportSize: CGSize(width: side, height: height ?? side))
                    }
                }
                    .compositingGroup()
                    .opacity(isDestination ? (preservesSource ? 0 : blend) : 1)
                    .zIndex(isDestination ? 1 : 0)
                    .transition(.identity)
            }
            if destination == nil, source != nil, !preservesSource {
                // Actual empty slots dissolve to the theme background, while
                // a pending image keeps showing the already loaded source.
                Color(uiColor: .systemBackground)
                    .opacity(blend)
                    .zIndex(2)
                    .transition(.identity)
            }
        }
        .frame(width: side, height: height ?? side)
        .clipped()
    }
}
