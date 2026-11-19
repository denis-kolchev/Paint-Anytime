import CoreGraphics
import Foundation
import ImageIO

/// Freeze alpha-locked ink before object editing. Store its actual translucent
/// coverage, rather than turning transparent pixels into adjacent vector cuts:
/// antialiasing those cuts separately creates seams when objects are moved.
nonisolated enum WatchTransparencyClipping {
    enum ClippingError: Error { case rendering }

    static func prepare(strokes: [Stroke], size: CGSize, scale: CGFloat) throws -> [Stroke] {
        guard strokes.contains(where: \.locksTransparency) else { return strokes }
        guard size.width > 0, size.height > 0, scale > 0,
              size.width.isFinite, size.height.isFinite, scale.isFinite else {
            throw ClippingError.rendering
        }
        // Preserve smooth edges even when selection starts with the canvas zoomed out.
        let resolution = min(max(scale, WatchBitmapRenderer.maximumRasterScale),
                             8192 / max(size.width, size.height))
        var preceding: [Stroke] = []
        var result: [Stroke] = []
        let paperPoints = CGRect(origin: .zero, size: size)
        for stroke in strokes {
            try Task.checkCancellation()
            defer { preceding.append(stroke) }
            // A blur alone renders nothing; it is baked with the ink it reads afterwards.
            guard stroke.locksTransparency, stroke.style.instrument != .eraser,
                  stroke.style.instrument != .blur else {
                result.append(stroke)
                continue
            }
            var ink = stroke
            ink.locksTransparency = false
            // Only the stroke's own pixels are rendered (ink and the alpha it is locked
            // to), not the paper: on a 2048 px canvas a paper-sized float ink at 4 px per
            // point is 256 MiB. A large stroke gets a lower resolution within the budget.
            let pointBounds = try WatchBitmapRenderer.StrokeGeometry(stroke).bounds.intersection(paperPoints)
            let strokeResolution = WatchBitmapRenderer.affordableResolution(resolution, for: pointBounds)
            let paper = CGRect(x: 0, y: 0, width: ceil(size.width * strokeResolution),
                               height: ceil(size.height * strokeResolution))
            let bounds = pointBounds.isNull ? CGRect.null
                : pointBounds.applying(CGAffineTransform(scaleX: strokeResolution, y: strokeResolution)).integral
                    .intersection(paper)
            // Retain even an invisible stroke's identity without letting off-paper
            // tails reappear later when the object is translated onto the paper.
            let region = bounds.isNull || bounds.isEmpty
                ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
            guard let croppedInk = WatchBitmapRenderer.regionInkImage(strokes: [ink], pixels: region,
                                                                      paper: size, scale: strokeResolution),
                  let croppedAlpha = WatchBitmapRenderer.regionInkImage(strokes: preceding, pixels: region,
                                                                        paper: size, scale: strokeResolution),
                  croppedInk.width == croppedAlpha.width, croppedInk.height == croppedAlpha.height,
                  let pixels = pixelContext(croppedInk), let pixelData = pixels.data,
                  let mask = pixelContext(croppedAlpha), let maskData = mask.data else {
                throw ClippingError.rendering
            }
            let rgba = pixelData.assumingMemoryBound(to: UInt8.self)
            let coverage = maskData.assumingMemoryBound(to: UInt8.self)
            for y in 0..<pixels.height {
                try Task.checkCancellation()
                for x in 0..<pixels.width {
                    let offset = y * pixels.bytesPerRow + x * 4
                    let opacity = bounds.isNull || bounds.isEmpty ? 0
                        : Int(coverage[y * mask.bytesPerRow + x * 4 + 3])
                    // Multiply premultiplied RGB as well as alpha, retaining the
                    // fractional coverage at the boundary instead of a binary cut.
                    for channel in 0..<4 {
                        rgba[offset + channel] = UInt8((Int(rgba[offset + channel]) * opacity + 127) / 255)
                    }
                }
            }
            guard let clippedImage = pixels.makeImage() else { throw ClippingError.rendering }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                throw ClippingError.rendering
            }
            CGImageDestinationAddImage(destination, clippedImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw ClippingError.rendering }
            // The snapshot already includes the old transform, cuts, and erasers.
            // Future object edits apply once to this independent piece of ink.
            ink.transform = .identity
            ink.excludedAreas = []
            ink.erasures = []
            ink.raster = StrokeRaster(png: data as Data, bounds: region.applying(
                CGAffineTransform(scaleX: 1 / strokeResolution, y: 1 / strokeResolution)))
            result.append(ink)
        }
        return result
    }

    private static func pixelContext(_ image: CGImage) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }
}
