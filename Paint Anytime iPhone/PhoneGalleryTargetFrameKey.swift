import SwiftUI

/// Actual focal tile geometry after the lazy grid has materialized its row.
struct PhoneGalleryTargetFrameKey: PreferenceKey {
    static var defaultValue: PhoneGalleryLayout? { nil }

    static func reduce(value: inout PhoneGalleryLayout?, nextValue: () -> PhoneGalleryLayout?) {
        if let next = nextValue() { value = next }
    }
}
