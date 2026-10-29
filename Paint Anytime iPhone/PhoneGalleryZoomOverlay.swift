import SwiftUI

@MainActor
struct PhoneGalleryZoomOverlay: View {
    let presentation: PhoneGalleryZoomPresentation
    let slots: [PhoneGalleryZoomSlot]
    let frame: CGRect
    let cache: PhoneGalleryPreviewCache
    let previews: [URL: UIImage]
    let previewSize: Int
    let sideBackdrop: UIImage?
    let sideBackdropFrame: CGRect

    var body: some View {
        PhoneGalleryZoomFrame(
            slots: slots, frame: frame, cache: cache, previews: previews,
            previewSize: previewSize, sideBackdrop: sideBackdrop,
            sideBackdropFrame: sideBackdropFrame, elasticAnchor: presentation.elasticAnchor,
            position: presentation.position,
            offsetY: presentation.offsetY)
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
    let sideBackdrop: UIImage?
    let sideBackdropFrame: CGRect
    let elasticAnchor: CGPoint
    // Animatable's accessors are nonisolated. Only these value-type scalars
    // participate in interpolation; UI and cache access stay on MainActor.
    nonisolated var position: CGFloat
    nonisolated var offsetY: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, offsetY) }
        set {
            position = newValue.first
            offsetY = newValue.second
        }
    }

    var body: some View {
        // Select both the image pair and its geometry from the interpolated
        // position, never from discrete endpoint state supplied by the parent.
        let boundedPosition = min(2, max(0, position))
        let elasticScale = 1 + position - boundedPosition
        let fromColumns = boundedPosition <= 1 ? 5 : 3
        let toColumns = boundedPosition <= 1 ? 3 : 1
        let progress = boundedPosition <= 1 ? boundedPosition : boundedPosition - 1
        let blend = Double(progress * progress * (3 - 2 * progress))

        ZStack(alignment: .topLeading) {
            if position < 0, let sideBackdrop {
                // Repeat the baked five-column strip diagonally by one row.
                // Both offsets are whole grid strides, so the seams line up.
                let rowStride = sideBackdropFrame.width / 5
                ForEach([-1, 1], id: \.self) { direction in
                    Image(uiImage: sideBackdrop)
                        .resizable()
                        .frame(width: sideBackdropFrame.width, height: sideBackdropFrame.height)
                        .offset(x: CGFloat(direction) * sideBackdropFrame.width,
                                y: sideBackdropFrame.minY + CGFloat(direction) * rowStride)
                }
            }
            ForEach(slots) { slot in
                // Empty offscreen transition slots must not cover the baked copies.
                if position >= 0 || (0..<5).contains(slot.columns[5] ?? -1) {
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
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        // Transform the whole rendered grid, including spacing and clips, so
        // rubber-banding cannot separate an image from its tile boundaries.
        .scaleEffect(elasticScale, anchor: UnitPoint(
            x: elasticAnchor.x / max(frame.width, 1),
            y: elasticAnchor.y / max(frame.height, 1)))
        .offset(y: offsetY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}
