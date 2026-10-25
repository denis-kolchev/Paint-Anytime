import SwiftUI
import WatchKit

struct InkPaletteEditor: View {
    @Binding var palette: InkPalette
    @ObservedObject var controller: CanvasController
    @ObservedObject var tutorial = TutorialSession.inactive
    let onBrowse: () -> Void
    let onEdit: () -> Void
    @Binding var isEditing: Bool
    @State private var showsEyedropper = false
    @Binding var sampledColor: SIMD4<Float>?
    @Binding var showsColorEditor: Bool
    @State private var draggedID: String?
    @State private var dragOffset = CGSize.zero
    @State private var dragOrder: [String] = []
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var dragTargetID: String?
    @State private var previewOffsets: [String: CGSize] = [:]
    @GestureState private var isDragging = false
    @State private var swatchFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(palette.displayTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(palette.allColors) { preset in
                            swatch(preset, viewportSize: viewport.size)
                        }
                        Button(action: createColor) {
                            Image(systemName: "plus.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.gray)
                                .aspectRatio(1, contentMode: .fit)
                                .tutorialHint(tutorial, steps: [.addPaletteColor])
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Create color"))
                        .disabled(!tutorial.permits([.addPaletteColor]))
                        Button(action: openEyedropper) {
                            Image(systemName: "eyedropper")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.gray)
                                .scaleEffect(0.8)
                                .aspectRatio(1, contentMode: .fit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Eyedropper"))
                        .disabled(tutorial.isActive)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .coordinateSpace(name: "paletteGrid")
                .onPreferenceChange(PaletteSwatchFramesKey.self) { swatchFrames = $0 }
                .background {
                    // Only empty space owns this gesture. Keeping it off the
                    // grid's ancestor excludes the plus and eyedropper buttons.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                if !isEditing { onEdit() }
                            },
                            including: tutorial.isActive || isEditing ? .none : .all)
                }
                .accessibilityAction(named: Text(L10n.text("Edit"))) { onEdit() }
            }
            .scrollDisabled(draggedID != nil)
            }
            .coordinateSpace(name: "paletteViewport")
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging { resetDrag() }
        }
        .onChange(of: isEditing) { _, _ in resetDrag() }
        .onDisappear { resetDrag() }
        .toolbar {
            if !isEditing && (!tutorial.isActive || tutorial.step == .openPalettes) {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onBrowse) {
                        Image(systemName: "paintpalette.fill")
                            .tutorialHint(tutorial, steps: [.openPalettes])
                    }
                    .accessibilityLabel(L10n.text("Palettes"))
                    .disabled(!tutorial.permits([.openPalettes]))
                }
            }
        }
        .fullScreenCover(isPresented: $showsEyedropper, onDismiss: {
            if sampledColor != nil { showsColorEditor = true }
        }) {
            PaletteEyedropperView(controller: controller, onCancel: {
                sampledColor = nil
                showsColorEditor = false
                showsEyedropper = false
            }) { color in
                sampledColor = color
                showsEyedropper = false
            }
        }
    }

    private func createColor() {
        guard tutorial.permits([.addPaletteColor]) else { return }
        sampledColor = nil
        showsColorEditor = true
        tutorial.record(.openedColorEditor)
    }

    private func openEyedropper() {
        guard !tutorial.isActive else { return }
        sampledColor = nil
        showsEyedropper = true
    }

    private func swatch(_ preset: InkPreset, viewportSize: CGSize) -> some View {
        let selected = palette.selectedIDs.contains(preset.id)
        return Button {
            guard !tutorial.isActive else { return }
            if isEditing {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    palette.delete(preset.id)
                }
                return
            }
            if selected {
                guard palette.selectedIDs.count > 1 else { return }
                palette.selectedIDs.removeAll { $0 == preset.id }
            } else {
                palette.selectedIDs.append(preset.id)
            }
        } label: {
            PaletteSwatchLabel(preset: preset, selected: selected)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isEditing {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        palette.delete(preset.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .gray)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: -5, y: -5)
                .accessibilityLabel(L10n.text("Delete") + " " + preset.name)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PaletteSwatchFramesKey.self,
                    value: [preset.id: geometry.frame(in: .named("paletteGrid"))])
            }
        }
        .modifier(PaletteEditingWiggle(
            enabled: isEditing && !showsColorEditor && draggedID == nil,
            viewportSize: viewportSize))
        // Animate slot changes independently of immediate finger tracking.
        .offset(previewOffsets[preset.id] ?? .zero)
        .animation(reorderAnimation, value: previewOffsets[preset.id] ?? .zero)
        .offset(draggedID == preset.id ? dragOffset : .zero)
        .scaleEffect(draggedID == preset.id && !reduceMotion ? 1.08 : 1)
        .zIndex(draggedID == preset.id ? 1 : 0)
        .highPriorityGesture(swatchDrag(preset.id), including: isEditing ? .all : .subviews)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in onEdit() },
            including: isEditing || tutorial.isActive ? .subviews : .all)
        .accessibilityAction(named: Text(L10n.text("Edit"))) { onEdit() }
        .accessibilityLabel(isEditing ? L10n.text("Delete") + " " + preset.name : preset.name)
        // Block tutorial interaction without the disabled button's dimming.
        .allowsHitTesting(!tutorial.isActive)
        .accessibilityValue(isEditing ? "" : L10n.text(selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(!isEditing && selected ? [.isSelected] : [])
    }

    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)
    }

    private func swatchDrag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("paletteGrid"))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard isEditing else { return }
                if draggedID == nil {
                    draggedID = id
                    WKInterfaceDevice.current().play(.click)
                    dragOrder = palette.allColors.map(\.id)
                    // Fixed slots prevent moving neighbours from changing the drop
                    // target underneath a stationary finger during their animation.
                    dragFrames = swatchFrames
                    dragTargetID = id
                }
                guard draggedID == id else { return }
                dragOffset = value.translation
                updateDragTarget(at: value.location, id: id)
            }
            .onEnded { value in
                guard isEditing, draggedID == id else { resetDrag(); return }
                updateDragTarget(at: value.location, id: id)
                // Animate the release as well: the held swatch settles into its
                // slot while neighbours finish moving to their final positions.
                withAnimation(reorderAnimation) {
                    if let target = dragTargetID { palette.move(id, to: target) }
                    resetDrag()
                }
            }
    }

    private func updateDragTarget(at location: CGPoint, id: String) {
        guard let target = dragOrder.first(where: { dragFrames[$0]?.contains(location) == true }),
              target != dragTargetID,
              let from = dragOrder.firstIndex(of: id),
              let to = dragOrder.firstIndex(of: target) else { return }
        var reordered = dragOrder
        reordered.remove(at: from)
        reordered.insert(id, at: to)
        var offsets: [String: CGSize] = [:]
        for (index, colorID) in reordered.enumerated() where colorID != id {
            guard let origin = dragFrames[colorID], let destination = dragFrames[dragOrder[index]] else { continue }
            offsets[colorID] = CGSize(width: destination.midX - origin.midX,
                                      height: destination.midY - origin.midY)
        }
        withAnimation(reorderAnimation) {
            previewOffsets = offsets
            dragTargetID = target
        }
    }

    private func resetDrag() {
        draggedID = nil
        dragOffset = .zero
        dragOrder = []
        dragFrames = [:]
        dragTargetID = nil
        previewOffsets = [:]
    }

}

private struct PaletteSwatchLabel: View {
    let preset: InkPreset
    let selected: Bool

    var body: some View {
        Circle()
            .fill(selected ? Color.clear : preset.color)
            .overlay {
                if selected {
                    Circle().strokeBorder(preset.color, lineWidth: 5)
                    Circle().inset(by: 4).strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    PaletteSelectionCheckmark(color: preset.color)
                }
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Circle())
    }
}

private struct PaletteSelectionCheckmark: View {
    let color: Color

    private var outlineMask: some View {
        ZStack {
            ForEach(0..<8) { index in
                let angle: Double = Double(index) * Double.pi / 4.0
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
            }
        }
    }

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(color)
            .background {
                // Match the ring: white at 20% over the swatch color.
                Rectangle()
                    .fill(color)
                    .overlay { Color.white.opacity(0.2) }
                    .padding(-1)
                    .mask(outlineMask)
                    .accessibilityHidden(true)
            }
    }
}

/// Visibility is measured before rotation, so animation never triggers layout updates.
private struct PaletteEditingWiggle: ViewModifier {
    let enabled: Bool
    let viewportSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    private var animates: Bool {
        enabled && isVisible && !reduceMotion && scenePhase == .active
    }

    func body(content: Content) -> some View {
        // Derive motion from time instead of retaining a repeating animation in
        // lazy cells, which may disappear while editing is being switched off.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { timeline in
            let phase = animates ? sin(timeline.date.timeIntervalSinceReferenceDate * .pi / 0.14) : 0
            content
                .rotationEffect(.degrees(phase * 2))
                .offset(x: phase * 0.5)
                // Only timeline ticks are immediate. Do not disable the
                // transaction for position changes while the timeline is paused.
                .animation(nil, value: phase)
        }
        .background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("paletteViewport"))
                let visible = frame.intersects(CGRect(origin: .zero, size: viewportSize))
                Color.clear
                    .onAppear { isVisible = visible }
                    .onChange(of: visible) { _, value in isVisible = value }
            }
        }
        .onDisappear { isVisible = false }
    }
}

private struct PaletteSwatchFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
