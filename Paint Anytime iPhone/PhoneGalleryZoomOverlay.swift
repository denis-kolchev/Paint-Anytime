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
        PhoneGalleryZoomFrame(
            slots: slots, frame: frame, cache: cache, previews: previews,
            previewSize: previewSize, fromColumns: presentation.fromColumns,
            toColumns: presentation.toColumns, progress: presentation.geometryProgress,
            blend: presentation.blend, offsetY: presentation.offsetY)
    }
}

/// Interpolate one presentation frame, then lay out every image and clip using
/// that frame. Child frames must not run independent endpoint animations.
@MainActor
private struct PhoneGalleryZoomFrame: View, Animatable {
    let slots: [PhoneGalleryZoomSlot]
    let frame: CGRect
    let cache: PhoneGalleryPreviewCache
    let previews: [URL: UIImage]
    let previewSize: Int
    let fromColumns: Int
    let toColumns: Int
    var progress: CGFloat
    var blend: Double
    var offsetY: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, Double> {
        get { AnimatablePair(AnimatablePair(progress, offsetY), blend) }
        set {
            progress = newValue.first.first
            offsetY = newValue.first.second
            blend = newValue.second
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slots) { slot in
                let sourceFrame = slot.frames[fromColumns] ?? .zero
                let destinationFrame = slot.frames[toColumns] ?? sourceFrame
                let width = sourceFrame.width + (destinationFrame.width - sourceFrame.width) * progress
                let height = sourceFrame.height + (destinationFrame.height - sourceFrame.height) * progress
                PhoneGalleryZoomTile(
                    source: slot.images[fromColumns],
                    destination: slot.images[toColumns],
                    blend: blend, side: width, cache: cache, height: height,
                    preservesSource: slot.preservesSource(
                        from: fromColumns, to: toColumns),
                    fixedPreviewSize: previewSize, frozenPreviews: previews)
                    .offset(x: sourceFrame.minX + (destinationFrame.minX - sourceFrame.minX) * progress,
                            y: sourceFrame.minY + (destinationFrame.minY - sourceFrame.minY) * progress)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(y: offsetY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}
