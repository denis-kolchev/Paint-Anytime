import SwiftUI

/// The phone's slot compositor, using CGImage on watch instead of UIKit images.
struct GalleryGridZoomOverlay: View {
    let zoom: GalleryGridZoom
    @GestureState private var dragging = false

    var body: some View {
        let bounded = min(2, max(0, zoom.position))
        let scale = 1 + zoom.position - bounded
        let from = bounded <= 1 ? 5 : 3
        let to = bounded <= 1 ? 3 : 1
        let progress = bounded <= 1 ? bounded : bounded - 1
        let blend = Double(progress * progress * (3 - 2 * progress))
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
                              let image = zoom.images[url] else { continue }
                        let copy = rect.offsetBy(dx: CGFloat(direction) * (zoom.viewport.width + GalleryZoomRules.spacing), dy: 0)
                        if copy.intersects(visible) { draw(image, in: copy, context: context) }
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
                if let url = slot.images[from], let image = zoom.images[url] {
                    draw(image, in: rect, context: context)
                }
                if !slot.preservesSource(from: from, to: to), slot.images[to] != slot.images[from] {
                    var destination = context
                    destination.opacity = blend
                    destination.drawLayer { layer in
                        layer.fill(Path(rect), with: .color(.black))
                        if let url = slot.images[to], let image = zoom.images[url] { draw(image, in: rect, context: layer) }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        // This recognizer exists only while the compositor owns scrolling.
        // A recognizer on the permanent ancestor competes with watchOS ScrollView.
        .gesture(DragGesture(minimumDistance: 1)
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { zoom.pan(to: $0.translation.height) }
            .onEnded { _ in if zoom.isPanning { zoom.endPan() } })
        .onChange(of: dragging) { _, active in
            if !active, zoom.isPanning { zoom.endPan() }
        }
        .accessibilityHidden(true)
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
