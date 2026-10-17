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

/// Only grid thumbnails receive this decoration; originals and exported files stay untouched.
/// Rasterizing the artwork, blur and heart together gives zoom a single image to animate.
@MainActor
private enum GalleryFavoriteThumbnailRenderer {
    private static let cache: NSCache<NSURL, GalleryThumbnailVariants> = {
        let cache = NSCache<NSURL, GalleryThumbnailVariants>()
        cache.totalCostLimit = 3 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()

    static func render(_ bitmap: GalleryBitmap) -> GalleryBitmap? {
        let request = bitmap.request
        let key = bitmap.url as NSURL
        if let cached = cache.object(forKey: key)?.images[request] { return cached }
        guard let pixels = request.shortSidePixels else { return nil }
        let scale = max(1, request.displayScale)
        let side = CGFloat(pixels) / scale
        let heartSize = side * 0.18
        let inset = side * 0.075
        let cornerSize = side * 0.9
        let artwork = Image(decorative: bitmap.image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipped()
        let content = artwork
            .overlay {
                artwork
                    .blur(radius: 3)
                    .overlay(Color.black.opacity(0.22))
                    .mask {
                        RadialGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.65), location: 0.3),
                            .init(color: .black.opacity(0.2), location: 0.65),
                            .init(color: .clear, location: 1)
                        ], center: .bottomLeading, startRadius: 0, endRadius: cornerSize)
                    }
            }
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "heart.fill")
                    .font(.system(size: heartSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .padding(inset)
            }
            .clipped()
            .environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let result = GalleryBitmap(request: request, image: image, originalSize: bitmap.originalSize)
        let variants = cache.object(forKey: key) ?? GalleryThumbnailVariants()
        variants.images[request] = result
        cache.setObject(variants, forKey: key, cost: variants.memoryCost)
        return result
    }
}

struct GalleryThumbnailView: View {
    let request: GalleryImageRequest
    var loadsImage: Bool
    var isFavorite = false
    @State private var bitmap: GalleryBitmap?

    private struct LoadRequest: Equatable {
        let image: GalleryImageRequest
        let isFavorite: Bool
    }

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.12))
            }
        }
        .task(id: loadsImage ? LoadRequest(image: request, isFavorite: isFavorite) : nil) {
            guard loadsImage else { return }
            let loaded = await GalleryImageCache.shared.load(request)
            guard !Task.isCancelled else { return }
            if isFavorite, let loaded {
                bitmap = GalleryFavoriteThumbnailRenderer.render(loaded) ?? loaded
            } else {
                bitmap = loaded
            }
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
    var respectsSafeArea = false
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
        .ignoresSafeArea(.container, edges: respectsSafeArea ? [] : .all)
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
