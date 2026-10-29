import SwiftUI
import Observation

/// Only the animated overlay reads these per-frame values in its body.
@MainActor
@Observable
final class PhoneGalleryZoomPresentation {
    var scale: CGFloat = 1
    // Continuous across density boundaries: 0 = five, 1 = three, 2 = one.
    // Geometry and image selection must derive from this same rendered value.
    var position: CGFloat = 0
    var elasticAnchor: CGPoint = .zero

    static func position(for columns: Int) -> CGFloat {
        columns == 1 ? 2 : (columns == 3 ? 1 : 0)
    }
    var offsetY: CGFloat = 0
}
