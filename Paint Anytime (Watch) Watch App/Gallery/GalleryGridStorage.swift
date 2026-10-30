import SwiftUI

/// Scroll snapshots are consumed by gestures and handoff tasks, not by body.
/// Updating them must not invalidate the whole gallery on every scroll frame.
@MainActor
final class GalleryGridStorage {
    private(set) var frames: [URL: CGRect] = [:]
    var bitmaps: [URL: GalleryBitmap] = [:]
    var focusedDrawing: CanvasExport?
    private var visibilityByURL: [URL: GalleryThumbnailVisibility] = [:]

    func visibility(for url: URL) -> GalleryThumbnailVisibility {
        if let existing = visibilityByURL[url] { return existing }
        let value = GalleryThumbnailVisibility()
        visibilityByURL[url] = value
        return value
    }

    func update(frames: [URL: CGRect], viewport: CGSize) {
        self.frames = frames
        let retainedArea = CGRect(origin: .zero, size: viewport)
            .insetBy(dx: -viewport.width, dy: -viewport.height * 2)
        for (url, visibility) in visibilityByURL {
            let nearby = frames[url]?.intersects(retainedArea) == true
            if visibility.isNearViewport != nearby {
                visibility.isNearViewport = nearby
            }
            if !nearby {
                bitmaps.removeValue(forKey: url)
                visibility.fallback = nil
            }
        }
    }

    func retain(urls: Set<URL>) {
        frames = frames.filter { urls.contains($0.key) }
        bitmaps = bitmaps.filter { urls.contains($0.key) }
        visibilityByURL = visibilityByURL.filter { urls.contains($0.key) }
    }

    func clearBitmaps() {
        bitmaps.removeAll()
        for visibility in visibilityByURL.values { visibility.fallback = nil }
    }
}
