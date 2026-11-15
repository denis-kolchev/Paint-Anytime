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
    let onOpen: () -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let longSide: CGFloat = 46
    static let shortSideMinimum: CGFloat = 24
    /// Space between the thumbnail and the control below it.
    static let controlGap: CGFloat = 6
    static let bottomTrailingSlot = 4

    private var frames: Binding<[CanvasToolbarControl: CGRect]> {
        Binding(get: { regions.frames }, set: { regions.frames = $0 })
    }

    var body: some View {
        ZStack {
            if isVisible, store.isEnabled, let image = store.image {
                let frame = Self.frame(for: CGSize(width: image.width, height: image.height),
                                       layout: layout, regions: regions, size: size,
                                       canvasOrigin: canvasOrigin, layoutDirection: layoutDirection)
                Button(action: onOpen) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
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
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                // A hidden thumbnail must not keep its no-draw zone on the canvas.
                .onDisappear { regions.frames[.reference] = nil }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.2), value: isVisible)
        .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.2), value: store.isEnabled)
    }

    /// The thumbnail's rectangle in canvas coordinates: the image's aspect within
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
        let bottom = size.height - (top.y - radius)
        let isRightToLeft = layoutDirection == .rightToLeft
        let x = isRightToLeft ? top.x - radius : top.x + radius - thumbnail.width
        return CGRect(x: x, y: bottom - thumbnail.height, width: thumbnail.width, height: thumbnail.height)
    }
}
