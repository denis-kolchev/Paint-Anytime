import SwiftUI

/// One synchronous drawing surface owns images, clipping and geometry together.
@MainActor
struct PhoneGalleryZoomOverlay: View {
    let presentation: PhoneGalleryZoomPresentation
    let slots: [PhoneGalleryZoomSlot]
    let previews: [URL: UIImage]
    let lowResPreviews: [URL: UIImage]
    let previewArrivals: [URL: Date]
    let sideBackdrops: [Int: UIImage]
    let sideBackdropFrame: CGRect
    let viewportInsets: EdgeInsets
    /// The latest arrival whose fade has finished; the timeline then pauses.
    @State private var settledArrival: Date?

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
        // Ticks only while a sharp preview is fading in, so late arrivals
        // animate even when the fingers are still.
        let latestArrival = previewArrivals.values.max()
        TimelineView(.animation(paused: latestArrival == nil || latestArrival == settledArrival)) { timeline in
            let now = timeline.date
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
                    if let url = slot.images[from] {
                        drawArtwork(url, in: rect, now: now, context: context)
                    }
                    let preservesSource = slot.preservesSource(from: from, to: to)
                    if !preservesSource, slot.images[to] != slot.images[from] {
                        if let url = slot.images[to], previews[url] != nil || lowResPreviews[url] != nil {
                            var destination = context
                            destination.opacity = blend
                            // Composite background and image as one fading layer.
                            destination.drawLayer { layer in
                                layer.fill(Path(rect), with: .color(background))
                                drawArtwork(url, in: rect, now: now, context: layer)
                            }
                        } else if slot.images[to] == nil {
                            var empty = context
                            empty.opacity = blend
                            empty.fill(Path(rect), with: .color(background))
                        }
                    }
                }
            }
        }
        .task(id: latestArrival) {
            guard let latestArrival else { return }
            try? await Task.sleep(for: .seconds(GalleryLowResFade.duration))
            guard !Task.isCancelled else { return }
            settledArrival = latestArrival
        }
        .padding(.top, -viewportInsets.top)
        .padding(.bottom, -viewportInsets.bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The sharp preview, fading in over the low-res snapshot after it arrives.
    private func drawArtwork(_ url: URL, in rect: CGRect, now: Date, context: GraphicsContext) {
        let sharp = previews[url]
        let opacity = sharp == nil ? 0
            : previewArrivals[url].map { GalleryLowResFade.opacity(elapsed: now.timeIntervalSince($0)) } ?? 1
        if opacity < 1, let lowRes = lowResPreviews[url] {
            Self.draw(lowRes, in: rect, context: context)
        }
        if let sharp, opacity > 0 {
            var faded = context
            faded.opacity *= opacity
            Self.draw(sharp, in: rect, context: faded)
        }
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
