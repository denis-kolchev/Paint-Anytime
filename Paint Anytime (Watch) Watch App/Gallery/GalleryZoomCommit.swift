import Foundation
import CoreGraphics

struct GalleryZoomCommit: Identifiable {
    let id = UUID()
    let columns: Int
    let leading: Int
    let target: URL
    let anchorY: CGFloat
    let viewportTop: CGFloat
}
