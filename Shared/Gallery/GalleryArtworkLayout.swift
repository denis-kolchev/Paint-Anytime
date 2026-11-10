import Foundation
import CoreGraphics

nonisolated enum GalleryArtworkLayout {
    static func frame(imageSize: CGSize, viewport: CGSize, fitsViewport: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              viewport.width.isFinite, viewport.height.isFinite else { return .zero }
        let scale = fitsViewport
            ? min(viewport.width / imageSize.width, viewport.height / imageSize.height) : 1
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2,
                      y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
