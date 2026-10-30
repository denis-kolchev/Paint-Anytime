import Foundation
import CoreGraphics

/// A spatial slot, not a moving photo identity. Both platforms blend its content.
struct GalleryZoomSlot: Identifiable {
    let id: Int
    let frames: [Int: CGRect]
    let images: [Int: URL]
    let columns: [Int: Int]

    func preservesSource(from: Int, to: Int) -> Bool {
        guard let source = columns[from], let destination = columns[to] else { return false }
        return (0..<from).contains(source) && !(0..<to).contains(destination)
    }
}
