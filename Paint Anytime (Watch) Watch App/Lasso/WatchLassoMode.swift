import Foundation

nonisolated enum WatchLassoMode: CaseIterable, Hashable, Sendable {
    /// `sketchAssist` selects whole strokes and sends them to Image Playground on the iPhone.
    case area, strokes, sketchAssist

    var title: String {
        switch self {
        case .area: "Select area"
        case .strokes: "Select whole strokes"
        case .sketchAssist: "Complete strokes with Image Playground"
        }
    }

    var symbol: String {
        switch self {
        case .area: "square.dashed"
        case .strokes: "scribble"
        case .sketchAssist: "sparkles"
        }
    }
}
