import CoreGraphics
import Foundation

/// Ink of part of the canvas, for whole-canvas operations (blur baking, transparency
/// clipping) that only look at a stroke's surroundings: their float buffers then cover
/// that part instead of the paper, which on a 2048 px canvas at 4 px per point would be
/// 256 MiB each.
nonisolated extension WatchBitmapRenderer {
    /// Pixels one such operation may render at once; larger areas lower its resolution.
    /// 2048 × 2048: what a whole 1024 px canvas already cost at 4 px per point.
    static let regionOperationPixelBudget: CGFloat = 2048 * 2048

    /// `resolution`, lowered so that `area` (canvas points) fits the pixel budget.
    static func affordableResolution(_ resolution: CGFloat, for area: CGRect) -> CGFloat {
        guard !area.isNull, area.width > 0, area.height > 0 else { return resolution }
        let fitting = (regionOperationPixelBudget / (area.width * area.height)).squareRoot()
        return min(resolution, max(0.5, fitting))
    }

    /// Canvas origin and size of a region covering whole `pixels` of the raster at
    /// `scale`; slightly under the pixel count so `ceil(size × scale)` adds no column.
    static func regionGeometry(pixels: CGRect, scale: CGFloat) -> (origin: CGPoint, size: CGSize) {
        (CGPoint(x: pixels.minX / scale, y: pixels.minY / scale),
         CGSize(width: (pixels.width - 0.001) / scale, height: (pixels.height - 0.001) / scale))
    }

    /// Canvas points beyond a region that blur strokes among `strokes` read: three box
    /// passes reach about 1.75 radii, the feather 0.15 widths; chained blurs add up.
    static func blurMargin(of strokes: [Stroke]) -> CGFloat {
        strokes.reduce(0) { margin, stroke in
            guard stroke.style.instrument == .blur else { return margin }
            return margin + CGFloat(stroke.style.effectiveBlurRadius) * 1.75 + CGFloat(stroke.style.width) * 0.2 + 2
        }
    }

    /// The full-canvas ink of `strokes` cropped to `pixels`: rendered over `pixels` plus
    /// their blur margin, so blur near the edge reads what it reads on the full canvas.
    static func regionInkImage(strokes: [Stroke], pixels: CGRect, paper: CGSize, scale: CGFloat) -> CGImage? {
        let paperPixels = CGRect(x: 0, y: 0, width: ceil(paper.width * scale), height: ceil(paper.height * scale))
        let margin = ceil(blurMargin(of: strokes) * scale)
        let rendered = pixels.insetBy(dx: -margin, dy: -margin).intersection(paperPixels)
        guard !rendered.isNull, !rendered.isEmpty, rendered.contains(pixels) else { return nil }
        let region = regionGeometry(pixels: rendered, scale: scale)
        guard let image = renderInk(strokes: strokes, size: region.size, scale: scale, origin: region.origin)?.image,
              image.width == Int(rendered.width), image.height == Int(rendered.height) else { return nil }
        if rendered == pixels { return image }
        return image.cropping(to: pixels.offsetBy(dx: -rendered.minX, dy: -rendered.minY))
    }
}
