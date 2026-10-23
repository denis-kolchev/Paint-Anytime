import SwiftUI
import WatchKit

struct InkPalette: Codable {
    var baseColors: [InkPreset]?
    var title: String?
    var generatedNameID: PaletteNameID?

    var displayTitle: String {
        if allColors.isEmpty { return L10n.text("New palette") }
        if let generatedNameID {
            return PaletteNameGenerator().displayName(generatedNameID)
        }
        return L10n.text(title ?? "Basic colors")
    }
    var customColors: [InkPreset] = []
    var selectedIDs: [String] = InkPreset.all.map(\.id)

    // Optional fields keep palettes saved before editing was introduced readable.
    var orderedIDs: [String]?
    var deletedIDs: [String]?

    init(baseColors: [InkPreset]? = nil, title: String? = nil,
         generatedNameID: PaletteNameID? = nil, customColors: [InkPreset] = [],
         selectedIDs: [String] = InkPreset.all.map(\.id),
         orderedIDs: [String]? = nil, deletedIDs: [String]? = nil) {
        self.baseColors = baseColors
        self.title = title
        self.generatedNameID = generatedNameID
        self.customColors = customColors
        self.selectedIDs = selectedIDs
        self.orderedIDs = orderedIDs
        self.deletedIDs = deletedIDs
    }

    var allColors: [InkPreset] {
        let available = ((baseColors ?? InkPaletteLibrary.basicColors) + customColors).filter { !(deletedIDs ?? []).contains($0.id) }
        let ordered = (orderedIDs ?? []).compactMap { id in available.first { $0.id == id } }
        return ordered + available.filter { !(orderedIDs ?? []).contains($0.id) }
    }

    mutating func delete(_ id: String) {
        guard !allColors.isEmpty else { return }
        deletedIDs = (deletedIDs ?? []) + [id]
        customColors.removeAll { $0.id == id }
        orderedIDs?.removeAll { $0 == id }
        selectedIDs.removeAll { $0 == id }
        if selectedIDs.isEmpty, let first = allColors.first { selectedIDs = [first.id] }
    }

    mutating func move(_ id: String, to target: String) {
        var ids = allColors.map(\.id)
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        orderedIDs = ids
    }
    var selectedColors: [InkPreset] {
        let selected = allColors.filter { selectedIDs.contains($0.id) }
        return selected.isEmpty ? Array(allColors.prefix(1)) : selected
    }

    static func decode(_ data: Data) -> InkPalette {
        guard var palette = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var knownIDs = Set((palette.baseColors ?? InkPaletteLibrary.basicColors).map(\.id))
        palette.customColors = palette.customColors.filter { preset in
            let values = [preset.rgba.x, preset.rgba.y, preset.rgba.z, preset.rgba.w]
            return values.allSatisfy { $0.isFinite && (0...1).contains($0) }
                && knownIDs.insert(preset.id).inserted
        }
        palette.customColors = palette.customColors.map(\.resolvingColorName)
        palette.selectedIDs = palette.selectedColors.map(\.id)
        return palette
    }
}

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

struct CustomInkEditor: View {
    var initialColor: SIMD4<Float>? = nil
    var saveTitle = "Add color"
    var dismissesOnSave = true
    @ObservedObject var tutorial = TutorialSession.inactive
    @State private var acceptsColorChanges = false
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rgb = [128.0, 128.0, 128.0]
    @State private var hsb = [0.0, 0.0, 128.0 / 255 * 100]
    @State private var page = 0
    let onSave: (InkPreset) -> Void

    private var hex: String {
        String(format: "#%02X%02X%02X", Int(rgb[0].rounded()), Int(rgb[1].rounded()), Int(rgb[2].rounded()))
    }
    private var colorName: String { NamedInkColors.name(forHex: hex) ?? hex }

    private var rgbBinding: Binding<[Double]> {
        Binding { rgb } set: { values in
            let changed = values != rgb
            rgb = values
            let r = values[0] / 255, g = values[1] / 255, b = values[2] / 255
            let high = max(r, g, b), low = min(r, g, b), delta = high - low
            // Retain hue for gray and hue/saturation for black so they can be restored.
            if delta > 0 {
                let sector = high == r ? (g - b) / delta : high == g ? (b - r) / delta + 2 : (r - g) / delta + 4
                hsb[0] = (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
            }
            if high > 0 { hsb[1] = delta / high * 100 }
            hsb[2] = high * 100
            if changed && acceptsColorChanges { tutorial.record(.adjustedColor) }
        }
    }
    private var hsbBinding: Binding<[Double]> {
        Binding { hsb } set: { values in
            let changed = values != hsb
            hsb = values
            let h = values[0] / 60, s = values[1] / 100, v = values[2] / 100
            let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
            let components: [Double]
            switch Int(h) % 6 {
            case 0: components = [c, x, 0]
            case 1: components = [x, c, 0]
            case 2: components = [0, c, x]
            case 3: components = [0, x, c]
            case 4: components = [x, 0, c]
            default: components = [c, 0, x]
            }
            rgb = components.map { min(255, max(0, ($0 + m) * 255)) }
            if changed && acceptsColorChanges { tutorial.record(.adjustedColor) }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                // Keep both pages in this exact viewport. A watchOS page-style
                // TabView adds its own safe-area layout and can crop the last row.
                HStack(spacing: 0) {
                    InkComponentsEditor(values: hsbBinding, isHue: true, isActive: page == 0)
                        .environment(\.layoutDirection, layoutDirection)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(page != 0)
                    InkComponentsEditor(values: rgbBinding, isHue: false, isActive: page == 1)
                        .environment(\.layoutDirection, layoutDirection)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityHidden(page != 1)
                }
                .environment(\.layoutDirection, .leftToRight)
                .offset(x: -CGFloat(page) * geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())

            }
            Text(colorName)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
            schemeCarousel
                .frame(height: 24)
        }
        .onAppear {
            if let c = initialColor { rgbBinding.wrappedValue = [Double(c.x) * 255, Double(c.y) * 255, Double(c.z) * 255] }
            acceptsColorChanges = true
        }
        .padding(.bottom, 8)
        // Use the empty space below the clock in tutorial color lessons.
        // Move the editor content together; the native toolbar stays in place.
        .offset(y: tutorial.isActive ? -20 : 0)
        .navigationBarBackButtonHidden(tutorial.isActive)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard tutorial.permits([.savePaletteColor]) else { return }
                    onSave(InkPreset(customID: UUID().uuidString, nameKey: colorName,
                                     rgba: SIMD4(Float(rgb[0] / 255), Float(rgb[1] / 255), Float(rgb[2] / 255), 1)))
                    if dismissesOnSave { dismiss() }
                } label: {
                    Image(systemName: "checkmark")
                        .tutorialHint(tutorial, steps: [.savePaletteColor])
                }
                .watchToolbarButtonStyle(usesCanvasMaterial: tutorial.isActive)
                .opacity(tutorial.permits([.savePaletteColor]) ? 1 : 0)
                .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3),
                           value: tutorial.permits([.savePaletteColor]))
                .disabled(!tutorial.permits([.savePaletteColor]))
                .accessibilityHidden(!tutorial.permits([.savePaletteColor]))
                .accessibilityLabel(L10n.text(saveTitle))
            }
        }
    }

    private var schemeCarousel: some View {
        GeometryReader { geometry in
            let itemWidth: CGFloat = 60
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        schemeButton("HSB", page: 0)
                        schemeButton("RGB", page: 1)
                    }
                    .padding(.horizontal, max(0, (geometry.size.width - itemWidth) / 2))
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(true)
                .onAppear { proxy.scrollTo(page, anchor: .center) }
                .onChange(of: geometry.size.width) { _, _ in
                    proxy.scrollTo(page, anchor: .center)
                }
                .onChange(of: page) { _, target in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            let forward = layoutDirection == .rightToLeft
                ? value.translation.width > 0 : value.translation.width < 0
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                page = min(1, max(0, page + (forward ? 1 : -1)))
            }
        })
    }

    private func schemeButton(_ title: String, page target: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { page = target }
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(page == target ? .primary : .secondary)
                .frame(width: 60, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(page == target ? [.isSelected] : [])
        .id(target)
    }

}

private struct InkComponentsEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var crownFocused: Bool
    @Binding var values: [Double]
    let isHue: Bool
    let isActive: Bool
    @State private var selectedChannel = 0

    private var channels: [String] { isHue ? ["Hue", "Saturation", "Brightness"] : ["Red", "Green", "Blue"] }
    private var channelAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }
    private func maximum(_ index: Int) -> Double { isHue ? (index == 0 ? 360 : 100) : 255 }
    private var color: Color { componentColor(values) }
    private func componentColor(_ components: [Double]) -> Color {
        if isHue {
            return Color(hue: components[0] / 360, saturation: components[1] / 100,
                         brightness: components[2] / 100)
        }
        return Color(.sRGB, red: components[0] / 255, green: components[1] / 255,
                     blue: components[2] / 255, opacity: 1)
    }
    private func valueLabel(_ index: Int) -> String {
        if isHue && index != 0 { return L10n.percent(values[index] / 100) }
        return "\(Int(values[index].rounded()))" + (isHue ? "°" : "")
    }
    private var channelValue: Binding<Double> {
        Binding { values[selectedChannel] } set: { value in
            guard isActive else { return }
            values[selectedChannel] = min(maximum(selectedChannel), max(0, value.rounded()))
        }
    }

    private var channelRows: some View {
        VStack(spacing: 6) {
            ForEach(channels.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    Button { selectChannel(index) } label: {
                        HStack {
                            Text(L10n.text(channels[index]))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 4)
                            Text(valueLabel(index)).monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .background(selectedChannel == index ? Color.white.opacity(0.16) : .clear,
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedChannel == index ? [.isSelected] : [])

                    HStack(spacing: 4) {
                        adjustmentButton("minus", amount: -1, channel: index).frame(width: 28)
                        channelSlider(index)
                        adjustmentButton("plus", amount: 1, channel: index).frame(width: 28)
                    }
                    // Keep the numeric scale increasing from left to right in every language.
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(height: 18)
                }
                .frame(height: 36)
            }

        }
    }

    var body: some View {
        GeometryReader { geometry in
            // Three 36 pt rows and two 6 pt gaps. Scale the whole block only
            // when necessary, so labels and controls always fit together.
            let scale = min(1, max(0.01, geometry.size.height / 120))
            channelRows
                .frame(width: geometry.size.width / scale, height: 120)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .focusable(isActive)
        .focused($crownFocused)
        .modifier(SteppedCrownModifier(
            value: channelValue, range: 0...maximum(selectedChannel),
            context: selectedChannel * 2 + (isActive ? 1 : 0)))
        .onAppear { crownFocused = isActive }
        .onChange(of: isActive) { _, active in crownFocused = active }
    }

    private func endpointColor(_ value: Double, channel: Int) -> Color {
        var components = values
        components[channel] = value
        return componentColor(components)
    }

    private func gradientColors(_ index: Int) -> [Color] {
        if isHue && index == 0 {
            return (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }
        }
        return [endpointColor(0, channel: index), endpointColor(maximum(index), channel: index)]
    }

    private func channelSlider(_ index: Int) -> some View {
        WatchGradientSlider(
            value: Binding(get: { values[index] }, set: { value in
                selectedChannel = index
                channelValue.wrappedValue = value
                crownFocused = true
            }),
            maximum: maximum(index), colors: gradientColors(index), thumbColor: color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(channels[index]))
        .accessibilityValue(valueLabel(index))
        .accessibilityAdjustableAction { direction in
            selectedChannel = index
            crownFocused = true
            switch direction {
            case .increment: channelValue.wrappedValue += 1
            case .decrement: channelValue.wrappedValue -= 1
            @unknown default: break
            }
        }
    }

    private func adjustmentButton(_ symbol: String, amount: Double, channel index: Int) -> some View {
        Button {
            selectedChannel = index
            channelValue.wrappedValue += amount
            crownFocused = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(amount > 0 ? values[index] >= maximum(index) : values[index] <= 0)
        .accessibilityLabel(L10n.text(channels[index]) + (amount > 0 ? " +1" : " −1"))
    }

    private func selectChannel(_ index: Int) {
        withAnimation(channelAnimation) { selectedChannel = index }
        crownFocused = true
    }

}

/// Keeps the palette draft alive while sampling the composited canvas.
private struct PaletteEyedropperView: View {
    @ObservedObject var controller: CanvasController
    let onCancel: () -> Void
    let onConfirm: (SIMD4<Float>) -> Void
    @State private var isMoving = true
    @State private var color: SIMD4<Float>?
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]

    var body: some View {
        NavigationStack {
            WatchCanvasView(controller: controller, protectedControls: controls,
                isMovingCanvas: $isMoving, isEyedropperActive: true,
                onSampleColor: { color = $0 })
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { if let color { onConfirm(color) } } label: {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                        .disabled(color == nil)
                        .watchToolbarButtonStyle()
                        .accessibilityLabel(L10n.text("Done"))
                        .trackCanvasControl(.tools, frames: $controls)
                    }
                }
        }
        // A full-screen cover can suppress the native leading toolbar slot on
        // older watchOS. Place Cancel explicitly and align it with Done.
        .overlay {
            GeometryReader { geometry in
                let origin = geometry.frame(in: .global).origin
                let doneFrame = controls[.tools]
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .watchToolbarButtonStyle(usesCanvasMaterial: true)
                .accessibilityLabel(L10n.text("Cancel"))
                .trackCanvasControl(.more, frames: $controls)
                .position(x: doneFrame.map { geometry.size.width - ($0.midX - origin.x) } ?? 30,
                          y: doneFrame.map { $0.midY - origin.y } ?? 30)
            }
        }
    }

}

/// Shared track for color channels and layer opacity.
struct WatchGradientSlider: View {
    @Binding var value: Double
    let maximum: Double
    let colors: [Color]
    let thumbColor: Color

    var body: some View {
        GeometryReader { geometry in
            let diameter: CGFloat = max(1, min(18, min(geometry.size.height, geometry.size.width)))
            let travel = max(1, geometry.size.width - diameter)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: diameter)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                Circle()
                    .fill(thumbColor)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .frame(width: diameter, height: diameter)
                    .offset(x: travel * min(1, max(0, value / maximum)))
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                value = min(maximum, max(0, ((gesture.location.x - diameter / 2) / travel) * maximum))
            })
        }
    }
}
