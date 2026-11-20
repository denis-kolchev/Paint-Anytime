import Foundation

/// Watch-only bridges between the shared low-res previews and `GalleryBitmap`.
extension GalleryPreview {
    nonisolated func bitmap(for url: URL) -> GalleryBitmap {
        GalleryBitmap(request: GalleryImageRequest(url: url, shortSidePixels: GalleryPreviewDisk.shortSide,
                                                   displayScale: 1),
                      image: image, originalSize: originalSize)
    }
}

extension GalleryPreviewSlot {
    /// A stable bitmap identity, so views comparing bitmaps do not see a new one per render.
    func bitmap(for url: URL) -> GalleryBitmap? {
        guard let preview else { return nil }
        if let cached = derivedImage as? GalleryBitmap, cached.url == url, cached.image === preview.image {
            return cached
        }
        let bitmap = preview.bitmap(for: url)
        derivedImage = bitmap
        return bitmap
    }
}

extension GalleryPreviewStore {
    func record(_ bitmap: GalleryBitmap) {
        record(image: bitmap.image, originalSize: bitmap.originalSize, for: bitmap.url)
    }
}
