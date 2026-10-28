import UIKit
import ImageIO

/// Shared, decoded preview pyramid for the resting grid and pinch overlay.
@MainActor
final class PhoneGalleryPreviewCache {
    let id = UUID()
    static let sizes = [320, 640, 1600]
    private let images: [Int: NSCache<NSString, UIImage>]
    private var displayed: [UUID: (url: URL, image: UIImage)] = [:]
    private var pending: [String: Task<UIImage?, Never>] = [:]
    private let decoder = Decoder()

    init() {
        // Separate budgets keep full-width previews from evicting every small tile.
        images = Dictionary(uniqueKeysWithValues: zip(Self.sizes, [8, 16, 40]).map { size, megabytes in
            let cache = NSCache<NSString, UIImage>()
            cache.totalCostLimit = megabytes * 1024 * 1024
            return (size, cache)
        })
    }

    static func size(for pixelSide: CGFloat) -> Int {
        sizes.first { CGFloat($0) >= pixelSide } ?? sizes[sizes.count - 1]
    }

    func image(for url: URL, maximumSize: Int) -> UIImage? {
        images[maximumSize]?.object(forKey: url.absoluteString as NSString)
    }

    func availableImage(for url: URL, maximumSize: Int) -> UIImage? {
        if let exact = image(for: url, maximumSize: maximumSize) { return exact }
        // A live tile can still display an image evicted from NSCache. Share
        // that same instance with the new overlay instead of decoding it again.
        if let retained = displayed.values.first(where: { $0.url == url }) {
            return retained.image
        }
        // Keep a prepared image on screen while the requested tier is missing.
        for size in Self.sizes where size > maximumSize {
            if let image = image(for: url, maximumSize: size) { return image }
        }
        for size in Self.sizes.reversed() where size < maximumSize {
            if let image = image(for: url, maximumSize: size) { return image }
        }
        return nil
    }

    func retainDisplayed(_ image: UIImage, for url: URL, owner: UUID) {
        displayed[owner] = (url, image)
    }

    func releaseDisplayed(owner: UUID) {
        displayed[owner] = nil
    }

    func load(_ url: URL, maximumSize: Int) async -> UIImage? {
        guard !Task.isCancelled, let cache = images[maximumSize] else { return nil }
        if let image = image(for: url, maximumSize: maximumSize) { return image }
        let key = "\(url.absoluteString)|\(maximumSize)"
        if let task = pending[key] { return await task.value }

        // Cache-owned work is shared: one disappearing tile must not cancel
        // another tile's request. A serial decoder bounds the in-flight memory.
        let decoder = decoder
        let task = Task { @MainActor in
            guard let decoded = await decoder.decode(url, maximumSize: maximumSize),
                  !Task.isCancelled else { return Optional<UIImage>.none }
            let image = UIImage(cgImage: decoded)
            cache.setObject(image, forKey: url.absoluteString as NSString,
                            cost: decoded.bytesPerRow * decoded.height)
            return image
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        return image
    }

    func prepareOtherSizes(for url: URL, excluding maximumSize: Int) async {
        for size in Self.sizes where size != maximumSize {
            guard !Task.isCancelled else { return }
            _ = await load(url, maximumSize: size)
        }
    }

    func invalidate() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        displayed.removeAll()
        for cache in images.values { cache.removeAllObjects() }
    }

    /// ImageIO runs off the main actor, one decode at a time, including prewarming.
    private actor Decoder {
        func decode(_ url: URL, maximumSize: Int) -> CGImage? {
            guard !Task.isCancelled else { return nil }
            return autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumSize
                ] as CFDictionary)
            }
        }
    }
}
