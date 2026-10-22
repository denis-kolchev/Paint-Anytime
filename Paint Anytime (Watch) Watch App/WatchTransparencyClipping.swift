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
        var alpha: CGImage?
        for stroke in strokes {
            try Task.checkCancellation()
            defer { preceding.append(stroke) }
            guard stroke.locksTransparency, stroke.style.instrument != .eraser else {
                result.append(stroke)
                alpha = nil
                continue
            }
            if alpha == nil {
                alpha = WatchBitmapRenderer.layerThumbnail(strokes: preceding, size: size, scale: resolution)
            }
            var ink = stroke
            ink.locksTransparency = false
            guard let alpha,
                  let image = WatchBitmapRenderer.layerThumbnail(strokes: [ink], size: size, scale: resolution),
                  image.width == alpha.width, image.height == alpha.height else {
                throw ClippingError.rendering
            }
            let paper = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let bounds = try WatchBitmapRenderer.StrokeGeometry(stroke).bounds
                .applying(CGAffineTransform(scaleX: resolution, y: resolution)).integral
                .intersection(paper)
            // Retain even an invisible stroke's identity without letting off-paper
            // tails reappear later when the object is translated onto the paper.
            let region = bounds.isNull || bounds.isEmpty
                ? CGRect(x: 0, y: 0, width: 1, height: 1) : bounds
            guard let croppedInk = image.cropping(to: region),
                  let croppedAlpha = alpha.cropping(to: region),
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
                CGAffineTransform(scaleX: 1 / resolution, y: 1 / resolution)))
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
