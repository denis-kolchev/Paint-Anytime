import SwiftUI

// The native toolbar retains its hit region even for transparent content.
// Handle that region explicitly using the canvas's current coordinate mapping.
final class WatchLassoToolbarInput {
    struct Mapping: Equatable {
        let frame: CGRect
        let paperSize: CGSize
        let offset: CGSize
        let zoomScale: CGFloat
        let rasterScale: CGFloat
        let enabled: Bool

        func point(_ global: CGPoint) -> CGPoint {
            CGPoint(x: (global.x - frame.midX - offset.width) / zoomScale + paperSize.width / 2,
                    y: (global.y - frame.midY - offset.height) / zoomScale + paperSize.height / 2)
        }
    }
    var mapping: Mapping?
}
