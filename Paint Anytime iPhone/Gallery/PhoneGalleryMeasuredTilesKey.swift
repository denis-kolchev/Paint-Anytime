import SwiftUI

struct PhoneGalleryMeasuredTilesKey: PreferenceKey {
    static var defaultValue: [URL: PhoneGalleryLayout] { [:] }

    static func reduce(value: inout [URL: PhoneGalleryLayout],
                       nextValue: () -> [URL: PhoneGalleryLayout]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
