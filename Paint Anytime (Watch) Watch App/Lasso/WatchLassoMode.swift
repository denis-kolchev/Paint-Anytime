import Foundation

nonisolated enum WatchLassoMode: CaseIterable, Hashable, Sendable {
    case area, strokes

    var title: String { self == .strokes ? "Select whole strokes" : "Select area" }
    var symbol: String { self == .strokes ? "scribble" : "square.dashed" }
}
