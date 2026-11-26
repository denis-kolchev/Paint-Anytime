import CoreGraphics
import SwiftUI

/// How the zoomed-in canvas is drawn. Smooth re-renders strokes finer than the saved
/// image; Pixels shows the saved image's own pixels (the grid it is exported at) as
/// sharp squares; Auto is smooth until a pixel covers `autoPixelSide` screen pixels.
/// App-wide, not part of the document.
enum CanvasPixelView {
    enum Mode: String, CaseIterable {
        case smooth, auto, pixels

        var title: String {
            switch self {
            case .smooth: L10n.text("Smooth")
            case .auto: L10n.text("Auto")
            case .pixels: L10n.text("Pixels")
            }
        }

        var detail: String {
            switch self {
            case .smooth: L10n.text("Edges stay smooth at any zoom.")
            case .auto: L10n.text("Smooth, until pixels get large enough to see.")
            case .pixels: L10n.text("When zoomed in, shows the drawing's pixels as squares.")
            }
        }
    }

    static let storageKey = "canvas.pixelViewMode"

    /// Auto switches once one saved pixel spans this many screen pixels per side: below
    /// it nearest-neighbour edges only look jagged, above it the squares read as pixels.
    static let autoPixelSide: CGFloat = 4

    /// Pixels per canvas point of the saved drawing: exports use the screen scale.
    /// On the tile ladder (√2 steps), so tiles of this scale sit on the saved grid.
    static func gridScale(displayScale: CGFloat) -> CGFloat {
        RegionTiling.ladderScale(max(1, displayScale))
    }

    /// The saved grid's scale when pixels show at `screenScale` (screen pixels per
    /// canvas point), nil for smooth rendering.
    static func activeGridScale(_ mode: Mode, displayScale: CGFloat, screenScale: CGFloat) -> CGFloat? {
        let grid = gridScale(displayScale: displayScale)
        switch mode {
        case .smooth: return nil
        case .pixels: return grid
        case .auto: return screenScale >= grid * autoPixelSide - 0.001 ? grid : nil
        }
    }
}

extension Image {
    /// Nearest-neighbour magnification for rasters on the saved pixel grid; others keep
    /// the default smoothing (lower-resolution fallbacks would show false blocks).
    func pixelGrid(_ isOnGrid: Bool) -> Image {
        isOnGrid ? interpolation(.none) : self
    }
}
