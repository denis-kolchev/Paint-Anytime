import SwiftUI

@MainActor
struct PhoneGalleryZoomOverlay: View {
    let presentation: PhoneGalleryZoomPresentation
    let slots: [PhoneGalleryZoomSlot]
    let frame: CGRect
    let cache: PhoneGalleryPreviewCache
    let previews: [URL: UIImage]
    let previewSize: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                let sourceFrame = slot.frames[presentation.fromColumns] ?? .zero
                let destinationFrame = slot.frames[presentation.toColumns] ?? sourceFrame
                let progress = presentation.geometryProgress
                let width = sourceFrame.width + (destinationFrame.width - sourceFrame.width) * progress
                let height = sourceFrame.height + (destinationFrame.height - sourceFrame.height) * progress
                PhoneGalleryZoomTile(
                    source: slot.images[presentation.fromColumns],
                    destination: slot.images[presentation.toColumns],
                    blend: presentation.blend, side: width, cache: cache, height: height,
                    preservesSource: slot.preservesSource(
                        from: presentation.fromColumns, to: presentation.toColumns),
                    fixedPreviewSize: previewSize, frozenPreviews: previews)
                    .offset(x: sourceFrame.minX + (destinationFrame.minX - sourceFrame.minX) * progress,
                            y: sourceFrame.minY + (destinationFrame.minY - sourceFrame.minY) * progress)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(y: presentation.offsetY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
