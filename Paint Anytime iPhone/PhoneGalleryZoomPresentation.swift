import SwiftUI
import Observation

/// Only the animated overlay reads these per-frame values in its body.
@MainActor
@Observable
final class PhoneGalleryZoomPresentation {
    var scale: CGFloat = 1
    var fromColumns = 5
    var toColumns = 5
    var blend: Double = 0
    var geometryProgress: CGFloat = 0
    var offsetY: CGFloat = 0
}
