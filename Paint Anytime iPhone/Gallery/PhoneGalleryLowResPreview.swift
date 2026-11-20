import SwiftUI

/// The 32 px snapshot a gallery tile shows until its sharp preview decodes,
/// so the grid never shows empty tiles or spinners. Only this view observes
/// the drawing's preview slot; the grid is not invalidated when it arrives.
@MainActor
struct PhoneGalleryLowResPreview: View {
    let url: URL
    var fillsFrame = true
    var viewportSize: CGSize? = nil

    var body: some View {
        if let image = GalleryPreviewStore.shared.slot(for: url).preview?.image {
            let size = CGSize(width: image.width, height: image.height)
            if let viewportSize {
                // Matches DrawingPreview's aspect-fill frame, so the sharp
                // image replaces this one without a jump.
                let scale = max(viewportSize.width / max(size.width, 1),
                                viewportSize.height / max(size.height, 1))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .clipped()
            } else {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
            }
        } else {
            // Only before the first preview pass reaches this drawing.
            Color(uiColor: .secondarySystemBackground)
        }
    }
}
