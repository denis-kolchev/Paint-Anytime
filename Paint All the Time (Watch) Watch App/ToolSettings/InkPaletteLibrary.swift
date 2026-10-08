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
    @State private var dragging = false
    @State private var dragOffset = CGSize.zero
    @State private var pageOffset: CGFloat = 0
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
        Group {
            if browsing {
                carousel
            } else if let index = library.palettes.firstIndex(where: { $0.id == currentID }) {
                InkPaletteEditor(palette: $library.palettes[index].palette, controller: controller,
                    onSave: { _ in confirm() }, onBrowse: { browsing = true }, startsEditing: editing)
                    .id(currentID)
            } else {
                carousel
            }
        }
    }

    private var carousel: some View {
        NavigationStack {
            GeometryReader { viewport in
                let width = viewport.size.width
                HStack(spacing: 0) {
                    ForEach(library.palettes) { entry in
                        VStack(spacing: 6) {
                            Text(L10n.text(entry.palette.title ?? "Palette"))
                                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 5), spacing: 5) {
                                ForEach(Array(entry.palette.allColors.prefix(15))) { color in
                                    Circle().fill(color.color)
                                        .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                                        .aspectRatio(1, contentMode: .fit)
                                }
                                if entry.palette.allColors.isEmpty { Image(systemName: "plus").foregroundStyle(.gray) }
                            }
                        }
                        .environment(\.layoutDirection, layoutDirection)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(dragging ? .white : .gray, lineWidth: 1) }
                        .padding(.horizontal, 14)
                        .scaleEffect(dragging && currentID == entry.id ? 0.92 : 1)
                        .offset(currentID == entry.id ? dragOffset : .zero)
                        .contentShape(Rectangle())
                        .onTapGesture { currentID = entry.id; editing = false; browsing = false }
                        .gesture(reorderGesture(entry.id).exclusively(before: pageGesture(width: width)))
                        .accessibilityAction(named: Text(L10n.text("Delete"))) { delete(entry.id) }
                        .accessibilityAction(named: Text(L10n.text("Move left"))) { move(entry.id, by: -1) }
                        .accessibilityAction(named: Text(L10n.text("Move right"))) { move(entry.id, by: 1) }
                        .frame(width: width)
                        .accessibilityHidden(currentID != entry.id)
                    }
                    Button(action: addPalette) {
                        Image(systemName: "plus").font(.largeTitle)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain).padding(.horizontal, 14)
                    .accessibilityLabel(L10n.text("New palette"))
                    .frame(width: width)
                    .gesture(pageGesture(width: width))
                    .accessibilityHidden(currentID != addID)
                }
                .environment(\.layoutDirection, .leftToRight)
                .offset(x: -CGFloat(pageIndex) * width + pageOffset)
                .frame(width: width, height: viewport.size.height, alignment: .leading)
                .clipped()
            }
            .safeAreaInset(edge: .bottom, spacing: -38) {
                Button(L10n.text(currentID == addID ? "New palette" : "Edit")) {
                    if currentID == addID { addPalette() }
                    else { editing = true; browsing = false }
                }
                .buttonStyle(.plain)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Capsule())
                .padding(.horizontal, 20)
                .padding(.bottom, 2)
                .background(alignment: .bottom) {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: 76)
                        .mask {
                            LinearGradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.25), location: 0.3),
                                .init(color: .black, location: 0.8)
                            ], startPoint: .top, endPoint: .bottom)
                        }
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) { Image(systemName: "checkmark") }
                        .disabled(!canConfirm)
                        .accessibilityLabel(L10n.text("Done"))
                }
            }
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

    private var pageIDs: [String] {
        library.palettes.map(\.id) + [addID]
    }

    private var pageIndex: Int { pageIDs.firstIndex(of: currentID) ?? 0 }

    private func pageGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let atEdge = (pageIndex == 0 && value.translation.width > 0)
                    || (pageIndex == pageIDs.count - 1 && value.translation.width < 0)
                pageOffset = value.translation.width * (atEdge ? 0.2 : 1)
            }
            .onEnded { value in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    pageOffset = 0
                    if abs(value.translation.width) > abs(value.translation.height) {
                        let travel = value.predictedEndTranslation.width
                        guard abs(travel) > min(40, width * 0.2) else { return }
                        let target = min(pageIDs.count - 1, max(0, pageIndex + (travel < 0 ? 1 : -1)))
                        currentID = pageIDs[target]
                    } else if value.translation.height < -45 && currentID != addID {
                        delete(currentID)
                    }
                }
            }
    }

    private func reorderGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5).sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag) = value {
                    dragging = true
                    dragOffset = drag?.translation ?? .zero
                }
            }
            .onEnded { value in
                defer { dragging = false; dragOffset = .zero }
                guard case .second(true, let drag?) = value else { return }
                if drag.translation.height < -45 && abs(drag.translation.height) > abs(drag.translation.width) {
                    delete(id)
                } else if abs(drag.translation.width) > 30 {
                    let step = max(1, Int(abs(drag.translation.width) / 60))
                    let forward = drag.translation.width > 0
                    move(id, by: forward ? step : -step)
                }
            }
    }
}
