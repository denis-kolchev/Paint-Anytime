import Foundation
import simd

nonisolated struct PointerSample: Codable, Equatable {
    var position: SIMD2<Float>
    var pressure: Float
    var timestamp: TimeInterval
}

nonisolated enum DrawingInstrument: Int, CaseIterable, Codable {
    // Preserve the raw values of the original monoline and fountain pen.
    case monoline = 0, fountainPen = 1, pen, marker, pencil, crayon, reed, watercolor, eraser, fill

    @MainActor static var displayOrder: [Self] {
        let order: [Self] = [.monoline, .pen, .marker, .pencil, .crayon, .fountainPen, .reed, .watercolor, .fill, .eraser]
        return order.filter { AppReleaseFeatures.current.allows($0) }
    }

    @MainActor var title: String {
        switch self {
        case .monoline: L10n.text("Monoline")
        case .pen: L10n.text("Pen")
        case .marker: L10n.text("Marker")
        case .pencil: L10n.text("Pencil")
        case .crayon: L10n.text("Crayon")
        case .fountainPen: L10n.text("Fountain pen")
        case .reed: L10n.text("Reed pen")
        case .watercolor: L10n.text("Watercolor")
        case .fill: L10n.text("Fill")
        case .eraser: L10n.text("Eraser")
        }
    }

    var defaultWidth: Float {
        switch self {
        case .monoline, .pen, .fill: 4
        case .fountainPen: 6
        case .pencil: 3
        case .marker, .eraser: 12
        case .crayon, .reed: 8
        case .watercolor: 16
        }
    }

    var maximumWidth: Float { 80 }

}

nonisolated enum EraserMode: Int, Codable, CaseIterable {
    case pixels, objects
    @MainActor var title: String { self == .pixels ? L10n.text("Pixel eraser") : L10n.text("Object eraser") }
}

nonisolated enum ColorBlendingMode: String, Codable, CaseIterable {
    case hybrid, multiply, normal
    case screen, overlay, softLight, hardLight, darken, lighten
    case colorDodge, colorBurn, add, difference, exclusion

    @MainActor var title: String { L10n.text(referenceName) }

    @MainActor var referenceLabel: String {
        let localized = title
        guard localized != referenceName else { return localized }
        // Isolate English inside right-to-left Arabic/Hebrew text.
        return localized + " · \u{2068}" + referenceName + "\u{2069}"
    }

    /// Explain the visible effect first; editor terminology remains a subtitle.
    @MainActor var effectTitle: String {
        switch self {
        case .hybrid: L10n.text("Color buildup")
        case .multiply: L10n.text("Deepen shadows")
        case .normal: L10n.text("Paint over")
        case .screen: L10n.text("Soft brightening")
        case .overlay: L10n.text("Boost contrast")
        case .softLight: L10n.text("Gentle tinting")
        case .hardLight: L10n.text("Dramatic lighting")
        case .darken: L10n.text("Keep darker tones")
        case .lighten: L10n.text("Keep lighter tones")
        case .colorDodge: L10n.text("Intense glow")
        case .colorBurn: L10n.text("Rich shadows")
        case .add: L10n.text("Add light")
        case .difference: L10n.text("Color inversion")
        case .exclusion: L10n.text("Soft inversion")
        }
    }

    var referenceName: String {
        switch self {
        case .hybrid: "Hybrid"
        case .multiply: "Multiply"
        case .normal: "Normal"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .darken: "Darken"
        case .lighten: "Lighten"
        case .colorDodge: "Color Dodge"
        case .colorBurn: "Color Burn"
        case .add: "Add"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        }
    }

    func multiplyWeight(for instrument: DrawingInstrument) -> Float {
        switch self {
        case .hybrid: instrument == .watercolor ? 0.85 : 0.8
        case .multiply: 1
        default: 0
        }
    }

    /// Display the reference swatch as ink on the app's white canvas backing.
    /// Preserve the original three charts; other modes start with empty ink,
    /// just like WatchBitmapRenderer. White is composited only for display.
    func referenceSwatch(yellowPasses: Int, bluePasses: Int) -> SIMD3<Float> {
        var ink: SIMD4<Float> = usesMultiplyFastPath ? SIMD4(1, 1, 1, 1) : .zero
        for _ in 0..<yellowPasses {
            ink = composite(base: ink, source: SIMD4(1, 0.78, 0.04, 0.8), instrument: .watercolor)
        }
        for _ in 0..<bluePasses {
            ink = composite(base: ink, source: SIMD4(0.04, 0.48, 0.9, 0.8), instrument: .watercolor)
        }
        return SIMD3(ink.x, ink.y, ink.z) + SIMD3(repeating: 1 - ink.w)
    }

    var usesMultiplyFastPath: Bool {
        self == .normal || self == .multiply || self == .hybrid
    }

    /// Separable blend functions, using straight RGB components in [0, 1].
    /// https://www.w3.org/TR/compositing-1/#blending
    /// Add uses clamped channel addition (Linear Dodge).
    func blend(base d: Float, source s: Float, instrument: DrawingInstrument) -> Float {
        switch self {
        case .normal: return s
        case .multiply: return d * s
        case .hybrid:
            let k = multiplyWeight(for: instrument)
            return s * (1 - k + k * d)
        case .screen: return d + s - d * s
        case .overlay: return d <= 0.5 ? 2 * d * s : 1 - 2 * (1 - d) * (1 - s)
        case .hardLight: return s <= 0.5 ? 2 * d * s : 1 - 2 * (1 - d) * (1 - s)
        case .softLight:
            if s <= 0.5 { return d - (1 - 2 * s) * d * (1 - d) }
            let curve = d <= 0.25 ? ((16 * d - 12) * d + 4) * d : sqrt(d)
            return d + (2 * s - 1) * (curve - d)
        case .darken: return min(d, s)
        case .lighten: return max(d, s)
        case .colorDodge:
            if d == 0 { return 0 }
            return s == 1 ? 1 : min(1, d / (1 - s))
        case .colorBurn:
            if d == 1 { return 1 }
            return s == 0 ? 0 : 1 - min(1, (1 - d) / s)
        case .add: return min(1, d + s)
        case .difference: return abs(d - s)
        case .exclusion: return d + s - 2 * d * s
        }
    }

    /// Source-over with blending, preserving premultiplied alpha on clear canvas.
    /// Shared by stroke rendering and the reference charts in the help screen.
    func composite(base: SIMD4<Float>, source: SIMD4<Float>, instrument: DrawingInstrument) -> SIMD4<Float> {
        let a = source.w
        let ad = base.w
        var result = SIMD4<Float>(repeating: 0)
        for channel in 0..<3 {
            let d = ad > 0 ? min(1, max(0, base[channel] / ad)) : 0
            let mixed = blend(base: d, source: source[channel], instrument: instrument)
            result[channel] = (1 - a) * base[channel] + a * ((1 - ad) * source[channel] + ad * mixed)
        }
        result.w = a + ad * (1 - a)
        return result
    }

}

nonisolated struct PencilStyle: Codable, Equatable {
    var instrument: DrawingInstrument = .monoline
    var color = SIMD4<Float>(0, 0, 0, 1)
    var width: Float = 4
    var opacity: Float = 1

    var effectiveOpacity: Float {
        instrument == .eraser ? 1 : (opacity.isFinite ? min(1, max(0, opacity)) : 1)
    }
    var eraserMode: EraserMode = .pixels
    var blendingMode: ColorBlendingMode = .hybrid
    // Degrees in canvas coordinates; the default preserves the previous nib angle.
    var reedAngle: Float = -45

    init() {}

    private enum CodingKeys: String, CodingKey {
        case instrument, color, width, opacity, eraserMode, reedAngle, blendingMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        instrument = try values.decodeIfPresent(DrawingInstrument.self, forKey: .instrument) ?? .monoline
        color = try values.decodeIfPresent(SIMD4<Float>.self, forKey: .color) ?? SIMD4(0, 0, 0, 1)
        width = try values.decodeIfPresent(Float.self, forKey: .width) ?? instrument.defaultWidth
        let decodedOpacity = try values.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        opacity = decodedOpacity.isFinite ? min(1, max(0, decodedOpacity)) : 1
        eraserMode = try values.decodeIfPresent(EraserMode.self, forKey: .eraserMode) ?? .pixels
        blendingMode = (try values.decodeIfPresent(String.self, forKey: .blendingMode))
            .flatMap(ColorBlendingMode.init(rawValue:)) ?? .hybrid
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

nonisolated struct Stroke: Codable, Equatable, Identifiable {
    let id: UUID
    // A copied stroke can still be edited; invalidate geometry without comparing points.
    private(set) var geometryRevision: UUID = UUID()
    private(set) var inputStream: UUID?
    var points: [PointerSample] {
        didSet { geometryRevision = UUID(); inputStream = nil }
    }

    mutating func beginInputStream() { inputStream = UUID() }

    mutating func appendInputSample(_ sample: PointerSample) {
        let stream = inputStream
        points.append(sample)
        inputStream = stream
    }

    func extends(_ previous: Stroke) -> Bool {
        guard id == previous.id, style == previous.style, points.count >= previous.points.count else { return false }
        if let inputStream, inputStream == previous.inputStream {
            return previous.points.last == (previous.points.isEmpty ? nil : points[previous.points.count - 1])
        }
        return points.starts(with: previous.points)
    }
    let style: PencilStyle
    var locksTransparency = false
    // Horizontal filled rectangles in canvas coordinates; independent of brush width.
    var fillRects: [SIMD4<Float>]? {
        didSet { geometryRevision = UUID() }
    }

    init(points: [PointerSample], style: PencilStyle, id: UUID = UUID()) {
        self.id = id
        self.points = points
        self.style = style
    }

    private enum CodingKeys: String, CodingKey { case id, points, style, locksTransparency, fillRects }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older drawings have no IDs. Assign once, then persist on the next save.
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fillRects = try values.decodeIfPresent([SIMD4<Float>].self, forKey: .fillRects)
        points = try values.decode([PointerSample].self, forKey: .points)
        style = try values.decode(PencilStyle.self, forKey: .style)
        locksTransparency = try values.decodeIfPresent(Bool.self, forKey: .locksTransparency) ?? false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fillRects == rhs.fillRects && lhs.id == rhs.id && lhs.points == rhs.points && lhs.style == rhs.style && lhs.locksTransparency == rhs.locksTransparency
    }
}

nonisolated struct CanvasLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Layer 1"
    var strokes: [Stroke] = []
    var isVisible = true
    var opacity: Float = 1
    var locksTransparency = false
}

nonisolated struct CanvasDocument: Codable, Equatable {
    // Stored bottom to top. The paper is always below every drawing layer.
    var layers: [CanvasLayer]
    var canvasSize: CGSize? = nil
    var resolution: Double = 72

    func size(fallback: CGSize) -> CGSize { canvasSize ?? fallback }
    var backgroundColor = SIMD4<Float>(1, 1, 1, 1)
    var strokes: [Stroke] {
        get { layers.flatMap(\.strokes) }
        set {
            if layers.count == 1 { layers[0].strokes = newValue }
            else { layers = [CanvasLayer(strokes: newValue)] }
        }
    }

    init(strokes: [Stroke] = []) { layers = [CanvasLayer(strokes: strokes)] }

    private enum CodingKeys: String, CodingKey { case layers, backgroundColor, strokes, canvasSize, resolution }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try values.decodeIfPresent([CanvasLayer].self, forKey: .layers) {
            layers = decoded
        } else {
            layers = [CanvasLayer(strokes: try values.decodeIfPresent([Stroke].self, forKey: .strokes) ?? [])]
        }
        canvasSize = try values.decodeIfPresent(CGSize.self, forKey: .canvasSize)
        if let size = canvasSize, !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 || size.width > 2048 || size.height > 2048 { canvasSize = nil }
        resolution = try values.decodeIfPresent(Double.self, forKey: .resolution) ?? 72
        if !resolution.isFinite || resolution <= 0 { resolution = 72 }
        if layers.isEmpty { layers = [CanvasLayer()] }
        backgroundColor = try values.decodeIfPresent(SIMD4<Float>.self, forKey: .backgroundColor) ?? SIMD4(1, 1, 1, 1)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(canvasSize, forKey: .canvasSize)
        try values.encode(resolution, forKey: .resolution)
        try values.encode(layers, forKey: .layers)
        try values.encode(backgroundColor, forKey: .backgroundColor)
    }
}
