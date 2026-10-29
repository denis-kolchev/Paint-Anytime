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
        // The pair always runs from the denser grid to the enlarged grid,
        // including when the gesture plays it in reverse. Columns outside the
        // enlarged grid keep their images as they move offscreen or back in.
        return (0..<from).contains(source) && !(0..<to).contains(destination)
    }
}
