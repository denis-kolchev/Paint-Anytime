import SwiftUI
import simd
import ImageIO

/// The immutable selection snapshot is shared by all requests in a gesture.
/// Only this small matrix changes while the finger moves.
nonisolated struct WatchSelectionPreview {
    let sessionID: UUID
    let document: CanvasDocument
    let layerID: UUID
    let selectedIDs: Set<UUID>
    let bounds: CGRect
    var transform: CGAffineTransform = .identity
}

/// Geometry is generated once by the brushes and consumed by both rendering paths.
nonisolated struct WatchDrawingCommand {
    enum Shape {
        case fill(Path)
        case stroke(Path, StrokeStyle)
    }
    let shape: Shape
    let rgba: SIMD4<Float>
    let opacity: Double
    let blendMode: GraphicsContext.BlendMode
    let usesOpacityLayer: Bool
    var exclusionPaths: [Path] = []
}

nonisolated struct WatchDrawingContext {
    enum Shading {
        case color(SIMD4<Float>)
    }
    final class Storage {
        var commands: [WatchDrawingCommand] = []
    }
    let storage = Storage()
    var opacity = 1.0
    var blendMode: GraphicsContext.BlendMode = .normal
    var usesOpacityLayer = false

    func fill(_ path: Path, with shading: Shading) {
        append(.fill(path), shading)
    }

    func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        append(.stroke(path, style), shading)
    }

    private func append(_ shape: WatchDrawingCommand.Shape, _ shading: Shading) {
        if case let .color(rgba) = shading {
            storage.commands.append(WatchDrawingCommand(shape: shape, rgba: rgba,
                                                        opacity: opacity, blendMode: blendMode,
                                                        usesOpacityLayer: usesOpacityLayer))
        }
    }
}
