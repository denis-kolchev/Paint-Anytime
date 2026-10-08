import SwiftUI

struct SavedInkPalette: Codable, Identifiable {
    var id: String
    var palette: InkPalette
}

struct InkPaletteLibrary: Codable {
    var palettes: [SavedInkPalette]
    var activeID: String

    var activePalette: InkPalette {
        palettes.first { $0.id == activeID }?.palette ?? InkPalette()
    }

    static let basicColors = InkPreset.all + colors("basic", "78CBB0 CDB4DB E9CBA7")

    private static func colors(_ id: String, _ hexes: String) -> [InkPreset] {
        hexes.split(separator: " ").enumerated().map { index, hex in
            let value = UInt32(hex, radix: 16)!
            return InkPreset(customID: "\(id)-\(index)", nameKey: "#\(hex)",
                rgba: SIMD4(Float((value >> 16) & 255) / 255,
                            Float((value >> 8) & 255) / 255, Float(value & 255) / 255, 1))
        }
    }

    static var initial: Self {
        let families: [(String, String, String)] = [
            ("reds", "Reds", "541D32 84243D B63246 E0444D F16C65 F6A08C F8C9B5 C94F70 E88FA9 F2C3CF 8C4138 B56B50 D69A72 777B62 F4E6D5"),
            ("oranges", "Oranges", "713C2B A54E2E D66A30 ED893B F7AC59 F6CA88 F8E2B5 C55A46 E98470 F2B3A0 B7844D D4AE64 858E68 4F7275 F4EBDD"),
            ("yellows", "Yellows", "73602C A68B32 D3B23B F2CE46 F9E373 FBF0AF F5E9CE D9993D EEB46A C3BF69 8E9D62 577B70 A67B6B D2AAA0 F8F4E5"),
            ("greens", "Greens", "183F38 28634B 41865B 66A56D 96C58A C8DDA9 E6EBD0 607748 92934F C3B66C 3F8980 79B6A6 B7D9C5 A66E56 E3BA95"),
            ("sky", "Light blues", "244E65 347C98 55A8C4 81CAE0 B8E4EE E0F2F1 327C80 67B4AE A2D6C6 658BAE 9AB8D9 CCD7EB B09CBF E6C2B3 F5E7CF"),
            ("blues", "Blues", "172944 244671 3266A3 4E8ACA 85B2E0 C0D7ED 284C62 397E91 7FB8BE 424879 7378A9 B4B6D3 987C86 D3AAA0 ECE4D7"),
            ("purples", "Purples", "382743 593B70 80559B A47BBB C8A8D7 E7D2E9 443E73 716BA6 ABA5D1 814766 B67794 DDA8BB 7A8A80 B8C7AB F0E3D0"),
            ("mono", "Black & white", "000000 191919 303030 484848 606060 787878 909090 A8A8A8 C0C0C0 D8D8D8 E8E8E8 F4F4F4 FFFFFF 827D77 A4ADB2"),
            ("browns", "Browns", "382B25 594034 7C5140 A16C4F C28C66 DDB491 EED8B8 713F3B A56455 CB9180 626346 8D9065 B8B58A 6E7770 C7C8B6")
        ]
        var entries = [SavedInkPalette(id: "basic", palette: InkPalette(title: "Basic colors"))]
        entries += families.map { id, title, hexes in
            let swatches = colors(id, hexes)
            return SavedInkPalette(id: id, palette: InkPalette(baseColors: swatches, title: title,
                                                               selectedIDs: swatches.map(\.id)))
        }
        return Self(palettes: entries, activeID: "basic")
    }

    static func decode(_ data: Data, legacy: Data) -> Self {
        if let saved = try? JSONDecoder().decode(Self.self, from: data),
           Set(saved.palettes.map(\.id)).count == saved.palettes.count,
           saved.palettes.contains(where: { $0.id == saved.activeID && !$0.palette.selectedColors.isEmpty }) {
            return saved
        }
        var result = initial
        if !legacy.isEmpty {
            result.palettes[0].palette = InkPalette.decode(legacy)
            result.palettes[0].palette.title = "Basic colors"
        }
        return result
    }
}

struct InkPaletteBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State var library: InkPaletteLibrary
    @ObservedObject var controller: CanvasController
    let onSave: (InkPaletteLibrary) -> Void
    @State private var currentID: String
    @State private var browsing = false
    @State private var editing = false
    @State private var showsColorEditor = false
    @State private var sampledColor: SIMD4<Float>?
    @Namespace private var paletteTransition
    @GestureState private var pageTranslation: CGFloat = 0
    private let addID = "add-palette"

    init(library: InkPaletteLibrary, controller: CanvasController,
         onSave: @escaping (InkPaletteLibrary) -> Void) {
        _library = State(initialValue: library)
        self.controller = controller
        self.onSave = onSave
        // Resolve the selection before the first render. An empty Group has no
        // child to appear, so onAppear cannot reliably initialize this state.
        let initialID = library.palettes.first(where: { $0.id == library.activeID })?.id
            ?? library.palettes.first?.id ?? "add-palette"
        _currentID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if !browsing, let index = library.palettes.firstIndex(where: { $0.id == currentID }) {
                    InkPaletteEditor(palette: $library.palettes[index].palette, controller: controller,
                        onBrowse: { setBrowsing(true) }, isEditing: $editing,
                        paletteID: currentID, transitionNamespace: paletteTransition,
                        sampledColor: $sampledColor, showsColorEditor: $showsColorEditor)
                        .id(currentID)
                        .transition(.opacity)
                        .zIndex(1)
                } else {
                    carousel
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationDestination(isPresented: $showsColorEditor) {
                CustomInkEditor(initialColor: sampledColor) { preset in
                    guard let index = library.palettes.firstIndex(where: { $0.id == currentID }) else { return }
                    if let existing = library.palettes[index].palette.allColors.first(where: { $0.rgba == preset.rgba }) {
                        if !library.palettes[index].palette.selectedIDs.contains(existing.id) {
                            library.palettes[index].palette.selectedIDs.append(existing.id)
                        }
                    } else {
                        library.palettes[index].palette.customColors.append(preset)
                        library.palettes[index].palette.selectedIDs.append(preset.id)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.text("Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: finishEditingOrConfirm) { Image(systemName: "checkmark") }
                        .disabled(!canConfirm && !editing)
                        .accessibilityLabel(L10n.text("Done"))
                }
            }
        }
    }

    private func setBrowsing(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.38)) {
            browsing = value
        }
    }

    private func finishEditingOrConfirm() {
        if editing && !browsing {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                editing = false
            }
        } else {
            confirm()
        }
    }

    private var carousel: some View {
            GeometryReader { viewport in
                let width = viewport.size.width
                let buttonHeight = min(36, viewport.size.height * 0.2)
                let verticalGap = min(10, viewport.size.height * 0.05)
                let bottomPadding: CGFloat = 3
                let titleHeight: CGFloat = 20
                let cardHeight = max(1, viewport.size.height - titleHeight - buttonHeight - verticalGap * 2 - bottomPadding)
                // Keep the outline upright around the three-column palette.
                let cardWidth = min(width * 0.68, cardHeight * 0.82)
                let gap = max(4, (width - cardWidth) / 2 - width * 0.08)
                let stride = cardWidth + gap
                let cardShape = paletteShape(width: cardWidth, height: cardHeight)

                VStack(spacing: verticalGap) {
                    Text(L10n.text(currentTitle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: width * 0.85, height: titleHeight)

                    HStack(spacing: gap) {
                        ForEach(library.palettes) { entry in
                            paletteCard(entry, width: cardWidth, height: cardHeight)
                        }
                        Button(action: addPalette) {
                            Image(systemName: "plus")
                                .font(.largeTitle)
                                .frame(width: cardWidth, height: cardHeight)
                                .background(.white.opacity(0.08), in: cardShape)
                                .overlay {
                                    cardShape
                                        .strokeBorder(.gray.opacity(0.6), lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("New palette"))
                        .accessibilityHidden(currentID != addID)
                        .accessibilityAdjustableAction { adjustPage($0) }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .offset(x: (width - cardWidth) / 2 - CGFloat(pageIndex) * stride + pageTranslation)
                    .frame(width: width, height: cardHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .clipped()
                    .simultaneousGesture(pageGesture(stride: stride))
                    .animation(pageAnimation, value: pageTranslation)

                    Button(L10n.text(currentID == addID ? "New palette" : "Edit")) {
                        if currentID == addID { addPalette() }
                        else { editing = true; setBrowsing(false) }
                    }
                    .buttonStyle(.plain)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: width * 0.46, height: buttonHeight)
                    .background {
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.08)],
                                                      startPoint: .top, endPoint: .bottom))
                    }
                    .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .padding(.bottom, bottomPadding)
                .frame(width: width, height: viewport.size.height)
            }
            // Use the lower safe area for Edit, leaving more height for the palette.
            .ignoresSafeArea(.container, edges: .bottom)
    }

    private func paletteCard(_ entry: SavedInkPalette, width: CGFloat, height: CGFloat) -> some View {
        let cardShape = paletteShape(width: width, height: height)
        let horizontalInset = width * 0.09
        let verticalInset = width * 0.06
        let spacing = min(4, width * 0.03)
        let swatchSize = max(1, min((width - horizontalInset * 2 - spacing * 2) / 3,
                                   (height - verticalInset * 2 - spacing * 4) / 5))
        return Button {
            if currentID == entry.id {
                editing = false
                setBrowsing(false)
            } else {
                withAnimation(pageAnimation) { currentID = entry.id }
            }
        } label: {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(swatchSize), spacing: spacing), count: 3), spacing: spacing) {
                ForEach(Array(entry.palette.allColors.prefix(15))) { color in
                    Circle().fill(color.color)
                        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                        .frame(width: swatchSize, height: swatchSize)
                        .modifier(PaletteSwatchTransition(paletteID: entry.id, colorID: color.id,
                            namespace: paletteTransition, enabled: !reduceMotion && entry.id == currentID))
                }
                if entry.palette.allColors.isEmpty {
                    Image(systemName: "plus").foregroundStyle(.gray)
                }
            }
            .environment(\.layoutDirection, layoutDirection)
            .frame(width: width, height: height)
            .background(.white.opacity(0.08), in: cardShape)
            .overlay {
                cardShape
                    .strokeBorder(.gray.opacity(0.6), lineWidth: 2)
            }
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { move(entry.id, by: -1) } label: {
                Label(L10n.text("Move left"), systemImage: "arrow.left")
            }.disabled(library.palettes.first?.id == entry.id)
            Button { move(entry.id, by: 1) } label: {
                Label(L10n.text("Move right"), systemImage: "arrow.right")
            }.disabled(library.palettes.last?.id == entry.id)
            Button(role: .destructive) { delete(entry.id) } label: {
                Label(L10n.text("Delete"), systemImage: "trash")
            }
        }
        .accessibilityLabel(L10n.text(entry.palette.title ?? "Palette"))
        .accessibilityAddTraits(currentID == entry.id ? [.isSelected] : [])
        .accessibilityAction(named: Text(L10n.text("Delete"))) { delete(entry.id) }
        .accessibilityAction(named: Text(L10n.text("Move left"))) { move(entry.id, by: -1) }
        .accessibilityAction(named: Text(L10n.text("Move right"))) { move(entry.id, by: 1) }
        .accessibilityAdjustableAction { adjustPage($0) }
        .accessibilityHidden(currentID != entry.id)
    }

    private func paletteShape(width: CGFloat, height: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: min(width, height) * 0.2, style: .continuous)
    }

    private var pageIDs: [String] { library.palettes.map(\.id) + [addID] }
    private var pageIndex: Int { pageIDs.firstIndex(of: currentID) ?? 0 }
    private var currentTitle: String {
        library.palettes.first { $0.id == currentID }?.palette.title
            ?? (currentID == addID ? "New palette" : "Palette")
    }
    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private func selectPage(by step: Int) {
        let target = min(pageIDs.count - 1, max(0, pageIndex + step))
        withAnimation(pageAnimation) { currentID = pageIDs[target] }
    }

    private func adjustPage(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: selectPage(by: 1)
        case .decrement: selectPage(by: -1)
        @unknown default: break
        }
    }

    private func pageGesture(stride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($pageTranslation) { value, translation, transaction in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                transaction.animation = nil
                let atEdge = (pageIndex == 0 && value.translation.width > 0)
                    || (pageIndex == pageIDs.count - 1 && value.translation.width < 0)
                translation = value.translation.width * (atEdge ? 0.2 : 1)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let travel = value.predictedEndTranslation.width
                guard abs(travel) > stride * 0.2 else { return }
                selectPage(by: travel < 0 ? 1 : -1)
            }
    }

    private var canConfirm: Bool {
        library.palettes.contains { $0.id == currentID && !$0.palette.selectedColors.isEmpty }
    }

    private func confirm() {
        guard canConfirm else { return }
        library.activeID = currentID
        onSave(library)
        dismiss()
    }

    private func addPalette() {
        let id = UUID().uuidString
        library.palettes.append(SavedInkPalette(id: id,
            palette: InkPalette(baseColors: [], title: "New palette", selectedIDs: [])))
        currentID = id
        editing = false
        browsing = false
    }

    private func delete(_ id: String) {
        guard let index = library.palettes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            library.palettes.remove(at: index)
            currentID = library.palettes.isEmpty ? addID : library.palettes[min(index, library.palettes.count - 1)].id
        }
    }

    private func move(_ id: String, by step: Int) {
        guard let index = library.palettes.firstIndex(where: { $0.id == id }) else { return }
        let target = min(library.palettes.count - 1, max(0, index + step))
        guard target != index else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            let entry = library.palettes.remove(at: index)
            library.palettes.insert(entry, at: target)
            currentID = id
        }
    }

}

/// Match each color independently; navigation and safe-area layout stay stationary.
struct PaletteSwatchTransition: ViewModifier {
    let paletteID: String
    let colorID: String
    let namespace: Namespace.ID
    let enabled: Bool

    private struct SwatchID: Hashable {
        let palette: String
        let color: String
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: SwatchID(palette: paletteID, color: colorID),
                                          in: namespace)
        } else {
            content
        }
    }
}
