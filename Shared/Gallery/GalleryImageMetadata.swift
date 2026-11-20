import CoreGraphics
import Foundation
import ImageIO

/// Reads a drawing's canvas size from its PNG description, falling back to pixels / scale.
nonisolated enum GalleryImageMetadata {
    static func originalSize(properties: [CFString: Any], pixelWidth: Double,
                              pixelHeight: Double, scale: CGFloat) -> CGSize {
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
           let description = png[kCGImagePropertyPNGDescription] as? String,
           let data = description.data(using: .utf8),
           let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let width = metadata["canvasWidthPoints"] as? NSNumber,
           let height = metadata["canvasHeightPoints"] as? NSNumber,
           width.doubleValue.isFinite, height.doubleValue.isFinite,
           width.doubleValue > 0, height.doubleValue > 0 {
            return CGSize(width: width.doubleValue, height: height.doubleValue)
        }
        let pixelsPerPoint = Double(max(1, scale))
        return CGSize(width: pixelWidth / pixelsPerPoint, height: pixelHeight / pixelsPerPoint)
    }
}
