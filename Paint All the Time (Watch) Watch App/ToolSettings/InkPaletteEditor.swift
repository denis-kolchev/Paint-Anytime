import SwiftUI

struct InkPalette: Codable {
    var baseColors: [InkPreset]?
    var title: String?
    var customColors: [InkPreset] = []
    var selectedIDs: [String] = InkPreset.all.map(\.id)

    // Optional fields keep palettes saved before editing was introduced readable.
    var orderedIDs: [String]?
    var deletedIDs: [String]?

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
    let onBrowse: () -> Void
    @Binding var isEditing: Bool
    @State private var showsEyedropper = false
    @Binding var sampledColor: SIMD4<Float>?
    @Binding var showsColorEditor: Bool
    @State private var draggedID: String?
    @State private var dragOffset = CGSize.zero
    @State private var swatchFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text(palette.title ?? "Basic colors"))
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(palette.allColors) { preset in
                            let selected = palette.selectedIDs.contains(preset.id)
                            Button {
                                guard !isEditing else { return }
                                if selected {
                                    guard palette.selectedIDs.count > 1 else { return }
                                    palette.selectedIDs.removeAll { $0 == preset.id }
                                } else {
                                    palette.selectedIDs.append(preset.id)
                                }
                            } label: {
                                Circle()
                                    .fill(selected ? Color.clear : preset.color)
                                    .overlay {
                                        if selected {
                                            Circle().strokeBorder(preset.color, lineWidth: 5)
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 22, weight: .semibold))
                                                .foregroundStyle(preset.color)
                                        }
                                    }
                                    // Keep black swatches visible on the black background.
                                    .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                                    .aspectRatio(1, contentMode: .fit)
                                    .contentShape(Circle())
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
                                enabled: isEditing && !showsColorEditor && draggedID != preset.id,
                                viewportSize: viewport.size))
                            .offset(draggedID == preset.id ? dragOffset : .zero)
                            .scaleEffect(draggedID == preset.id && !reduceMotion ? 1.08 : 1)
                            .zIndex(draggedID == preset.id ? 1 : 0)
                            .highPriorityGesture(swatchDrag(preset.id), including: isEditing ? .all : .none)
                            .highPriorityGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in onBrowse() },
                                including: isEditing ? .none : .all)
                            .accessibilityAction(named: Text(L10n.text("Palettes"))) { onBrowse() }
                            .accessibilityLabel(preset.name)
                            .accessibilityValue(L10n.text(selected ? "Selected" : "Not selected"))
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                        Button { sampledColor = nil; showsColorEditor = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.gray)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Create color"))
                        Button {
                            sampledColor = nil
                            showsEyedropper = true
                        } label: {
                            Image(systemName: "eyedropper")
                                .font(.title2)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Eyedropper"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .coordinateSpace(name: "paletteGrid")
                .onPreferenceChange(PaletteSwatchFramesKey.self) { swatchFrames = $0 }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) { if !isEditing { onBrowse() } }
                .accessibilityAction(named: Text(L10n.text("Palettes"))) { onBrowse() }
            }
            .scrollDisabled(draggedID != nil)
            }
            .coordinateSpace(name: "paletteViewport")
        }
        .fullScreenCover(isPresented: $showsEyedropper, onDismiss: {
            if sampledColor != nil { showsColorEditor = true }
        }) {
            PaletteEyedropperView(controller: controller) { color in
                sampledColor = color
                showsEyedropper = false
            }
        }
    }

    private func swatchDrag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("paletteGrid"))
            .onChanged { value in
                guard isEditing else { return }
                draggedID = id
                dragOffset = value.translation
            }
            .onEnded { value in
                defer { draggedID = nil; dragOffset = .zero }
                guard isEditing,
                      let target = swatchFrames.first(where: { $0.value.contains(value.location) })?.key else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    palette.move(id, to: target)
                }
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
    @State private var wigglePhase = false

    private var animates: Bool {
        enabled && isVisible && !reduceMotion && scenePhase == .active
    }

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named("paletteViewport"))
                    let visible = frame.intersects(CGRect(origin: .zero, size: viewportSize))
                    Color.clear
                        .onAppear { isVisible = visible }
                        .onChange(of: visible) { _, value in isVisible = value }
                }
            }
            .rotationEffect(.degrees(animates ? (wigglePhase ? 2 : -2) : 0))
            .offset(x: animates ? (wigglePhase ? 0.5 : -0.5) : 0)
            .animation(animates
                       ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true)
                       : nil, value: wigglePhase)
            .task(id: animates) {
                // Start a new state transition after SwiftUI installs the visible
                // editing state, including when a cell scrolls back into view.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { wigglePhase = false }
                guard animates else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                wigglePhase = true
            }
            .onDisappear {
                isVisible = false
                wigglePhase = false
            }
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
        }
    }
    private var hsbBinding: Binding<[Double]> {
        Binding { hsb } set: { values in
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
        }
        .padding(.bottom, 8)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onSave(InkPreset(customID: UUID().uuidString, nameKey: colorName,
                                     rgba: SIMD4(Float(rgb[0] / 255), Float(rgb[1] / 255), Float(rgb[2] / 255), 1)))
                    dismiss()
                } label: { Image(systemName: "checkmark") }
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
                        schemeButton("Hue", page: 0)
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
            Text(title == "Hue" ? L10n.text("Hue") : title)
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
        "\(Int(values[index].rounded()))" + (isHue ? (index == 0 ? "°" : "%") : "")
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
        .digitalCrownRotation(detent: channelValue, from: 0, through: maximum(selectedChannel), by: 1,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
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
        GeometryReader { geometry in
            let diameter: CGFloat = max(1, min(18, min(geometry.size.height, geometry.size.width)))
            let travel = max(1, geometry.size.width - diameter)
            let thumbX = diameter / 2 + travel * values[index] / maximum(index)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: gradientColors(index),
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: diameter)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                Circle()
                    .fill(color)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .frame(width: diameter, height: diameter)
                    .offset(x: thumbX - diameter / 2)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                selectedChannel = index
                channelValue.wrappedValue = ((value.location.x - diameter / 2) / travel) * maximum(index)
                crownFocused = true
            })
        }
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
    let onConfirm: (SIMD4<Float>) -> Void
    @State private var isMoving = true
    @State private var isSampling = true
    @State private var color: SIMD4<Float>?
    @State private var controls: [CanvasToolbarControl: CGRect] = [:]

    var body: some View {
        NavigationStack {
            WatchCanvasView(controller: controller, protectedControls: controls,
                isMovingCanvas: $isMoving, isEyedropperActive: isSampling,
                onSampleColor: { color = $0 })
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isSampling.toggle() } label: {
                            Image(systemName: "eyedropper")
                                .foregroundStyle(isSampling ? .green : .primary)
                        }
                        .watchToolbarButtonStyle()
                        .accessibilityLabel(L10n.text("Eyedropper"))
                        .accessibilityAddTraits(isSampling ? [.isSelected] : [])
                        .trackCanvasControl(.more, frames: $controls)
                    }
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
    }
}
