import SwiftUI

struct CustomCanvasControls: View {
    let layout: CanvasControlLayout
    let state: CanvasMorphState
    let regions: CanvasControlRegions
    @ObservedObject var controller: CanvasController
    let size: CGSize
    let canvasOrigin: CGPoint
    let onAction: (CanvasQuickAction) -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let anchors: [CanvasToolbarControl] = [.tools, .clear, .undo, .redo, .save, .more]
    /// Fallback bottom-row center, measured from the bottom edge.
    static let bottomRowCenterInset: CGFloat = 38

    /// Top slots expand downwards, the bottom row upwards.
    static func isTop(_ index: Int) -> Bool {
        index == 0 || index == CanvasControlLayout.topLeadingSlot
    }

    private var frames: Binding<[CanvasToolbarControl: CGRect]> {
        Binding(get: { regions.frames }, set: { regions.frames = $0 })
    }

    var body: some View {
        let geometry = MorphPanelGeometry(size: size, layoutDirection: layoutDirection)
        ZStack {
            ForEach(layout.slots.indices.filter { !layout.slots[$0].isEmpty }, id: \.self) { index in
                let assignment = layout.slots[index]
                let expanded = assignment.isMorph && state.customExpandedSlot == index
                let anchor = position(index, geometry: geometry)
                let diameter = geometry.diameter
                let rowHeight = min(diameter, max(24, (size.height - 64) / CGFloat(max(4, assignment.actions.count))))
                let height = expanded ? rowHeight * CGFloat(assignment.actions.count) : diameter
                CanvasMorphContent(isExpanded: expanded) {
                    VStack(spacing: 0) {
                        ForEach(assignment.actions) { action in
                            actionButton(action, height: rowHeight)
                        }
                    }
                } collapsed: {
                    Button {
                        if assignment.isMorph {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                                state.customExpandedSlot = index
                            }
                        } else if let action = assignment.actions.first {
                            onAction(action)
                        }
                    } label: {
                        CanvasQuickActionIcon(action: assignment.actions[0],
                                              instrument: controller.pencilStyle.instrument,
                                              isMorph: assignment.isMorph,
                                              morphIcon: assignment.icon)
                            .frame(width: diameter, height: diameter)
                            // A plain button hit-tests only the glyph; the interactive glass
                            // still animates, so a tap beside the icon looked accepted.
                            // Circle, like the glass: a square's corners took strokes started
                            // beside the button and the canvas never saw them.
                            .contentShape(Circle())
                    }
                    .buttonStyle(CanvasMorphButtonStyle())
                    // Stays enabled: `onAction` answers an unavailable action with a haptic.
                    .environment(\.isCanvasActionUnavailable,
                                 !assignment.isMorph && !assignment.actions[0].isAvailable(in: controller))
                    .accessibilityLabel(assignment.isMorph ? L10n.format("Morph: %@", assignment.actions.map { L10n.text($0.title) }.joined(separator: ", ")) : L10n.text(assignment.actions[0].title))
                }
                .frame(width: diameter)
                .modifier(CanvasMorphGlass(adaptsToCanvas: true, isInteractive: false))
                .trackCanvasControl(.custom(index), frames: frames)
                .position(x: anchor.x, y: anchor.y + (Self.isTop(index) ? 1 : -1) * (height - diameter) / 2)
                .zIndex(expanded ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func actionButton(_ action: CanvasQuickAction, height: CGFloat) -> some View {
        Button {
            // An unavailable action leaves the morph as it is, like the disabled button did.
            guard action.isAvailable(in: controller) else { return UnavailableActionFeedback.play() }
            // Undo, Redo, Tool settings and More keep the morph open; any other option
            // collapses it with the same spring as opening.
            if !action.keepsMorphOpen {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    state.customExpandedSlot = nil
                }
            }
            onAction(action)
        } label: {
            CanvasQuickActionIcon(action: action, instrument: controller.pencilStyle.instrument)
                .frame(width: MorphPanelGeometry.buttonDiameter, height: height)
                // The whole row belongs to its action: rows tile the glass with no gaps.
                .contentShape(Rectangle())
        }
        .buttonStyle(CanvasMorphButtonStyle())
        .environment(\.isCanvasActionUnavailable, !action.isAvailable(in: controller))
        .accessibilityLabel(L10n.text(action.title))
    }

    private func position(_ index: Int, geometry: MorphPanelGeometry) -> CGPoint {
        if let frame = regions.toolbarAnchors[Self.anchors[index]], !frame.isEmpty {
            let point = CGPoint(x: frame.midX - canvasOrigin.x, y: frame.midY - canvasOrigin.y)
            // The canvas hides the native bars for this layout; a hidden bar reports its slots
            // off screen (the bottom row vanished below the edge). Use only on-screen anchors.
            if CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4).contains(point) { return point }
        }
        if index == 0 { return CGPoint(x: geometry.trailingX, y: geometry.top + 18) }
        if index == CanvasControlLayout.topLeadingSlot { return CGPoint(x: geometry.leadingX, y: geometry.top + 18) }
        // Bottom row as the native bottom bar lays it out (Canvas Editor): the outer circles
        // straight below the top ones, equal spacing between, center about 38 pt above the
        // bottom edge on Apple Watch Ultra (from device screenshots).
        let leading = position(CanvasControlLayout.topLeadingSlot, geometry: geometry).x
        let trailing = position(0, geometry: geometry).x
        return CGPoint(x: leading + (trailing - leading) * CGFloat(index - 1) / 3,
                       y: size.height - Self.bottomRowCenterInset)
    }
}

extension CanvasQuickAction {
    /// Undo and Redo are tapped repeatedly, so choosing them leaves the morph open.
    /// Tool settings and More open a screen whose transition a collapse would fight.
    var keepsMorphOpen: Bool { self == .undo || self == .redo || self == .brush || self == .more }

    /// Undo, Redo and Clear have nothing to do on an empty history or canvas.
    func isAvailable(in controller: CanvasController) -> Bool {
        switch self {
        case .undo: controller.canUndo
        case .redo: controller.canRedo
        case .clear: controller.canClear
        default: true
        }
    }
}

struct CanvasQuickActionIcon: View {
    let action: CanvasQuickAction
    @AppStorage(WatchSketchAssist.phoneAvailabilityKey) private var sketchAssistOnPhone = false
    let instrument: DrawingInstrument
    var isMorph = false
    var morphIcon: String? = nil

    var body: some View {
        Group {
            if isMorph { Image(systemName: CanvasMorphIcon.resolve(morphIcon)) }
            else if action == .clear { BroomIcon() }
            // The eraser toggle shows the tool in hand: the eraser while erasing.
            else if action == .brush || action == .eraserToggle { ToolIcon(instrument: instrument) }
            else if action == .canvasEditor { CanvasLayoutIcon() }
            else if action == .palettes { CurrentPaletteIcon() }
            else if action == .sketchAssist {
                Image(systemName: action.symbol).modifier(SketchAssistLock(isLocked: !sketchAssistOnPhone))
            }
            else { Image(systemName: action.symbol) }
        }
        .font(.system(size: 17, weight: .semibold))
    }
}

/// Retains the native toolbar anchor and its touch handling while the glass
/// panel is drawn above the canvas, exactly like the built-in morph controls.
struct CustomCanvasToolbarAnchor: View {
    let index: Int
    let assignment: CanvasControlAssignment
    let state: CanvasMorphState
    let onAction: (CanvasQuickAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if assignment.isMorph && state.customExpandedSlot != index {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    state.customExpandedSlot = index
                }
            } else {
                let action = CustomCanvasControls.isTop(index) ? assignment.actions.first : assignment.actions.last
                if action?.keepsMorphOpen != true {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        state.customExpandedSlot = nil
                    }
                }
                if let action { onAction(action) }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 18, height: 18).opacity(0)
        }
        // Keep an empty slot installed so the clock and other items stay put.
        .disabled(assignment.isEmpty)
        .watchToolbarButtonStyle(diameter: MorphPanelGeometry.buttonDiameter,
                                 usesCanvasMaterial: true, hidesNativeChrome: true)
        .accessibilityHidden(true)
    }
}
