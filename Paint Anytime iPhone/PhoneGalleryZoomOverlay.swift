import SwiftUI

/// One synchronous drawing surface owns images, clipping and geometry together.
@MainActor
struct PhoneGalleryZoomOverlay: View {
    let presentation: PhoneGalleryZoomPresentation
    let slots: [PhoneGalleryZoomSlot]
    let previews: [URL: UIImage]
    let sideBackdrops: [Int: UIImage]
    let sideBackdropFrame: CGRect
    let viewportInsets: EdgeInsets

    var body: some View {
        let position = presentation.position
        let bounded = min(2, max(0, position))
        let scale = 1 + position - bounded
        let from = bounded <= 1 ? 5 : 3
        let to = bounded <= 1 ? 3 : 1
        let progress = bounded <= 1 ? bounded : bounded - 1
        let blend = Double(progress * progress * (3 - 2 * progress))
        let anchor = presentation.elasticAnchor
        let offsetY = presentation.offsetY
        Canvas { context, size in
            // Extend under the header and home indicator, keeping slot and
            // gesture coordinates relative to the original scroll viewport.
            context.translateBy(x: 0, y: viewportInsets.top)
            context.translateBy(x: anchor.x, y: anchor.y + offsetY)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -anchor.x, y: -anchor.y)
            let visible = CGRect(x: anchor.x - anchor.x / scale,
                                 y: anchor.y - (anchor.y + offsetY + viewportInsets.top) / scale,
                                 width: size.width / scale, height: size.height / scale)
            if position < 0 {
                for direction in [-1, 1] {
                    if let image = sideBackdrops[direction] {
                        context.draw(Image(uiImage: image), in: sideBackdropFrame.offsetBy(
                            dx: CGFloat(direction) * sideBackdropFrame.width, dy: 0))
                    }
                }
            }
            for slot in slots {
                if position < 0, !(0..<5).contains(slot.columns[5] ?? -1) { continue }
                guard let start = slot.frames[from] else { continue }
                let end = slot.frames[to] ?? start
                let rect = CGRect(x: start.minX + (end.minX - start.minX) * progress,
                                  y: start.minY + (end.minY - start.minY) * progress,
                                  width: start.width + (end.width - start.width) * progress,
                                  height: start.height + (end.height - start.height) * progress)
                guard rect.intersects(visible), rect.width > 0, rect.height > 0 else { continue }
                let background = Color(uiColor: .systemBackground)
                context.fill(Path(rect), with: .color(background))
                if let url = slot.images[from], let image = previews[url] {
                    Self.draw(image, in: rect, context: context)
                }
                let preservesSource = slot.preservesSource(from: from, to: to)
                if !preservesSource, slot.images[to] != slot.images[from] {
                    if let url = slot.images[to], let image = previews[url] {
                        var destination = context
                        destination.opacity = blend
                        // Composite background and image as one fading layer.
                        destination.drawLayer { layer in
                            layer.fill(Path(rect), with: .color(background))
                            Self.draw(image, in: rect, context: layer)
                        }
                    } else if slot.images[to] == nil {
                        var empty = context
                        empty.opacity = blend
                        empty.fill(Path(rect), with: .color(background))
                    }
                }
            }
        }
        .padding(.top, -viewportInsets.top)
        .padding(.bottom, -viewportInsets.bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    nonisolated private static func draw(_ image: UIImage, in rect: CGRect, context: GraphicsContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.draw(Image(uiImage: image), in: CGRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height))
    }
}
