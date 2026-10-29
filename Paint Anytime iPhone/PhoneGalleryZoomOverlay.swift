import SwiftUI

@MainActor
struct PhoneGalleryZoomOverlay: View {
    let presentation: PhoneGalleryZoomPresentation
    let slots: [PhoneGalleryZoomSlot]
    let side: CGFloat
    let frame: CGRect
    let cache: PhoneGalleryPreviewCache
    let previews: [URL: UIImage]
    let previewSize: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                PhoneGalleryZoomTile(
                    source: slot.images[presentation.fromColumns],
                    destination: slot.images[presentation.toColumns],
                    blend: presentation.blend, side: side, cache: cache,
                    preservesSource: slot.preservesSource(
                        from: presentation.fromColumns, to: presentation.toColumns),
                    fixedPreviewSize: previewSize, frozenPreviews: previews)
                    .scaleEffect(presentation.scale)
                    .offset(x: slot.origin.x + (presentation.scale - 1) * slot.scaleOffset.width,
                            y: slot.origin.y + (presentation.scale - 1) * slot.scaleOffset.height)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: presentation.offsetX, y: frame.minY + presentation.offsetY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
