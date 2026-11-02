import Foundation

/// Slots: 0 top right, 1...4 bottom row, 5 top left. Version 1 stored only
/// the first five and kept More fixed at the top left.
struct CanvasControlLayout: Codable, Equatable {
    static let storageKey = "watch.canvasControlLayout.v1"
    static let enabledKey = "watch.canvasControlLayout.enabled"
    static let topLeadingSlot = 5
    var version = 2
    var slots: [CanvasControlAssignment]

    static let standard = CanvasControlLayout(slots: [
        .single(.brush), .group([.clear, .save, .lasso]),
        .single(.undo), .single(.redo), .single(.layers), .single(.more)
    ])

    /// The canvas with Everything at hand off: two expandable menus and an
    /// empty bottom row. Saving exactly this restores that mode itself.
    static let original = CanvasControlLayout(slots: [
        .group([.brush, .undo, .redo], icon: "paintbrush.pointed"),
        .single(.nothing), .single(.nothing), .single(.nothing), .single(.nothing),
        .group([.more, .clear, .save, .lasso, .layers], icon: "doc.badge.gearshape")
    ])

    /// More is the only way into settings, so at least one slot must offer it.
    var containsMore: Bool { slots.contains { $0.actions.contains(.more) } }

    static func decode(_ data: Data) -> CanvasControlLayout? {
        guard var layout = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        if layout.version == 1, layout.slots.count == 5 {
            layout.version = 2
            layout.slots.append(.single(.more))
        }
        guard layout.version == 2, layout.slots.count == 6,
              layout.slots.allSatisfy({ $0.isValid }), layout.containsMore else { return nil }
        return layout
    }
}

struct CanvasControlAssignment: Codable, Equatable {
    var isMorph: Bool
    var actions: [CanvasQuickAction]
    /// Optional so layouts saved before morph icons existed still decode.
    var icon: String? = nil

    static func single(_ action: CanvasQuickAction) -> Self {
        Self(isMorph: false, actions: [action])
    }

    static func group(_ actions: [CanvasQuickAction], icon: String? = nil) -> Self {
        Self(isMorph: true, actions: actions, icon: icon)
    }

    /// An empty slot shows no circle on the canvas.
    var isEmpty: Bool { !isMorph && actions == [.nothing] }

    /// Five matches the built-in canvas actions menu.
    static let maxMorphActions = 5

    var isValid: Bool {
        (isMorph ? (1...Self.maxMorphActions).contains(actions.count) && !actions.contains(.nothing) : actions.count == 1)
            && Set(actions).count == actions.count
    }
}

/// Symbols offered for a morph circle. The list is closed so a stored layout
/// can never reference a symbol missing from the watchOS 10 SDK. The ellipsis
/// is left out: it now marks More.
enum CanvasMorphIcon {
    static let standard = "square.grid.2x2"
    static let symbols = [
        standard, "paintbrush.pointed", "doc.badge.gearshape", "circle.grid.cross", "plus", "star", "heart",
        "bolt", "sparkles", "wand.and.stars", "paintpalette", "scribble", "pencil.tip",
        "slider.horizontal.3", "gearshape", "folder", "square.stack", "list.bullet", "tray"
    ]

    /// Unknown or retired symbols fall back instead of invalidating the layout.
    static func resolve(_ icon: String?) -> String {
        icon.flatMap { symbols.contains($0) ? $0 : nil } ?? standard
    }
}

/// Stable identifiers are independent of translated display names.
enum CanvasQuickAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case brush, clear, save, lasso, undo, redo, layers, gallery, language, tutorial
    case canvasSize, toolSynchronization, visiblePalettes, blending, privacy, reportBug
    case eyedropper, camera, palettes, more, nothing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .brush: "Tool settings"
        case .clear: "Clear canvas"
        case .save: "Save drawing"
        case .lasso: "Lasso"
        case .undo: "Undo"
        case .redo: "Redo"
        case .layers: "Layers"
        case .gallery: "Gallery"
        case .language: "Language"
        case .tutorial: "Tutorial"
        case .canvasSize: "Canvas size"
        case .toolSynchronization: "Tool synchronization"
        case .visiblePalettes: "Visible palettes"
        case .blending: "Color blending"
        case .privacy: "Privacy Policy"
        case .reportBug: "Report a bug"
        case .eyedropper: "Eyedropper"
        case .camera: "Free camera"
        case .palettes: "Palettes"
        case .more: "More"
        case .nothing: "Nothing"
        }
    }

    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .clear: "eraser"
        case .save: "square.and.arrow.down"
        case .lasso: "lasso"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .layers: "square.3.layers.3d"
        case .gallery: "photo.on.rectangle"
        case .language: "globe"
        case .tutorial: "graduationcap"
        case .canvasSize: "arrow.up.left.and.arrow.down.right"
        case .toolSynchronization: "arrow.triangle.2.circlepath"
        case .visiblePalettes, .palettes: "paintpalette"
        case .blending: "circle.lefthalf.filled"
        case .privacy: "hand.raised"
        case .reportBug: "envelope"
        case .eyedropper: "eyedropper"
        case .camera: "hand.draw"
        case .more: "ellipsis"
        case .nothing: "circle.dashed"
        }
    }
}
