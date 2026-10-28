import SwiftUI

/// Immutable correspondence and geometry captured at the start of a pinch.
struct PhoneGalleryZoomSlot: Identifiable {
    let id: Int
    let origin: CGPoint
    let scaleOffset: CGSize
    let images: [Int: URL]
    let columns: [Int: Int]

    func preservesSource(from: Int, to: Int) -> Bool {
        guard let source = columns[from], let destination = columns[to] else { return false }
        return (source == 0 || source == from - 1) && !(0..<to).contains(destination)
    }
}
