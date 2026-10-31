import Foundation

/// Only the five replaceable positions are stored. More is never configurable.
struct CanvasControlLayout: Codable, Equatable {
    static let storageKey = "watch.canvasControlLayout.v1"
    static let enabledKey = "watch.canvasControlLayout.enabled"
    var version = 1
    var slots: [CanvasControlAssignment]

    static let standard = CanvasControlLayout(slots: [
        .single(.brush), .group([.clear, .save, .lasso]),
        .single(.undo), .single(.redo), .single(.layers)
    ])

    static func decode(_ data: Data) -> CanvasControlLayout? {
        guard let layout = try? JSONDecoder().decode(Self.self, from: data),
              layout.version == 1, layout.slots.count == 5,
              layout.slots.allSatisfy({ $0.isValid }) else { return nil }
        return layout
    }
}

struct CanvasControlAssignment: Codable, Equatable {
    var isMorph: Bool
    var actions: [CanvasQuickAction]

    static func single(_ action: CanvasQuickAction) -> Self {
        Self(isMorph: false, actions: [action])
    }

    static func group(_ actions: [CanvasQuickAction]) -> Self {
        Self(isMorph: true, actions: actions)
    }

    var isValid: Bool {
        (isMorph ? (1...4).contains(actions.count) : actions.count == 1)
            && Set(actions).count == actions.count
    }
}

/// Stable identifiers are independent of translated display names.
enum CanvasQuickAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case brush, clear, save, lasso, undo, redo, layers, gallery, language, tutorial
    case canvasSize, toolSynchronization, visiblePalettes, blending, privacy, reportBug
    case eyedropper, camera, palettes

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
        }
    }
}
