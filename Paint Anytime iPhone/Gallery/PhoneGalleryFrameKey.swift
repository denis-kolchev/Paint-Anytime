import SwiftUI

/// Grid bounds and the column count that actually produced this layout.
struct PhoneGalleryFrameKey: PreferenceKey {
    static var defaultValue: PhoneGalleryLayout { PhoneGalleryLayout(columns: 0, frame: .zero) }

    static func reduce(value: inout PhoneGalleryLayout, nextValue: () -> PhoneGalleryLayout) {
        let next = nextValue()
        if next.columns > 0 { value = next }
    }
}
