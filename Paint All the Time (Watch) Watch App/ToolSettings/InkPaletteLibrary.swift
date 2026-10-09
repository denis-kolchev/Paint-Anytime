import SwiftUI

struct SavedInkPalette: Codable, Identifiable {
    var id: String
    var palette: InkPalette
    var isHidden: Bool?

    var isVisible: Bool { id == "basic" || isHidden != true }
}

struct InkPaletteLibrary: Codable {
    var palettes: [SavedInkPalette]
    var activeID: String

    var visiblePalettes: [SavedInkPalette] { palettes.filter(\.isVisible) }

    var activePalette: InkPalette {
        visiblePalettes.first { $0.id == activeID }?.palette
            ?? visiblePalettes.first?.palette ?? InkPalette()
    }

    /// Merge the browser's visible draft without deleting hidden palettes.
    func mergingVisiblePalettes(_ draft: Self) -> Self {
        var remaining = draft.palettes.makeIterator()
        var merged: [SavedInkPalette] = []
        for entry in palettes {
            if !entry.isVisible { merged.append(entry) }
            else if let next = remaining.next() { merged.append(next) }
        }
        while let next = remaining.next() { merged.append(next) }
        return Self(palettes: merged, activeID: draft.activeID)
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
                                                               selectedIDs: swatches.map(\.id)), isHidden: true)
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
    private let hiddenNameIDs: Set<PaletteNameID>
    @State private var currentID: String
    @State private var browsing = false
    @State private var editing = false
    @State private var showsColorEditor = false
    @State private var sampledColor: SIMD4<Float>?
    @State private var pendingDeletionID: String?
    @State private var actionPalette: SavedInkPalette?
    @GestureState private var carouselTranslation = CGSize.zero
    @State private var movingID: String?
    @State private var insertionIndex = 0
    @State private var movingTranslation = CGSize.zero
    @State private var lastMoveX: CGFloat = 0
    @GestureState private var moveGestureActive = false
    private let addID = "add-palette"

    init(library: InkPaletteLibrary, controller: CanvasController,
         onSave: @escaping (InkPaletteLibrary) -> Void) {
        let visibleLibrary = InkPaletteLibrary(palettes: library.visiblePalettes, activeID: library.activeID)
        _library = State(initialValue: visibleLibrary)
        self.controller = controller
        hiddenNameIDs = Set(library.palettes.filter { !$0.isVisible }.compactMap { $0.palette.generatedNameID })
        self.onSave = { draft in onSave(library.mergingVisiblePalettes(draft)) }
        // Resolve the selection before the first render. An empty Group has no
        // child to appear, so onAppear cannot reliably initialize this state.
        let initialID = visibleLibrary.palettes.first(where: { $0.id == library.activeID })?.id
            ?? visibleLibrary.palettes.first?.id ?? "add-palette"
        _currentID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if !browsing, let index = library.palettes.firstIndex(where: { $0.id == currentID }) {
                    InkPaletteEditor(palette: $library.palettes[index].palette, controller: controller,
                        onBrowse: { setBrowsing(true) }, isEditing: $editing,
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
                        .disabled(movingID != nil || pendingDeletionID != nil || (!canConfirm && !editing))
                        .accessibilityLabel(L10n.text("Done"))
                }
            }
        }
        .onChange(of: moveGestureActive) { _, active in
            if !active { cancelMove() }
        }
        .onChange(of: library.palettes.first { $0.id == currentID }?.palette.allColors.map(\.rgba)) { _, _ in
            updateGeneratedName()
        }
        .confirmationDialog(L10n.text("Palette"), isPresented: Binding(
            get: { actionPalette != nil },
            set: { if !$0 { actionPalette = nil } }
        ), presenting: actionPalette) { entry in
            Button(L10n.text("Move left")) { move(entry.id, by: -1) }
                .disabled(library.palettes.first?.id == entry.id)
            Button(L10n.text("Move right")) { move(entry.id, by: 1) }
                .disabled(library.palettes.last?.id == entry.id)
            Button(L10n.text("Delete"), role: .destructive) { delete(entry.id) }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }

    private func setBrowsing(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
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
                let availableHeight = max(1, viewport.size.height - titleHeight - buttonHeight - verticalGap * 2 - bottomPadding)
                let cardWidth = min(width * 0.68, availableHeight)
                let cardHeight = cardWidth
                let gap = max(4, (width - cardWidth) / 2 - width * 0.08)
                let stride = cardWidth + gap
                let previewSize = cardWidth * 0.65
                let previewTop = titleHeight + verticalGap - 6
                let previewGap: CGFloat = 8
                let previewStride = previewSize + previewGap
                let slotStride = movingID == nil ? stride : previewStride
                let stripOffset = movingID == nil
                    ? (width - stride) / 2 - CGFloat(pageIndex) * stride + carouselTranslation.width
                    : width / 2 - CGFloat(insertionIndex) * previewStride + previewGap / 2
                let cardShape = paletteShape(width: cardWidth, height: cardHeight)

                VStack(spacing: verticalGap) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(reorderPreviewPalettes) { entry in
                            VStack(spacing: verticalGap) {
                                carouselTitle(entry.palette.displayTitle, width: slotStride - 6, height: titleHeight)
                                    .opacity(titleOpacity(for: entry.id, stride: stride))
                                paletteSlot(entry,
                                            width: movingID == nil ? cardWidth : previewSize,
                                            height: movingID == nil ? cardHeight : previewSize,
                                            stride: stride)
                                    .opacity(movingID == entry.id ? 0 : 1)
                                    .offset(y: movingID == nil ? 0 : -6)
                            }
                            // Collapse the held card's slot so the remaining cards
                            // form one compact row with the insertion boundary at center.
                            .frame(width: movingID == entry.id ? 0 : slotStride,
                                   height: titleHeight + verticalGap + cardHeight, alignment: .top)
                            .accessibilityHidden(currentID != entry.id)
                        }
                        VStack(spacing: verticalGap) {
                            carouselTitle(L10n.text("New palette"), width: stride - 6, height: titleHeight)
                                .opacity(titleOpacity(for: addID, stride: stride))
                            Button {
                                guard pendingDeletionID == nil, movingID == nil else { return }
                                if currentID == addID {
                                    addPalette()
                                } else {
                                    withAnimation(pageAnimation) { currentID = addID }
                                }
                            } label: {
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
                            .disabled(pendingDeletionID != nil)
                            .accessibilityLabel(L10n.text("New palette"))
                            .accessibilityAdjustableAction { adjustPage($0) }
                        }
                        .frame(width: stride)
                        .accessibilityHidden(currentID != addID || movingID != nil)
                        .opacity(movingID == nil ? 1 : 0)
                        .allowsHitTesting(movingID == nil)
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: stripOffset)
                    .frame(width: width, height: titleHeight + verticalGap + cardHeight, alignment: .leading)
                    .contentShape(Rectangle())
                    .clipped()
                    // A recognized swipe must cancel the card's button press.
                    .coordinateSpace(name: "paletteReordering")
                    // Once a swipe is recognized, cancel the card button's tap.
                    // Leave the revealed Delete button outside this arbitration.
                    .highPriorityGesture(pageGesture(stride: stride),
                                         including: pendingDeletionID == nil ? .all : .subviews)
                    .animation(pageAnimation, value: carouselTranslation)
                    .overlay(alignment: .top) {
                        if let movingID, let entry = library.palettes.first(where: { $0.id == movingID }) {
                            ZStack(alignment: .top) {
                                Rectangle().fill(.green)
                                    .frame(width: 2, height: previewSize)
                                    .overlay(alignment: .top) {
                                        Text("\(insertionIndex + 1) / \(library.palettes.count)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.green, in: RoundedRectangle(cornerRadius: 4))
                                            .fixedSize()
                                            .alignmentGuide(.top) { dimensions in
                                                dimensions[.bottom] + 4
                                            }
                                    }
                                    .offset(y: previewTop)
                                paletteCard(entry, width: cardWidth, height: cardHeight)
                                    .opacity(0.5)
                                    .offset(x: movingTranslation.width, y: titleHeight + previewSize * 0.35 + movingTranslation.height)
                            }
                            .frame(width: width, height: titleHeight + cardHeight, alignment: .top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .task(id: moveEdgeDirection) {
                        let direction = moveEdgeDirection
                        guard direction != 0 else { return }
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .milliseconds(450)) }
                            catch { return }
                            guard movingID != nil else { return }
                            withAnimation(pageAnimation) {
                                insertionIndex = min(library.palettes.count - 1, max(0, insertionIndex + direction))
                            }
                        }
                    }

                    Button(L10n.text(pendingDeletionID != nil ? "Cancel" : "Edit")) {
                        if pendingDeletionID != nil {
                            withAnimation(pageAnimation) { pendingDeletionID = nil }
                        } else if currentID != addID { editing = true; setBrowsing(false) }
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
                    .opacity(currentID == addID || movingID != nil ? 0 : 1)
                    .allowsHitTesting(currentID != addID && movingID == nil)
                    .accessibilityHidden(currentID == addID || movingID != nil)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: currentID == addID)
                }
                .padding(.bottom, bottomPadding)
                .frame(width: width, height: viewport.size.height)
            }
            // Use the lower safe area for Edit, leaving more height for the palette.
            .ignoresSafeArea(.container, edges: .bottom)
    }

    private func titleOpacity(for id: String, stride: CGFloat) -> Double {
        guard movingID == nil, let index = pageIDs.firstIndex(of: id) else { return 0 }
        // Use the same displacement as the cards, so only the current title
        // and the title in the swipe direction participate in the crossfade.
        // Clamping keeps the end title visible during edge resistance.
        let position = min(CGFloat(pageIDs.count - 1),
                           max(0, CGFloat(pageIndex) - carouselTranslation.width / stride))
        return Double(max(0, 1 - abs(CGFloat(index) - position)))
    }

    private func carouselTitle(_ title: String, width: CGFloat, height: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, height: height)
            .environment(\.layoutDirection, layoutDirection)
    }

    private func paletteSlot(_ entry: SavedInkPalette, width: CGFloat, height: CGFloat,
                             stride: CGFloat) -> some View {
        let awaitingDeletion = pendingDeletionID == entry.id
        let lift = entry.id == currentID ? carouselTranslation.height : 0
        return ZStack {
            if awaitingDeletion || lift < 0 {
                Button(role: .destructive) { delete(entry.id) } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: min(34, width * 0.35)))
                        Text(L10n.text("Delete"))
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(.red)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(awaitingDeletion)
                .accessibilityHidden(!awaitingDeletion)
            }
            paletteCard(entry, width: width, height: height)
                // Observe a hold alongside the button's tap, and only on the
                // card itself so the revealed Delete button has no hold handler.
                .simultaneousGesture(reorderGesture(entry, stride: stride),
                                     including: pendingDeletionID == nil ? .all : .none)
                .offset(y: awaitingDeletion ? -height - 12 : lift)
                .opacity(awaitingDeletion ? 0 : 1)
                .allowsHitTesting(pendingDeletionID == nil)
                .accessibilityHidden(awaitingDeletion || entry.id != currentID)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private func paletteCard(_ entry: SavedInkPalette, width: CGFloat, height: CGFloat) -> some View {
        let cardShape = paletteShape(width: width, height: height)
        let horizontalInset = width * 0.09
        let verticalInset = width * 0.06
        let spacing = min(4, width * 0.03)
        let swatchSize = max(1, min((width - horizontalInset * 2 - spacing * 2) / 3,
                                   (height - verticalInset * 2 - spacing * 4) / 5))
        return Button {
            guard pendingDeletionID == nil, movingID == nil else { return }
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
        .accessibilityLabel(entry.palette.displayTitle)
        .accessibilityAddTraits(currentID == entry.id ? [.isSelected] : [])
        .accessibilityAction(named: Text(L10n.text("Delete"))) { delete(entry.id) }
        .accessibilityAction(named: Text(L10n.text("Move left"))) { move(entry.id, by: -1) }
        .accessibilityAction(named: Text(L10n.text("Move right"))) { move(entry.id, by: 1) }
        .accessibilityAdjustableAction { adjustPage($0) }
        .accessibilityHidden(currentID != entry.id)
    }

    private var reorderPreviewPalettes: [SavedInkPalette] {
        guard let movingID, let source = library.palettes.firstIndex(where: { $0.id == movingID }) else {
            return library.palettes
        }
        var preview = library.palettes
        let entry = preview.remove(at: source)
        preview.insert(entry, at: min(insertionIndex, preview.count))
        return preview
    }

    private var moveEdgeDirection: Int {
        guard movingID != nil else { return 0 }
        return movingTranslation.width > 45 ? 1 : movingTranslation.width < -45 ? -1 : 0
    }

    private func reorderGesture(_ entry: SavedInkPalette, stride: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("paletteReordering")))
            .updating($moveGestureActive) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard pendingDeletionID == nil else { return }
                guard case .second(true, let drag) = value else { return }
                if movingID == nil {
                    guard let index = library.palettes.firstIndex(where: { $0.id == entry.id }) else { return }
                    withAnimation(pageAnimation) {
                        movingID = entry.id
                        insertionIndex = index
                    }
                    lastMoveX = 0
                }
                guard let drag else { return }
                movingTranslation = drag.translation
                let distance = drag.translation.width - lastMoveX
                if abs(distance) > stride * 0.45 {
                    let direction = distance > 0 ? 1 : -1
                    withAnimation(pageAnimation) {
                        insertionIndex = min(library.palettes.count - 1, max(0, insertionIndex + direction))
                    }
                    lastMoveX = drag.translation.width
                }
            }
            .onEnded { value in
                if case .second(true, _) = value,
                   let movingID,
                   let source = library.palettes.firstIndex(where: { $0.id == movingID }) {
                    withAnimation(pageAnimation) {
                        let entry = library.palettes.remove(at: source)
                        library.palettes.insert(entry, at: min(insertionIndex, library.palettes.count))
                        currentID = entry.id
                    }
                }
                cancelMove()
            }
    }

    private func cancelMove() {
        guard movingID != nil else { return }
        withAnimation(pageAnimation) {
            movingID = nil
            movingTranslation = .zero
            lastMoveX = 0
        }
    }

    private func paletteShape(width: CGFloat, height: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: min(width, height) * 0.2, style: .continuous)
    }

    private var pageIDs: [String] { library.palettes.map(\.id) + [addID] }
    private var pageIndex: Int { pageIDs.firstIndex(of: currentID) ?? 0 }
    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private func selectPage(by step: Int) {
        guard pendingDeletionID == nil, movingID == nil else { return }
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
            .updating($carouselTranslation) { value, translation, transaction in
                guard pendingDeletionID == nil, movingID == nil else { return }
                transaction.animation = nil
                if abs(value.translation.height) > abs(value.translation.width) {
                    if currentID != addID { translation.height = min(0, value.translation.height) }
                    return
                }
                let atEdge = (pageIndex == 0 && value.translation.width > 0)
                    || (pageIndex == pageIDs.count - 1 && value.translation.width < 0)
                translation.width = value.translation.width * (atEdge ? 0.2 : 1)
            }
            .onEnded { value in
                guard pendingDeletionID == nil, movingID == nil else { return }
                if abs(value.translation.height) > abs(value.translation.width) {
                    if currentID != addID && value.translation.height < -30 {
                        withAnimation(pageAnimation) { pendingDeletionID = currentID }
                    }
                    return
                }
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
        updateGeneratedName()
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

    private func updateGeneratedName() {
        guard let index = library.palettes.firstIndex(where: { $0.id == currentID }) else { return }
        let palette = library.palettes[index].palette
        guard palette.generatedNameID != nil || palette.title == "New palette" else { return }
        guard !palette.allColors.isEmpty else {
            library.palettes[index].palette.generatedNameID = nil
            library.palettes[index].palette.title = "New palette"
            return
        }
        let previous = palette.generatedNameID
        let used = Set(library.palettes.filter { $0.id != currentID && !$0.palette.allColors.isEmpty }
            .compactMap { $0.palette.generatedNameID }).union(hiddenNameIDs)
        // Name the complete palette, independent of swatch order or selection.
        let hexColors = library.palettes[index].palette.allColors.map { preset in
            let channels = [preset.rgba.x, preset.rgba.y, preset.rgba.z].map { value in
                Int((min(1, max(0, value.isFinite ? value : 0)) * 255).rounded())
            }
            return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
        }.sorted()
        library.palettes[index].palette.generatedNameID = PaletteNameGenerator().generate(
            hexColors: hexColors, usedByOtherPalettes: used, previous: previous)
    }

    private func delete(_ id: String) {
        guard let index = library.palettes.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            pendingDeletionID = nil
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
