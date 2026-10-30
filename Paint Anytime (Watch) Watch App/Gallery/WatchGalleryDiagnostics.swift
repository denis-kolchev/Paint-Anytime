#if DEBUG
import SwiftUI

/// Non-observable counters: recording an event must not invalidate the gallery.
@MainActor
final class WatchGalleryDiagnostics {
    static let shared = WatchGalleryDiagnostics()
    private(set) var geometryUpdates = 0
    private(set) var geometryMS = 0.0
    private(set) var loads = 0
    private(set) var cancellations = 0
    private(set) var pending = 0
    private(set) var visible = 0
    private(set) var missing = 0
    private(set) var measured = 0
    private(set) var heldMB = 0.0
    private(set) var mode = "grid"
    private var lastDetails = -Double.infinity

    func geometry(elapsedMS: Double, frames: [URL: CGRect], viewport: CGSize,
                  bitmaps: [URL: GalleryBitmap], columns: Int, zooming: Bool) {
        guard GalleryDebug.isEnabled else { return }
        geometryUpdates += 1
        geometryMS += elapsedMS
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDetails >= 0.5 else { return }
        lastDetails = now
        let bounds = CGRect(origin: .zero, size: viewport)
        var visibleCount = 0, missingCount = 0
        for (url, frame) in frames where frame.intersects(bounds) {
            visibleCount += 1
            if bitmaps[url] == nil { missingCount += 1 }
        }
        visible = visibleCount
        missing = missingCount
        measured = frames.count
        heldMB = Double(bitmaps.values.reduce(0) { $0 + $1.memoryCost }) / 1_048_576
        mode = zooming ? "zoom" : "\(columns)col"
    }

    func beganLoad() {
        guard GalleryDebug.isEnabled else { return }
        loads += 1
        pending += 1
    }

    func endedLoad(cancelled: Bool) {
        guard GalleryDebug.isEnabled else { return }
        pending = max(0, pending - 1)
        if cancelled { cancellations += 1 }
    }
}
#endif
