import Foundation
import simd

struct PointerSample: Codable, Equatable {
    var position: SIMD2<Float>
    var pressure: Float
    var timestamp: TimeInterval
}

enum DrawingInstrument: Int, CaseIterable, Codable {
    // Preserve the raw values of the original monoline and fountain pen.
    case monoline = 0, fountainPen = 1, pen, marker, pencil, crayon, reed, watercolor, eraser

    static var displayOrder: [Self] {
        let order: [Self] = [.monoline, .pen, .marker, .pencil, .crayon, .fountainPen, .reed, .watercolor, .eraser]
        return order.filter { AppReleaseFeatures.current.allows($0) }
    }

    var title: String {
        switch self {
        case .monoline: L10n.text("Monoline")
        case .pen: L10n.text("Pen")
        case .marker: L10n.text("Marker")
        case .pencil: L10n.text("Pencil")
        case .crayon: L10n.text("Crayon")
        case .fountainPen: L10n.text("Fountain pen")
        case .reed: L10n.text("Reed pen")
        case .watercolor: L10n.text("Watercolor")
        case .eraser: L10n.text("Eraser")
        }
    }

    var defaultWidth: Float {
        switch self {
        case .monoline, .pen: 4
        case .fountainPen: 6
        case .pencil: 3
        case .marker, .eraser: 12
        case .crayon, .reed: 8
        case .watercolor: 16
        }
    }

    var maximumWidth: Float { 80 }

}

enum EraserMode: Int, Codable, CaseIterable {
    case pixels, objects
    var title: String { self == .pixels ? L10n.text("Pixel eraser") : L10n.text("Object eraser") }
}

struct PencilStyle: Codable, Equatable {
    var instrument: DrawingInstrument = .monoline
    var color = SIMD4<Float>(0, 0, 0, 1)
    var width: Float = 4
    var eraserMode: EraserMode = .pixels
    // Degrees in canvas coordinates; the default preserves the previous nib angle.
    var reedAngle: Float = -45

    init() {}

    private enum CodingKeys: String, CodingKey {
        case instrument, color, width, eraserMode, reedAngle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        instrument = try values.decodeIfPresent(DrawingInstrument.self, forKey: .instrument) ?? .monoline
        color = try values.decodeIfPresent(SIMD4<Float>.self, forKey: .color) ?? SIMD4(0, 0, 0, 1)
        width = try values.decodeIfPresent(Float.self, forKey: .width) ?? instrument.defaultWidth
        eraserMode = try values.decodeIfPresent(EraserMode.self, forKey: .eraserMode) ?? .pixels
        let angle = try values.decodeIfPresent(Float.self, forKey: .reedAngle) ?? -45
        reedAngle = angle.isFinite ? min(90, max(-90, angle)) : -45
    }

    static func initial(for instrument: DrawingInstrument) -> Self {
        var style = Self()
        style.instrument = instrument
        style.width = instrument.defaultWidth
        if instrument == .marker { style.color = SIMD4(1, 0.8, 0.1, 1) }
        return style
    }
}

struct Stroke: Codable, Equatable {
    var points: [PointerSample]
    let style: PencilStyle
}

struct CanvasDocument: Codable, Equatable {
    var strokes: [Stroke] = []
}
