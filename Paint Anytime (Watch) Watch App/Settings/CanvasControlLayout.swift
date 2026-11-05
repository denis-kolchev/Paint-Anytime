import Foundation

/// Decodes the stored layout once per distinct value. Views read the layout many
/// times per body evaluation; comparing the small stored Data is far cheaper than
/// JSON decoding. Not observable: it memoizes a value SwiftUI already tracks.
final class CanvasControlLayoutCache {
    private var data: Data?
    private var layout: CanvasControlLayout?

    func layout(for data: Data) -> CanvasControlLayout? {
        if data != self.data {
            self.data = data
            layout = CanvasControlLayout.decode(data)
        }
        return layout
    }
}

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

    /// The built-in canvas: two expandable menus and an empty bottom row.
    /// Saving exactly this restores the built-in controls themselves.
    static let original = CanvasControlLayout(slots: [
        .group([.brush, .undo, .redo], icon: "paintbrush.pointed"),
        .single(.nothing), .single(.nothing), .single(.nothing), .single(.nothing),
        .group([.more, .clear, .save, .lasso, .layers], icon: "doc.badge.gearshape")
    ])

    /// More is the only way into settings, so at least one slot must offer it.
    var containsMore: Bool { slots.contains { $0.actions.contains(.more) } }

    /// Actions the canvas editor never lets the last copy of leave the canvas:
    /// More leads to settings, and Undo and Redo have no other way in.
    /// Only More is enforced on decoding, so layouts saved without Undo still load.
    static let requiredActions: [CanvasQuickAction] = [.more, .undo, .redo]

    /// The custom layout the canvas shows, or nil for the original menus.
    /// A stored layout that no longer decodes also falls back to the menus.
    static func custom(from data: Data, enabled: Bool,
                       decode: (Data) -> CanvasControlLayout? = CanvasControlLayout.decode) -> CanvasControlLayout? {
        enabled ? decode(data) : nil
    }

    /// The layout the canvas shows, with the original menus spelled out as a layout.
    static func current(from data: Data, enabled: Bool) -> CanvasControlLayout {
        custom(from: data, enabled: enabled) ?? .original
    }

    /// Every action placed on the canvas, inside groups included.
    var actions: Set<CanvasQuickAction> { Set(slots.flatMap(\.actions)) }

    /// Everything at hand was retired in 1.2. Keep its always-visible buttons
    /// for people who had it on by turning them into the same custom layout.
    static func migrateEverythingAtHand(_ defaults: UserDefaults = .standard) {
        let key = "experimental.morphToolbar"
        guard let prefersMenus = defaults.object(forKey: key) as? Bool else { return }
        if !prefersMenus && !defaults.bool(forKey: enabledKey),
           let data = try? JSONEncoder().encode(standard) {
            defaults.set(data, forKey: storageKey)
            defaults.set(true, forKey: enabledKey)
        }
        defaults.removeObject(forKey: key)
    }

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
/// can never reference a symbol missing from the watchOS 10 SDK. Symbols of
/// actions a morph can hold are left out, such as the ellipsis of More, the
/// palette, the sparkles of Complete strokes and the pen tip of a tool. Twenty
/// fill the picker's four columns evenly.
enum CanvasMorphIcon {
    static let standard = "square.grid.2x2"
    static let symbols = [
        standard, "paintbrush.pointed", "doc.badge.gearshape", "circle.grid.cross", "plus", "star", "heart",
        "bolt", "wand.and.stars", "scribble", "slider.horizontal.3", "gearshape", "folder", "square.stack",
        "list.bullet", "tray", "wrench.and.screwdriver", "archivebox", "square.on.circle", "bookmark.fill"
    ]

    /// Unknown or retired symbols fall back instead of invalidating the layout.
    static func resolve(_ icon: String?) -> String {
        icon.flatMap { symbols.contains($0) ? $0 : nil } ?? standard
    }
}

/// Stable identifiers are independent of translated display names.
enum CanvasQuickAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case brush, clear, save, lasso, undo, redo, layers, gallery, language, tutorial
    case canvasSize, toolSynchronization, visiblePalettes, blending, reportBug
    case eyedropper, camera, palettes, perspectiveGuides, canvasEditor, autosave, sketchAssist
    case eraserToggle, share, closeMorph, more, nothing

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
        case .reportBug: "Report a bug"
        case .eyedropper: "Eyedropper"
        case .camera: "Free camera"
        case .palettes: "Palettes"
        case .perspectiveGuides: "Perspective guides"
        case .canvasEditor: "Canvas editor"
        case .autosave: "Autosave"
        case .sketchAssist: "Complete strokes"
        case .eraserToggle: "Eraser ↔ tool"
        case .share: "Share"
        case .closeMorph: "Close"
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
        case .reportBug: "envelope"
        case .eyedropper: "eyedropper"
        case .camera: "hand.draw"
        case .perspectiveGuides: "perspective"
        case .canvasEditor: "pencil.and.ellipsis.rectangle"
        case .autosave: "clock.arrow.circlepath"
        case .sketchAssist: "sparkles"
        case .eraserToggle: "eraser"
        case .share: "square.and.arrow.up"
        case .closeMorph: "xmark"
        case .more: "ellipsis"
        case .nothing: "circle.dashed"
        }
    }

    /// Expected use while drawing, most frequent first: drawing tools, then canvas
    /// and file actions, then settings opened once in a while. An estimate, not
    /// measured usage: the app collects no analytics.
    private static let usageOrder: [CanvasQuickAction] = [
        .brush, .undo, .redo, .eraserToggle, .eyedropper, .palettes, .layers, .lasso,
        .save, .clear, .gallery, .share, .sketchAssist, .more, .closeMorph,
        .perspectiveGuides, .canvasSize, .visiblePalettes, .blending, .toolSynchronization,
        .canvasEditor, .autosave, .language, .tutorial, .reportBug
    ]

    /// Actions the editor offers: Nothing first for a single circle, then by expected use.
    /// Close only collapses a morph, so a single circle never offers it.
    static func menuOrder(inMorph: Bool) -> [CanvasQuickAction] {
        // Actions missing from the list still appear, at the end, so none gets lost.
        let ordered = usageOrder + allCases.filter { !usageOrder.contains($0) && $0 != .nothing }
        let offered = ordered.filter { action in
            switch action {
            case .closeMorph: inMorph
            case .sketchAssist: AppReleaseFeatures.current.showsSketchAssist
            // No longer offered; a layout that already holds it keeps working.
            case .camera: false
            default: true
            }
        }
        return (inMorph ? [] : [.nothing]) + offered
    }
}

extension CanvasQuickAction {
    /// Retired actions, such as the Privacy Policy, decode as Nothing so
    /// layouts saved before their removal stay usable.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .nothing
    }
}

extension CanvasControlAssignment {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isMorph = try container.decode(Bool.self, forKey: .isMorph)
        var actions = try container.decode([CanvasQuickAction].self, forKey: .actions)
        let icon = try container.decodeIfPresent(String.self, forKey: .icon)
        if isMorph {
            // A morph drops retired actions; one left with none becomes an empty slot.
            actions.removeAll { $0 == .nothing }
            self = actions.isEmpty ? .single(.nothing) : .group(actions, icon: icon)
        } else {
            self = Self(isMorph: false, actions: actions, icon: icon)
        }
    }
}
