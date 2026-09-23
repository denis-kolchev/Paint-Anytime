import Foundation

extension DrawingInstrument {
    var helpDescription: String {
        switch self {
        case .monoline: L10n.text("Draws a smooth line with a constant width.")
        case .pen: L10n.text("Draw slowly for thicker lines and quickly for thinner lines.")
        case .marker: L10n.text("Creates translucent strokes. Overlapping strokes darken the color.")
        case .pencil: L10n.text("Creates a light, finely textured line.")
        case .crayon: L10n.text("Creates a grainy stroke with a denser texture than the pencil.")
        case .fountainPen: L10n.text("A rounded calligraphy nib varies line width with stroke direction.")
        case .reed: L10n.text("A flat calligraphy nib creates sharp edges. Adjust its angle on the Angle page.")
        case .watercolor: L10n.text("Creates soft, translucent strokes. Layer strokes to deepen the color.")
        case .eraser: L10n.text("Removes marks. Choose Pixel eraser or Object eraser on the Mode page.")
        }
    }
}

extension EraserMode {
    var helpDescription: String {
        switch self {
        case .pixels: L10n.text("Erases only the parts you touch. Width sets the size of the erased area.")
        case .objects: L10n.text("Removes each entire stroke you touch, even if you touch only part of it.")
        }
    }
}
