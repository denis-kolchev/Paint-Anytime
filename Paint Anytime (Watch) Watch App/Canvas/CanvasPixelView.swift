import CoreGraphics
import SwiftUI

/// Pixel view: when zoomed in, the canvas shows the drawing's own pixels (the grid it
/// is saved at) as sharp squares instead of re-rendering finer detail than the saved
/// image has. App-wide, not part of the document.
enum CanvasPixelView {
    static let storageKey = "canvas.pixelView"

    /// Pixels per canvas point of the saved drawing: exports use the screen scale.
    /// On the tile ladder (√2 steps), so tiles of this scale sit on the saved grid.
    static func gridScale(displayScale: CGFloat) -> CGFloat {
        RegionTiling.ladderScale(max(1, displayScale))
    }
}

extension Image {
    /// Nearest-neighbour magnification for rasters on the saved pixel grid; others keep
    /// the default smoothing (lower-resolution fallbacks would show false blocks).
    func pixelGrid(_ isOnGrid: Bool) -> Image {
        isOnGrid ? interpolation(.none) : self
    }
}
