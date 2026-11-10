import SwiftUI

/// Latest materialized tile frames; reports do not invalidate the gallery.
final class PhoneGalleryMeasuredTiles {
    var frames: [URL: PhoneGalleryLayout] = [:]
    var updatedAt = ProcessInfo.processInfo.systemUptime
}
