import SwiftUI
import os

nonisolated extension WatchBitmapRenderer {
    /// Highest resolution of the sharp viewport overlay; the full-canvas layer caches
    /// stay at `maximumRasterScale` or lower (see `LayerCache.inkByteLimit`).
    static let maximumDetailScale: CGFloat = 8
    /// Padded fragment size in pixels; one float context of it is ~24 MB. Rendering
    /// holds about three (layer ink, eraser mask, brush coverage), so it also stays
    /// within a quarter of the memory this device has left right now.
    static var detailPixelLimit: CGFloat {
        let ceiling: CGFloat = 1_500_000
        #if targetEnvironment(simulator)
        // The Simulator enforces no per-app limit and reports 0.
        return ceiling
        #else
        // On a watch 0 means the limit is already reached: keep the minimum.
        let available = CGFloat(os_proc_available_memory())
        return min(ceiling, max(250_000, available / 4 / (3 * 16)))
        #endif
    }

    struct ViewportDetail {
        let image: CGImage
        /// Canvas points covered by `image`, on whole pixels of `scale`.
        let rect: CGRect
        let scale: CGFloat
    }

    /// Renders only the visible part of the canvas, without layer caches.
    ///
    /// Brush geometry, grain and eraser masks follow each stroke's transform, so
    /// shifting every stroke by a whole number of pixels reproduces the full-canvas
    /// raster inside the fragment. The padding lets blur sample beyond the visible
    /// edge as it would on the full canvas; it is cropped off afterwards.
    static func renderDetail(document: CanvasDocument, visible: CGRect, paperSize: CGSize,
                             scale requested: CGFloat) -> ViewportDetail? {
        let paper = CGRect(origin: .zero, size: paperSize)
        let visible = visible.intersection(paper)
        guard !visible.isNull, !visible.isEmpty, requested.isFinite, requested > 0 else { return nil }
        let blurReach = document.layers.lazy.flatMap(\.strokes)
            .filter { $0.style.instrument == .blur }
            .map { CGFloat($0.style.effectiveBlurRadius) * 1.75 }
            .max() ?? 0
        let padded = visible.insetBy(dx: -(2 + blurReach), dy: -(2 + blurReach)).intersection(paper)
        let scale = min(requested, (detailPixelLimit / (padded.width * padded.height)).squareRoot())
        guard scale.isFinite, scale > 0 else { return nil }
        // Whole pixels, on the same grid as the full canvas at this scale.
        let minX = floor(padded.minX * scale), minY = floor(padded.minY * scale)
        let maxX = ceil(padded.maxX * scale), maxY = ceil(padded.maxY * scale)
        guard maxX > minX, maxY > minY else { return nil }
        let shift = CGAffineTransform(translationX: -minX / scale, y: -minY / scale)
        var shifted = document
        shifted.layers = document.layers.map { layer in
            var layer = layer
            layer.strokes = layer.strokes.map { stroke in
                var stroke = stroke
                stroke.transform = StrokeTransform(stroke.transform.affine.concatenating(shift))
                return stroke
            }
            return layer
        }
        // Slightly under the pixel count, so `ceil(size * scale)` cannot add a column.
        let size = CGSize(width: (maxX - minX - 0.001) / scale, height: (maxY - minY - 0.001) / scale)
        guard !Task.isCancelled,
              let image = render(document: shifted, size: size, scale: scale), !Task.isCancelled
        else { return nil }
        // Image rows run down from the canvas top, like canvas points.
        let cropMinX = floor(visible.minX * scale), cropMinY = floor(visible.minY * scale)
        let crop = CGRect(x: cropMinX - minX, y: cropMinY - minY,
                          width: ceil(visible.maxX * scale) - cropMinX,
                          height: ceil(visible.maxY * scale) - cropMinY)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, let cropped = image.cropping(to: crop) else { return nil }
        return ViewportDetail(image: cropped,
                              rect: CGRect(x: (minX + crop.minX) / scale, y: (minY + crop.minY) / scale,
                                           width: crop.width / scale, height: crop.height / scale),
                              scale: scale)
    }
}

/// Sharp overlay for the visible part of a zoomed canvas, in paper coordinates.
///
/// The full-canvas raster keeps every layer cached, so its resolution is capped by
/// memory. Once zoom and pan settle, this renders just the visible area at up to
/// ×8 in the background. It hides while a stroke or lasso is live and after any
/// document change, until a fragment of the current revision is ready.
struct WatchViewportDetailView: View {
    let document: CanvasDocument
    let documentID: ObjectIdentifier
    let documentRevision: UInt64
    /// Visible canvas rectangle in canvas points.
    let visible: CGRect
    let paperSize: CGSize
    /// Resolution the current zoom would use without memory limits.
    let scale: CGFloat
    /// Resolution of the full-canvas raster below.
    let baseScale: CGFloat
    let isEnabled: Bool

    private struct Request: Equatable {
        let documentID: ObjectIdentifier
        let revision: UInt64
        let visible: CGRect
        let paperSize: CGSize
        let scale: CGFloat
    }

    @State private var detail: (request: Request, value: WatchBitmapRenderer.ViewportDetail)?

    private var wantedScale: CGFloat {
        // Quarter steps, so Crown detents do not restart rendering for tiny changes.
        (min(WatchBitmapRenderer.maximumDetailScale, scale) * 4).rounded(.down) / 4
    }

    private var request: Request? {
        guard isEnabled, wantedScale > baseScale + 0.01 else { return nil }
        return Request(documentID: documentID, revision: documentRevision,
                       visible: visible.intersection(CGRect(origin: .zero, size: paperSize)),
                       paperSize: paperSize, scale: wantedScale)
    }

    private func isCurrent(_ entry: (request: Request, value: WatchBitmapRenderer.ViewportDetail)) -> Bool {
        isEnabled && entry.request.documentID == documentID && entry.request.revision == documentRevision
            && entry.request.paperSize == paperSize && entry.value.scale > baseScale + 0.01
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let detail, isCurrent(detail) {
                Image(decorative: detail.value.image, scale: 1)
                    .resizable()
                    .frame(width: detail.value.rect.width, height: detail.value.rect.height)
                    .offset(x: detail.value.rect.minX, y: detail.value.rect.minY)
            }
        }
        .frame(width: paperSize.width, height: paperSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            guard let request, !request.visible.isNull, !request.visible.isEmpty else { return }
            // A fragment of this revision already covers the view at this resolution.
            if let detail, isCurrent(detail), detail.value.scale >= request.scale - 0.01,
               detail.value.rect.insetBy(dx: -0.5, dy: -0.5).contains(request.visible) { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let document = self.document
            let work = Task.detached(priority: .userInitiated) {
                WatchBitmapRenderer.renderDetail(document: document, visible: request.visible,
                                                 paperSize: request.paperSize, scale: request.scale)
            }
            let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let value else { return }
            detail = (request, value)
        }
    }
}
