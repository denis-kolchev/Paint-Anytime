import SwiftUI

struct InkPalette: Codable {
    var customColors: [InkPreset] = []
    var selectedIDs: [String] = InkPreset.all.map(\.id)

    // Optional fields keep palettes saved before editing was introduced readable.
    var orderedIDs: [String]?
    var deletedIDs: [String]?

    var allColors: [InkPreset] {
        let available = (InkPreset.all + customColors).filter { !(deletedIDs ?? []).contains($0.id) }
        let ordered = (orderedIDs ?? []).compactMap { id in available.first { $0.id == id } }
        return ordered + available.filter { !(orderedIDs ?? []).contains($0.id) }
    }

    mutating func delete(_ id: String) {
        guard allColors.count > 1 else { return }
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
        return selected.isEmpty ? [allColors.first ?? InkPreset.all[0]] : selected
    }

    static func decode(_ data: Data) -> InkPalette {
        guard var palette = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var knownIDs = Set(InkPreset.all.map(\.id))
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
    @Environment(\.dismiss) private var dismiss
    @State var palette: InkPalette
    let onSave: (InkPalette) -> Void
    @State private var showsColorEditor = false
    @State private var isEditing = false
    @State private var draggedID: String?
    @State private var dragOffset = CGSize.zero
    @State private var swatchFrames: [String: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Palette")).font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(palette.allColors) { preset in
                            let selected = palette.selectedIDs.contains(preset.id)
                            Button {
                                guard !isEditing else { return }
                                if selected {
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
                            .disabled(!isEditing && selected && palette.selectedIDs.count == 1)
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
                                    .disabled(palette.allColors.count == 1)
                                    .accessibilityLabel(L10n.text("Delete") + " " + preset.name)
                                }
                            }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: PaletteSwatchFramesKey.self,
                                        value: [preset.id: geometry.frame(in: .named("paletteGrid"))])
                                }
                            }
                            .offset(draggedID == preset.id ? dragOffset : .zero)
                            .scaleEffect(draggedID == preset.id && !reduceMotion ? 1.08 : 1)
                            .zIndex(draggedID == preset.id ? 1 : 0)
                            .highPriorityGesture(swatchDrag(preset.id), including: isEditing ? .all : .none)
                            .accessibilityLabel(preset.name)
                            .accessibilityValue(L10n.text(selected ? "Selected" : "Not selected"))
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                        Button { showsColorEditor = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.gray)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Create color"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .coordinateSpace(name: "paletteGrid")
                .onPreferenceChange(PaletteSwatchFramesKey.self) { swatchFrames = $0 }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) { isEditing = true }
                .accessibilityAction(named: Text(L10n.text("Edit"))) { isEditing = true }
            }
            .scrollDisabled(draggedID != nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.text("Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if isEditing { isEditing = false }
                        else { onSave(palette); dismiss() }
                    } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel(L10n.text("Done"))
                }
            }
            .navigationDestination(isPresented: $showsColorEditor) {
                CustomInkEditor { preset in
                    if let existing = palette.allColors.first(where: { $0.rgba == preset.rgba }) {
                        if !palette.selectedIDs.contains(existing.id) { palette.selectedIDs.append(existing.id) }
                    } else {
                        palette.customColors.append(preset)
                        palette.selectedIDs.append(preset.id)
                    }
                }
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

private struct PaletteSwatchFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CustomInkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var crownFocused: Bool
    @State private var values: [Double] = [128, 128, 128]
    @State private var selectedChannel = 0
    let onSave: (InkPreset) -> Void

    private let channels = ["Red", "Green", "Blue"]
    private var channelAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }
    private var color: Color {
        Color(.sRGB, red: values[0] / 255, green: values[1] / 255,
              blue: values[2] / 255, opacity: 1)
    }
    private var hex: String {
        String(format: "#%02X%02X%02X", Int(values[0]), Int(values[1]), Int(values[2]))
    }
    private var colorName: String { NamedInkColors.name(forHex: hex) ?? hex }
    private var channelValue: Binding<Double> {
        Binding { values[selectedChannel] } set: { value in
            values[selectedChannel] = min(255, max(0, value.rounded()))
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(channels.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    Button { selectChannel(index) } label: {
                        HStack {
                            Text(L10n.text(channels[index]))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Spacer(minLength: 4)
                            Text("\(Int(values[index]))").monospacedDigit()
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
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
                    .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            Text(colorName)
                .font(.caption.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // Respect the system toolbar above; include the bottom safe area in layout.
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .contentShape(Rectangle())
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(detent: channelValue, from: 0, through: 255, by: 1,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { crownFocused = true }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    onSave(InkPreset(customID: UUID().uuidString, nameKey: colorName,
                                     rgba: SIMD4(Float(values[0] / 255), Float(values[1] / 255),
                                                 Float(values[2] / 255), 1)))
                    dismiss()
                } label: { Image(systemName: "checkmark") }
                .accessibilityLabel(L10n.text("Add color"))
            }
        }
    }

    private func endpointColor(_ value: Double, channel: Int) -> Color {
        var components = values
        components[channel] = value
        return Color(.sRGB, red: components[0] / 255, green: components[1] / 255,
                     blue: components[2] / 255, opacity: 1)
    }

    private func channelSlider(_ index: Int) -> some View {
        GeometryReader { geometry in
            let diameter: CGFloat = max(1, min(28, min(geometry.size.height, geometry.size.width)))
            let travel = max(1, geometry.size.width - diameter)
            let thumbX = diameter / 2 + travel * values[index] / 255
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [endpointColor(0, channel: index), endpointColor(255, channel: index)],
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
                channelValue.wrappedValue = ((value.location.x - diameter / 2) / travel) * 255
                crownFocused = true
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text(channels[index]))
        .accessibilityValue("\(Int(values[index]))")
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
                .font(.system(size: 20, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(amount > 0 ? values[index] >= 255 : values[index] <= 0)
        .accessibilityLabel(L10n.text(channels[index]) + (amount > 0 ? " +1" : " −1"))
    }

    private func selectChannel(_ index: Int) {
        withAnimation(channelAnimation) { selectedChannel = index }
        crownFocused = true
    }

}
