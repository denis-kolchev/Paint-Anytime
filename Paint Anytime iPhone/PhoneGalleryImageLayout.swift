import Foundation
import CoreGraphics
import ImageIO

/// Original proportions and prefix heights, captured when the inbox changes.
/// No file reads or image decoding are needed during a zoom gesture.
struct PhoneGalleryImageLayout {
    private var ratios: [URL: CGFloat] = [:]
    private var prefixHeights: [CGFloat] = [0]

    init(images: [URL] = []) {
        for url in images {
            let ratio: CGFloat = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.doubleValue > 0, height.doubleValue > 0 else { return 1 }
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                let rotated = (5...8).contains(orientation)
                return CGFloat(rotated ? width.doubleValue / height.doubleValue
                    : height.doubleValue / width.doubleValue)
            }
            ratios[url] = ratio
            prefixHeights.append((prefixHeights.last ?? 0) + ratio)
        }
    }

    func height(for url: URL, width: CGFloat) -> CGFloat {
        width * (ratios[url] ?? 1)
    }

    /// Extrapolate empty rows outside the collection as squares for the overlay.
    func top(at index: Int, width: CGFloat, spacing: CGFloat) -> CGFloat {
        let count = prefixHeights.count - 1
        let bounded = min(count, max(0, index))
        return (prefixHeights[bounded] + CGFloat(index - bounded)) * width + CGFloat(index) * spacing
    }
}
