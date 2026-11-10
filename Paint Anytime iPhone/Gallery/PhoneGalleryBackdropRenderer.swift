import UIKit

/// Serial rasterization away from the main actor. Inputs are immutable snapshots;
/// the renderer never accesses SwiftUI state or the preview cache.
actor PhoneGalleryBackdropRenderer {
    static let shared = PhoneGalleryBackdropRenderer()

    struct Tile {
        let image: UIImage
        let rect: CGRect
    }

    func render(tiles: [Int: [Tile]], size: CGSize, scale: CGFloat,
                background: UIColor) -> [Int: UIImage]? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            var images: [Int: UIImage] = [:]
            for direction in [-1, 1] {
                guard !Task.isCancelled else { return nil }
                images[direction] = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                    background.setFill()
                    renderer.fill(CGRect(origin: .zero, size: size))
                    for tile in tiles[direction] ?? [] {
                        guard !Task.isCancelled else { return }
                        let image = tile.image
                        let rect = tile.rect
                        let imageScale = max(rect.width / image.size.width, rect.height / image.size.height)
                        let imageSize = CGSize(width: image.size.width * imageScale,
                                               height: image.size.height * imageScale)
                        renderer.cgContext.saveGState()
                        renderer.cgContext.clip(to: rect)
                        image.draw(in: CGRect(x: rect.midX - imageSize.width / 2,
                                              y: rect.midY - imageSize.height / 2,
                                              width: imageSize.width, height: imageSize.height))
                        renderer.cgContext.restoreGState()
                    }
                }
            }
            return Task.isCancelled ? nil : images
        }
    }
}
