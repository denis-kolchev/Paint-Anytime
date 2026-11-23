import SwiftUI

/// The reference as a small picture in the canvas's bottom-trailing corner. With a custom
/// control in that corner it sits just above the control. Its own view, so the store and
/// the measured toolbar anchors invalidate only this thumbnail, not the canvas screen.
struct ReferenceCanvasThumbnail: View {
    @ObservedObject var store = ReferenceImageStore.shared
    /// The custom layout on the canvas, or nil for the built-in menus (bottom row empty).
    let layout: CanvasControlLayout?
    let regions: CanvasControlRegions
    let size: CGSize
    let canvasOrigin: CGPoint
    let isVisible: Bool
    /// The brush editor covers the canvas: the thumbnail stays mounted and fades with the
    /// other canvas controls instead of vanishing ahead of them.
    var isCoveredByEditor = false
    let onOpen: () -> Void
    @Environment(\.layoutDirection) private var layoutDirection

    static let longSide: CGFloat = 46
    static let shortSideMinimum: CGFloat = 24
    /// Space between the thumbnail and the control below it.
    static let controlGap: CGFloat = 6
    static let bottomTrailingSlot = 4
    /// The bottom-row slot beside the bottom-trailing corner.
    static let neighborSlot = 3
    /// Space between a free-corner thumbnail and the circle beside it.
    static let neighborGap: CGFloat = 4
    /// The thumbnail shrinks no further than this beside that circle; below it, it moves up.
    static let longSideMinimum: CGFloat = 32

    private var frames: Binding<[CanvasToolbarControl: CGRect]> {
        Binding(get: { regions.frames }, set: { regions.frames = $0 })
    }

    var body: some View {
        ZStack {
            if isVisible, store.isEnabled {
                let image = store.image
                // Without an image the reference stays in place as an empty square window.
                let imageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1)
                // The part the full-screen view shows, so its zoom carries over to the canvas.
                let region = image == nil ? CGRect(x: 0, y: 0, width: 1, height: 1)
                    : store.viewerState.reference.visibleRegion(imageSize: imageSize,
                                                                screen: store.viewerState.screenSize)
                let regionSize = CGSize(width: imageSize.width * region.width,
                                        height: imageSize.height * region.height)
                let frame = Self.frame(for: regionSize,
                                       layout: layout, regions: regions, size: size,
                                       canvasOrigin: canvasOrigin, layoutDirection: layoutDirection)
                Button(action: onOpen) {
                    Group {
                        if let image {
                            Self.picture(image, region: region, imageSize: imageSize, frame: frame.size)
                        } else {
                            Color.black.opacity(0.35)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CanvasMorphButtonStyle())
                .accessibilityLabel(L10n.text("Reference image"))
                .trackCanvasControl(.reference, frames: frames)
                .position(x: frame.midX, y: frame.midY)
                // Appears and disappears instantly, without a transition.
                .transition(.identity)
                // A hidden thumbnail must not keep its no-draw zone on the canvas.
                .onDisappear { regions.frames[.reference] = nil }
            }
        }
        .frame(width: size.width, height: size.height)
        // Ignore animations inherited from the screen's state changes (gallery, menus).
        .transaction { $0.animation = nil }
        // Outside the transaction above: the same fade the canvas stack gives the morph
        // panels and custom controls when the brush editor opens or closes.
        .opacity(isCoveredByEditor ? 0 : 1)
        .animation(.easeInOut(duration: 0.25), value: isCoveredByEditor)
        .allowsHitTesting(!isCoveredByEditor)
        .accessibilityHidden(isCoveredByEditor)
    }

    /// `region` of the picture filling `frame`, centered: the whole picture is laid out
    /// at the scale that makes the region cover the frame, then clipped by the caller.
    private static func picture(_ image: CGImage, region: CGRect, imageSize: CGSize, frame: CGSize) -> some View {
        let regionSize = CGSize(width: max(1, imageSize.width * region.width),
                                height: max(1, imageSize.height * region.height))
        let scale = max(frame.width / regionSize.width, frame.height / regionSize.height)
        let full = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: full.width, height: full.height)
            .offset(x: frame.width / 2 - region.midX * full.width,
                    y: frame.height / 2 - region.midY * full.height)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    }

    /// The thumbnail's rectangle in canvas coordinates: the shown region's aspect within
    /// `longSide`, centered where the bottom-trailing control's circle is, or above it.
    static func frame(for imageSize: CGSize, layout: CanvasControlLayout?, regions: CanvasControlRegions,
                      size: CGSize, canvasOrigin: CGPoint, layoutDirection: LayoutDirection) -> CGRect {
        let aspect = imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        let thumbnail = aspect >= 1
            ? CGSize(width: longSide, height: max(shortSideMinimum, longSide / aspect))
            : CGSize(width: max(shortSideMinimum, longSide * aspect), height: longSide)
        let geometry = MorphPanelGeometry(size: size, layoutDirection: layoutDirection)
        let slot = CustomCanvasControls.slotCenter(bottomTrailingSlot, geometry: geometry,
                                                   regions: regions, canvasOrigin: canvasOrigin)
        if let layout, layout.slots.indices.contains(bottomTrailingSlot),
           !layout.slots[bottomTrailingSlot].isEmpty {
            let centerY = slot.y - geometry.diameter / 2 - controlGap - thumbnail.height / 2
            return CGRect(x: slot.x - thumbnail.width / 2, y: centerY - thumbnail.height / 2,
                          width: thumbnail.width, height: thumbnail.height)
        }
        // A free corner: the thumbnail's outer bottom corner sits as far from the screen
        // edges as the top-trailing circle's outer top corner does, mirrored vertically.
        let top = CustomCanvasControls.slotCenter(0, geometry: geometry, regions: regions,
                                                  canvasOrigin: canvasOrigin)
        let radius = geometry.diameter / 2
        var bottom = size.height - (top.y - radius)
        let isRightToLeft = layoutDirection == .rightToLeft
        let outerX = isRightToLeft ? top.x - radius : top.x + radius
        var thumbnailSize = thumbnail
        // The circle next to the free corner: on narrow screens it reaches under the
        // thumbnail. Shrink the thumbnail to the space beside it, then, if it still overlaps
        // at the minimum size, lift it just above the circle.
        if let layout, layout.slots.indices.contains(neighborSlot), !layout.slots[neighborSlot].isEmpty {
            let neighbor = CustomCanvasControls.slotCenter(neighborSlot, geometry: geometry,
                                                           regions: regions, canvasOrigin: canvasOrigin)
            let clearance = radius + neighborGap
            let available = abs(outerX - neighbor.x) - clearance
            let longest = max(thumbnailSize.width, thumbnailSize.height)
            if thumbnailSize.width > available {
                let scale = min(1, max(available / thumbnailSize.width, longSideMinimum / longest))
                thumbnailSize = CGSize(width: thumbnailSize.width * scale, height: thumbnailSize.height * scale)
            }
            let dx = abs(outerX - neighbor.x) - thumbnailSize.width
            if dx < clearance {
                bottom = min(bottom, neighbor.y - (clearance * clearance - dx * dx).squareRoot())
            }
        }
        let x = isRightToLeft ? outerX : outerX - thumbnailSize.width
        return CGRect(x: x, y: bottom - thumbnailSize.height,
                      width: thumbnailSize.width, height: thumbnailSize.height)
    }
}
