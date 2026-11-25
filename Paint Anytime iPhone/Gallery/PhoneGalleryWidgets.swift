import Foundation
import os

/// Keeps the Home Screen widgets' previews in the App Group in step with the gallery.
enum PhoneGalleryWidgets {
    private static let queue = DispatchQueue(label: "PaintAnytime.phoneGalleryWidgets", qos: .utility)
    /// A refresh waits to start on `queue`; requests made meanwhile join it.
    private static let refreshQueued = OSAllocatedUnfairLock(initialState: false)

    /// Re-encodes only new or re-saved drawings (a stat per file), off the main thread.
    /// The gallery refreshes often, so requests made while one waits are merged.
    static func refresh() {
        let schedules = refreshQueued.withLock { queued -> Bool in
            guard !queued else { return false }
            queued = true
            return true
        }
        guard schedules else { return }
        queue.async {
            refreshQueued.withLock { $0 = false }
            autoreleasepool {
                do {
                    let store = IncomingDrawingStore()
                    let favorites = try store.favoriteNames()
                    let drawings = try store.pendingImages()
                        .sorted { $0.lastPathComponent > $1.lastPathComponent }
                        .map { (url: $0, isFavorite: favorites.contains($0.lastPathComponent)) }
                    try GalleryWidgetStore.publish(drawings)
                } catch {
                    NSLog("Widget refresh failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
