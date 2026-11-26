import CoreGraphics
import Foundation

/// Crown zoom inside the settled 1:1 photo, about the screen center, up to 8×.
/// The fitted photo is scale 1; the offset is in screen points after scaling.
struct GalleryPhotoZoom: Equatable {
    static let maximumScale: CGFloat = 8
    /// Magnification per two units of Crown travel, close to the grid zoom's feel.
    private static let crownBase: CGFloat = 5

    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero

    var isZoomed: Bool { scale > 1.001 }

    /// Applies a Crown delta (positive zooms in). Returns true when a limit was reached.
    @discardableResult
    mutating func zoom(byCrown delta: Double, imageSize: CGSize, viewport: CGSize) -> Bool {
        let requested = scale * pow(Self.crownBase, CGFloat(delta) / 2)
        let next = min(Self.maximumScale, max(1, requested))
        guard next != scale else { return false }
        // Keep the picture point under the screen center fixed.
        offset = CGSize(width: offset.width * next / scale, height: offset.height * next / scale)
        scale = next
        clamp(imageSize: imageSize, viewport: viewport)
        return next != requested
    }

    mutating func pan(to proposed: CGSize, imageSize: CGSize, viewport: CGSize) {
        offset = proposed
        clamp(imageSize: imageSize, viewport: viewport)
    }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    /// The scaled photo covers the screen where it is larger and stays where it
    /// was fitted where it is smaller.
    private mutating func clamp(imageSize: CGSize, viewport: CGSize) {
        guard scale > 1 else { offset = .zero; return }
        let fitted = GalleryArtworkLayout.frame(imageSize: imageSize, viewport: viewport, fitsViewport: true)
        guard fitted.width > 0, fitted.height > 0 else { offset = .zero; return }
        func axis(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat, length: CGFloat) -> CGFloat {
            let center = length / 2
            let scaledMin = center + (lower - center) * scale
            let scaledMax = center + (upper - center) * scale
            if scaledMax - scaledMin <= length {
                return -((lower + upper) / 2 - center) * (scale - 1)
            }
            return Swift.min(-scaledMin, Swift.max(length - scaledMax, value))
        }
        offset = CGSize(
            width: axis(offset.width, min: fitted.minX, max: fitted.maxX, length: viewport.width),
            height: axis(offset.height, min: fitted.minY, max: fitted.maxY, length: viewport.height))
    }
}
