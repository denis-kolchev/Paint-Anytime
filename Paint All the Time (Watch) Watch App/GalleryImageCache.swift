import SwiftUI
import ImageIO

// These values cross from the decoding actor to the UI. CGImage is immutable.
nonisolated struct GalleryImageRequest: Hashable, Sendable {
    let url: URL
    let shortSidePixels: Int?
    let displayScale: CGFloat
}

nonisolated final class GalleryBitmap: @unchecked Sendable {
    let request: GalleryImageRequest
    let image: CGImage
    let originalSize: CGSize
    var url: URL { request.url }
    var memoryCost: Int { image.bytesPerRow * image.height }

    init(request: GalleryImageRequest, image: CGImage, originalSize: CGSize) {
        self.request = request
        self.image = image
        self.originalSize = originalSize
    }
}

nonisolated private final class GalleryThumbnailVariants {
    var images: [GalleryImageRequest: GalleryBitmap] = [:]
    var memoryCost: Int { images.values.reduce(0) { $0 + $1.memoryCost } }
}

// File access, metadata parsing, and decompression run off the main actor.
// A serial actor also coalesces requests: the next caller finds the cached result.
actor GalleryImageCache {
    static let shared = GalleryImageCache()
    private let thumbnails = NSCache<NSURL, GalleryThumbnailVariants>()
    private let originals = NSCache<NSURL, GalleryBitmap>()

    init() {
        thumbnails.totalCostLimit = 6 * 1024 * 1024
        thumbnails.countLimit = 100
        originals.totalCostLimit = 8 * 1024 * 1024
        originals.countLimit = 3
    }

    func load(_ request: GalleryImageRequest) -> GalleryBitmap? {
        guard !Task.isCancelled else { return nil }
        let key = request.url as NSURL
        if request.shortSidePixels != nil {
            if let cached = thumbnails.object(forKey: key)?.images[request] { return cached }
        } else if let cached = originals.object(forKey: key), cached.request == request {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(request.url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }

        let image: CGImage?
        if let side = request.shortSidePixels {
            let longest = max(width.doubleValue, height.doubleValue)
            let shortest = min(width.doubleValue, height.doubleValue)
            // Preserve enough pixels for a square tile using aspect-fill, without upscaling.
            let maximum = Int(min(longest, ceil(Double(max(1, side)) * longest / shortest)))
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image, !Task.isCancelled else { return nil }
        let size = originalSize(properties: properties, pixelWidth: width.doubleValue,
                                pixelHeight: height.doubleValue, scale: request.displayScale)
        let bitmap = GalleryBitmap(request: request, image: image, originalSize: size)
        if request.shortSidePixels != nil {
            let variants = thumbnails.object(forKey: key) ?? GalleryThumbnailVariants()
            variants.images[request] = bitmap
            thumbnails.setObject(variants, forKey: key, cost: variants.memoryCost)
        } else {
            originals.setObject(bitmap, forKey: key, cost: bitmap.memoryCost)
        }
        return bitmap
    }

    func remove(_ url: URL) {
        thumbnails.removeObject(forKey: url as NSURL)
        originals.removeObject(forKey: url as NSURL)
    }

    private func originalSize(properties: [CFString: Any], pixelWidth: Double,
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

struct GalleryThumbnailView: View {
    let request: GalleryImageRequest
    var loadsImage: Bool
    @State private var bitmap: GalleryBitmap?

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.12))
            }
        }
        .task(id: loadsImage ? request : nil) {
            guard loadsImage else { return }
            let loaded = await GalleryImageCache.shared.load(request)
            guard !Task.isCancelled else { return }
            bitmap = loaded
        }
        .onDisappear { bitmap = nil }
    }
}

struct GalleryFullscreenPage: View {
    let url: URL
    let size: CGSize
    let canvasOriginY: CGFloat
    let thumbnailPixels: Int
    let displayScale: CGFloat
    let isNearby: Bool
    let loadsOriginal: Bool
    let fallback: GalleryBitmap?
    @State private var preview: GalleryBitmap?
    @State private var original: GalleryBitmap?

    var body: some View {
        let previewRequest = isNearby
            ? GalleryImageRequest(url: url, shortSidePixels: thumbnailPixels, displayScale: displayScale) : nil
        let originalRequest = loadsOriginal
            ? GalleryImageRequest(url: url, shortSidePixels: nil, displayScale: displayScale) : nil
        GeometryReader { pageGeometry in
            ZStack(alignment: .topLeading) {
                Color.black
                if let bitmap = original ?? preview ?? fallback {
                    Image(decorative: bitmap.image, scale: 1)
                        .resizable()
                        .frame(width: bitmap.originalSize.width, height: bitmap.originalSize.height)
                        .position(x: size.width / 2, y: size.height / 2)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            // TabView can inset its pages independently of the outer safe area.
            // Correct the measured vertical origin, retaining horizontal paging motion.
            .offset(y: canvasOriginY - pageGeometry.frame(in: .global).minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .all)
        .task(id: previewRequest) {
            guard let previewRequest else { preview = nil; return }
            let loaded = await GalleryImageCache.shared.load(previewRequest)
            guard !Task.isCancelled else { return }
            preview = loaded
        }
        .task(id: originalRequest) {
            guard let originalRequest else { original = nil; return }
            let loaded = await GalleryImageCache.shared.load(originalRequest)
            guard !Task.isCancelled else { return }
            original = loaded
        }
        .onDisappear { preview = nil; original = nil }
    }
}
