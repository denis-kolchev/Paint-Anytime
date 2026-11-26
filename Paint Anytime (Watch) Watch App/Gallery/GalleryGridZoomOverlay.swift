import SwiftUI

/// The phone's slot compositor, using CGImage on watch instead of UIKit images.
struct GalleryGridZoomOverlay: View {
    let zoom: GalleryGridZoom
    /// Taps during settlement or restore; the native grid ignores input meanwhile.
    var onTap: (CGPoint) -> Void = { _ in }
    @GestureState private var dragging = false
    /// The latest arrival whose fade has finished; the timeline then pauses.
    @State private var settledArrival: Date?

    var body: some View {
        let bounded = min(2, max(0, zoom.position))
        let scale = 1 + zoom.position - bounded
        let from = bounded <= 1 ? 5 : 3
        let to = bounded <= 1 ? 3 : 1
        let progress = bounded <= 1 ? bounded : bounded - 1
        let blend = Double(progress * progress * (3 - 2 * progress))
        // Ticks only while a sharp image is fading in over its low-res preview.
        let latestArrival = zoom.imageArrivals.values.max()
        TimelineView(.animation(paused: latestArrival == nil || latestArrival == settledArrival)) { timeline in
            let now = timeline.date
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                let anchor = zoom.elasticAnchor
                let visible = CGRect(x: anchor.x - anchor.x / scale,
                    y: anchor.y - (anchor.y + zoom.presentationOffsetY + zoom.topInset) / scale,
                    width: size.width / scale, height: size.height / scale)
                context.translateBy(x: 0, y: zoom.topInset)
                context.translateBy(x: anchor.x, y: anchor.y + zoom.presentationOffsetY)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -anchor.x, y: -anchor.y)
                if zoom.position < 0 {
                    let stride = GalleryZoomRules.side(5, width: zoom.viewport.width) + GalleryZoomRules.spacing
                    let leading = zoom.leading[5] ?? 0
                    let anchorRow = (zoom.index + leading) / 5
                    for slot in zoom.slots {
                        guard let column = slot.columns[5], (0..<5).contains(column),
                              let rect = slot.frames[5] else { continue }
                        let row = anchorRow + Int(((rect.minY - (zoom.tops[5] ?? 0)) / stride).rounded())
                        for direction in [-1, 1] {
                            guard let url = GalleryZoomRules.backdropURL(images: zoom.snapshot,
                                leading: leading, row: row, column: column, direction: direction),
                                  hasImage(url) else { continue }
                            let copy = rect.offsetBy(dx: CGFloat(direction) * (zoom.viewport.width + GalleryZoomRules.spacing), dy: 0)
                            if copy.intersects(visible) { drawArtwork(url, in: copy, now: now, context: context) }
                        }
                    }
                }
                for slot in zoom.slots {
                    if zoom.position < 0, !(0..<5).contains(slot.columns[5] ?? -1) { continue }
                    guard let start = slot.frames[from], let end = slot.frames[to] else { continue }
                    let rect = CGRect(x: start.minX + (end.minX - start.minX) * progress,
                                      y: start.minY + (end.minY - start.minY) * progress,
                                      width: start.width + (end.width - start.width) * progress,
                                      height: start.height + (end.height - start.height) * progress)
                    guard rect.intersects(visible) else { continue }
                    context.fill(Path(rect), with: .color(.black))
                    if let url = slot.images[from] {
                        drawArtwork(url, in: rect, now: now, context: context)
                    }
                    if !slot.preservesSource(from: from, to: to), slot.images[to] != slot.images[from] {
                        var destination = context
                        destination.opacity = blend
                        destination.drawLayer { layer in
                            layer.fill(Path(rect), with: .color(.black))
                            if let url = slot.images[to] { drawArtwork(url, in: rect, now: now, context: layer) }
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
        .contentShape(Rectangle())
        // This recognizer exists only while the compositor owns scrolling.
        // A recognizer on the permanent ancestor competes with watchOS ScrollView.
        .gesture(DragGesture(minimumDistance: 1)
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { zoom.pan(to: $0.translation.height) }
            .onEnded { _ in if zoom.isPanning { zoom.endPan() } })
        .simultaneousGesture(SpatialTapGesture().onEnded { onTap($0.location) })
        .onChange(of: dragging) { _, active in
            if !active, zoom.isPanning { zoom.endPan() }
        }
        .accessibilityHidden(true)
    }

    private func hasImage(_ url: URL) -> Bool {
        zoom.images[url] != nil || GalleryPreviewStore.shared.slot(for: url).preview != nil
    }

    /// Tiles still decoding draw their low-resolution preview instead of a black
    /// cell; a sharp image that arrives later fades in over it.
    private func drawArtwork(_ url: URL, in rect: CGRect, now: Date, context: GraphicsContext) {
        let sharp = zoom.images[url]
        let opacity = sharp == nil ? 0
            : zoom.imageArrivals[url].map { GalleryLowResFade.opacity(elapsed: now.timeIntervalSince($0)) } ?? 1
        if opacity < 1, let lowRes = GalleryPreviewStore.shared.slot(for: url).preview?.image {
            draw(lowRes, in: rect, context: context)
        }
        if let sharp, opacity > 0 {
            var faded = context
            faded.opacity *= opacity
            draw(sharp, in: rect, context: faded)
        }
    }

    private func draw(_ bitmap: CGImage, in rect: CGRect, context: GraphicsContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = max(rect.width / CGFloat(bitmap.width), rect.height / CGFloat(bitmap.height))
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.draw(Image(decorative: bitmap, scale: 1), in: CGRect(
            x: rect.midX - CGFloat(bitmap.width) * scale / 2,
            y: rect.midY - CGFloat(bitmap.height) * scale / 2,
            width: CGFloat(bitmap.width) * scale, height: CGFloat(bitmap.height) * scale))
    }
}
