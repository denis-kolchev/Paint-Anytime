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
                    }
                    .buttonStyle(.plain)
                    .disabled(!assignment.isMorph && !enabled(assignment.actions[0]))
                    .accessibilityLabel(assignment.isMorph ? "Morph: " + assignment.actions.map { L10n.text($0.title) }.joined(separator: ", ") : L10n.text(assignment.actions[0].title))
                }
                .frame(width: diameter)
                .modifier(CanvasMorphGlass(adaptsToCanvas: true))
                .trackCanvasControl(.custom(index), frames: frames)
                .position(x: anchor.x, y: anchor.y + (Self.isTop(index) ? 1 : -1) * (height - diameter) / 2)
                .zIndex(expanded ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func actionButton(_ action: CanvasQuickAction, height: CGFloat) -> some View {
        Button {
            state.customExpandedSlot = nil
            onAction(action)
        } label: {
            CanvasQuickActionIcon(action: action, instrument: controller.pencilStyle.instrument)
                .frame(width: MorphPanelGeometry.buttonDiameter, height: height)
        }
        .buttonStyle(.plain)
        .disabled(!enabled(action))
        .accessibilityLabel(L10n.text(action.title))
    }

    private func enabled(_ action: CanvasQuickAction) -> Bool {
        switch action {
        case .undo: controller.canUndo
        case .redo: controller.canRedo
        case .clear: controller.canClear
        default: true
        }
    }

    private func position(_ index: Int, geometry: MorphPanelGeometry) -> CGPoint {
        if let frame = regions.toolbarAnchors[Self.anchors[index]], !frame.isEmpty {
            return CGPoint(x: frame.midX - canvasOrigin.x, y: frame.midY - canvasOrigin.y)
        }
        if index == 0 { return CGPoint(x: geometry.trailingX, y: geometry.top + 18) }
        if index == CanvasControlLayout.topLeadingSlot { return CGPoint(x: geometry.leadingX, y: geometry.top + 18) }
        return CGPoint(x: geometry.leadingX + (geometry.trailingX - geometry.leadingX) * CGFloat(index - 1) / 3,
                       y: geometry.bottom - 18)
    }
}

struct CanvasQuickActionIcon: View {
    let action: CanvasQuickAction
    let instrument: DrawingInstrument
    var isMorph = false
    var morphIcon: String? = nil

    var body: some View {
        Group {
            if isMorph { Image(systemName: CanvasMorphIcon.resolve(morphIcon)) }
            else if action == .clear { BroomIcon() }
            else if action == .brush { ToolIcon(instrument: instrument) }
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
                state.customExpandedSlot = nil
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
