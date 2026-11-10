import ImageIO
import SwiftUI
import UIKit

@MainActor
struct DrawingPreview: View {
    let url: URL
    let maximumSize: Int
    var fillsFrame = false
    var cache: PhoneGalleryPreviewCache? = nil
    var preparesOtherSizes = false
    var isTransitionDestination = false
    var frozenPreview: UIImage? = nil
    var viewportSize: CGSize? = nil
    @State private var previewOwner = UUID()
    @State private var preview: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = frozenPreview ?? cache?.image(for: url, maximumSize: maximumSize)
                ?? preview ?? cache?.availableImage(for: url, maximumSize: maximumSize) {
                if let viewportSize {
                    // Use the same dimensions as the tile's clip. A fixed inner
                    // frame also prevents an oversized aspect-fill image from
                    // changing the ZStack's layout and centering during a pinch.
                    let scale = max(viewportSize.width / max(image.size.width, 1),
                                    viewportSize.height / max(image.size.height, 1))
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                        .background {
                            if isTransitionDestination { Color(uiColor: .systemBackground) }
                        }
                        .clipped()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                        .background {
                            if isTransitionDestination { Color(uiColor: .systemBackground) }
                        }
                }
            }
            else if isTransitionDestination { Color.clear }
            else if failed { Label("Preview unavailable", systemImage: "photo") }
            else { ProgressView() }
        }
        .onAppear {
            if let cache, let image = frozenPreview ?? cache.availableImage(for: url, maximumSize: maximumSize) ?? preview {
                preview = image
                cache.retainDisplayed(image, for: url, owner: previewOwner)
            }
        }
        .onDisappear { cache?.releaseDisplayed(owner: previewOwner) }
        .task(id: "\(url.absoluteString)|\(maximumSize)|\(cache?.id.uuidString ?? "detail")|\(preparesOtherSizes)") {
            failed = false
            if let frozenPreview {
                preview = frozenPreview
                cache?.retainDisplayed(frozenPreview, for: url, owner: previewOwner)
                return
            }
            if let cache {
                let image = await cache.load(url, maximumSize: maximumSize)
                guard !Task.isCancelled else { return }
                if let image {
                    cache.retainDisplayed(image, for: url, owner: previewOwner)
                    preview = image
                }
                failed = image == nil
                if preparesOtherSizes, image != nil {
                    await cache.prepareOtherSizes(for: url, excluding: maximumSize)
                }
                return
            }
            let sourceURL = url
            let size = maximumSize
            let image = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return Optional<CGImage>.none }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: size
                ] as CFDictionary)
            }.value
            if !Task.isCancelled {
                if let image { preview = UIImage(cgImage: image) }
                else { failed = true }
            }
        }
    }
}
