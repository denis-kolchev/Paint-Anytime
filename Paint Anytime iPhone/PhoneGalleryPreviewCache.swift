import UIKit
import ImageIO

/// Shared by the resting grid and gesture overlay, including newly created slots.
@MainActor
final class PhoneGalleryPreviewCache {
    let id = UUID()
    private let images = NSCache<NSString, UIImage>()
    private var pending: [String: Task<UIImage?, Never>] = [:]

    init() {
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL, maximumSize: Int) -> UIImage? {
        images.object(forKey: key(url, maximumSize) as NSString)
    }

    func load(_ url: URL, maximumSize: Int) async -> UIImage? {
        let key = key(url, maximumSize)
        if let image = images.object(forKey: key as NSString) { return image }
        if let task = pending[key] { return await task.value }

        // Owned by the cache: removing one tile must not cancel another tile's load.
        let task = Task { @MainActor in
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return Optional<CGImage>.none
                }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumSize
                ] as CFDictionary)
            }.value
            guard let decoded else { return Optional<UIImage>.none }
            let image = UIImage(cgImage: decoded)
            images.setObject(image, forKey: key as NSString,
                             cost: decoded.bytesPerRow * decoded.height)
            return image
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        return image
    }

    private func key(_ url: URL, _ maximumSize: Int) -> String {
        "\(url.absoluteString)|\(maximumSize)"
    }
}
