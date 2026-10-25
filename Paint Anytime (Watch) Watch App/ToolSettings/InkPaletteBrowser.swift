import SwiftUI

@MainActor
struct InkPaletteBrowser: View {
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State var library: InkPaletteLibrary
    @ObservedObject var controller: CanvasController
    @ObservedObject var tutorial = TutorialSession.inactive
    let onSave: (InkPaletteLibrary) -> Void
    private let returnsToCanvasAfterColorSave: Bool
    private let hiddenNameIDs: Set<PaletteNameID>
    @State private var currentID: String
    @State private var browsing = false
    @State private var editing = false
    @State private var paletteBeforeEditing: SavedInkPalette?
    @State private var showsColorEditor = false
    @State private var sampledColor: SIMD4<Float>?
    @State private var addedColors: [(paletteID: String, colorID: String)] = []
    @State private var pendingDeletionID: String?
    @State private var actionPalette: SavedInkPalette?
    @GestureState private var carouselTranslation = CGSize.zero
    @State private var movingID: String?
    @State private var insertionIndex = 0
    @State private var movingTranslation = CGSize.zero
    @State private var lastMoveX: CGFloat = 0
    @GestureState private var moveGestureActive = false
    private let addID = "add-palette"

    init(library: InkPaletteLibrary, controller: CanvasController, initialColor: SIMD4<Float>? = nil,
         tutorial: TutorialSession? = nil,
         onSave: @escaping (InkPaletteLibrary) -> Void) {
        let visibleLibrary = InkPaletteLibrary(palettes: library.visiblePalettes, activeID: library.activeID)
        _library = State(initialValue: visibleLibrary)
        self.controller = controller
        self.tutorial = tutorial ?? .inactive
        returnsToCanvasAfterColorSave = initialColor != nil
        _sampledColor = State(initialValue: initialColor)
        _showsColorEditor = State(initialValue: initialColor != nil)
        hiddenNameIDs = Set(library.palettes.filter { !$0.isVisible }.compactMap { $0.palette.generatedNameID })
        self.onSave = { draft in onSave(library.mergingVisiblePalettes(draft)) }
        // Resolve the selection before the first render. An empty Group has no
        // child to appear, so onAppear cannot reliably initialize this state.
        let initialID = visibleLibrary.palettes.first(where: { $0.id == library.activeID })?.id
            ?? visibleLibrary.palettes.first?.id ?? "add-palette"
        _currentID = State(initialValue: initialID)
    }

    var body: some View {
        Group {
            if tutorial.isActive {
                // The tutorial already owns a NavigationStack. Reuse its safe
                // area so the content starts below the native toolbar.
                browserContent
            } else {
                NavigationStack { browserContent }
            }
        }
        // watchOS supplies a modal close button separately from the navigation back button.
        .interactiveDismissDisabled(tutorial.isActive || browsing || currentID == addID)
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
                .disabled(!canDeletePalette)
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
    }

    private var browserContent: some View {
        ZStack {
            if tutorial.isActive && showsColorEditor {
                // Keep tutorial screens in the same viewport as the coach card.
                // A watchOS navigation push takes over the full screen.
                colorEditor
                    .transition(.opacity)
                    .zIndex(2)
            } else if !browsing, let index = library.palettes.firstIndex(where: { $0.id == currentID }) {
                InkPaletteEditor(palette: $library.palettes[index].palette, controller: controller, tutorial: tutorial,
                    onBrowse: {
                        if showsEmptyPaletteClose {
                            discardEmptyPalette()
                        } else {
                            setBrowsing(true)
                            tutorial.record(.browsedPalettes)
                        }
                    }, onEdit: beginEditing, isEditing: $editing,
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
        .animation(tutorial.isActive ? .easeInOut(duration: reduceMotion ? 0.15 : 0.3) : nil,
                   value: browsing)
        .animation(tutorial.isActive ? .easeInOut(duration: reduceMotion ? 0.15 : 0.3) : nil,
                   value: showsColorEditor)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: Binding(
            get: { !tutorial.isActive && showsColorEditor },
            set: { if !tutorial.isActive { showsColorEditor = $0 } }
        )) {
            colorEditor
        }
        .toolbar {
            if tutorial.isActive && !showsColorEditor {
                // Reserve the trailing native toolbar slot to center the system clock.
                ToolbarItem(placement: .confirmationAction) {
                    Button {} label: {
                        Color.clear.frame(width: 32, height: 32)
                    }
                    .watchToolbarButtonStyle(hidesNativeChrome: true)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            if tutorial.isActive && tutorial.step != .openPalettes {
                ToolbarItem(placement: .cancellationAction) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if !tutorial.isActive {
                if browsing || currentID == addID {
                    // Occupy the cancellation slot so watchOS does not insert its own close button.
                    ToolbarItem(placement: .cancellationAction) {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                } else if editing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: cancelEditing) { Image(systemName: "xmark") }
                            .accessibilityLabel(L10n.text("Cancel"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if showsEmptyPaletteClose {
                        Button(action: discardEmptyPalette) { Image(systemName: "xmark") }
                            .accessibilityLabel(L10n.text("Close"))
                    } else {
                        Button(action: finishEditingOrConfirm) { Image(systemName: "checkmark") }
                            .disabled(movingID != nil || pendingDeletionID != nil || (!canConfirm && !editing))
                            .accessibilityLabel(L10n.text("Done"))
                    }
                }
            }
        }
    }

    private var colorEditor: some View {
        CustomInkEditor(initialColor: sampledColor, dismissesOnSave: !returnsToCanvasAfterColorSave && !tutorial.isActive,
                        tutorial: tutorial) { preset in
            guard let index = library.palettes.firstIndex(where: { $0.id == currentID }) else { return }
            if let existing = library.palettes[index].palette.allColors.first(where: { $0.rgba == preset.rgba }) {
                if !library.palettes[index].palette.selectedIDs.contains(existing.id) {
                    library.palettes[index].palette.selectedIDs.append(existing.id)
                }
            } else {
                library.palettes[index].palette.customColors.append(preset)
                library.palettes[index].palette.selectedIDs.append(preset.id)
                addedColors.append((currentID, preset.id))
            }
            if returnsToCanvasAfterColorSave || tutorial.isActive {
                // Also select an existing swatch when the sampled color
                // already belongs to the palette.
                controller.pencilStyle.color = preset.rgba
                confirm()
            }
        }
    }

    private func setBrowsing(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            browsing = value
        }
    }

    private func beginEditing() {
        guard !editing, !tutorial.isActive else { return }
        guard let palette = library.palettes.first(where: { $0.id == currentID }) else { return }
        paletteBeforeEditing = palette
        editing = true
        setBrowsing(false)
    }

    private func cancelEditing() {
        guard let original = paletteBeforeEditing,
              let index = library.palettes.firstIndex(where: { $0.id == original.id }) else { return }
        library.palettes[index] = original
        paletteBeforeEditing = nil
        sampledColor = nil
        showsColorEditor = false
        editing = false
        setBrowsing(false)
    }

    private func finishEditingOrConfirm() {
        if editing && !browsing {
            paletteBeforeEditing = nil
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
                let regularCardWidth = min(width * 0.68, availableHeight)
                let tutorialTop = max(0, (viewport.size.height - titleHeight - regularCardWidth
                    - buttonHeight - verticalGap * 2 - bottomPadding) / 2 + 28)
                // Keep the title in place and fit the whole outline above the
                // measured coach card, including the 1.15x reminder animation.
                let tutorialStripHeight = max(1, (viewport.size.height - tutorialHintReservedHeight
                    - 6 - tutorialTop) / 1.075)
                let cardWidth = tutorial.isActive
                    ? min(regularCardWidth, max(1, tutorialStripHeight - titleHeight - verticalGap))
                    : regularCardWidth
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
                                guard pendingDeletionID == nil, movingID == nil,
                                      tutorial.permits([.createPalette]) else { return }
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
                            .disabled(pendingDeletionID != nil || !tutorial.permits([.createPalette]))
                            .accessibilityLabel(L10n.text("New palette"))
                            .accessibilityAdjustableAction { adjustPage($0) }
                        }
                        .tutorialHint(tutorial, steps: [.createPalette])
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
                    // Clip neighboring pages horizontally, leaving vertical room
                    // for the tutorial's animated title and card.
                    .padding(.vertical, tutorial.isActive ? viewport.size.height : 0)
                    .clipped()
                    .padding(.vertical, tutorial.isActive ? -viewport.size.height : 0)
                    // A recognized swipe must cancel the card's button press.
                    .coordinateSpace(name: "paletteReordering")
                    // Once a swipe is recognized, cancel the card button's tap.
                    // Leave the revealed Delete button outside this arbitration.
                    .highPriorityGesture(pageGesture(stride: stride),
                                         including: pendingDeletionID == nil ? .all : .subviews)
                    .animation(pageAnimation, value: carouselTranslation)
                    .overlay {
                        if tutorial.permits([.findNewPalette]) && tutorial.isActive {
                            TutorialToolSwipeGuide(direction: -1)
                        }
                    }
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

                    Button {
                        if pendingDeletionID != nil {
                            withAnimation(pageAnimation) { pendingDeletionID = nil }
                        } else if currentID != addID { beginEditing() }
                    } label: {
                        Text(L10n.text(pendingDeletionID != nil ? "Cancel" : "Edit"))
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 12)
                            .frame(width: width * 0.46, height: buttonHeight)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background {
                        Capsule().fill(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.08)],
                                                      startPoint: .top, endPoint: .bottom))
                    }
                    .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
                    .contentShape(Capsule())
                    .opacity(tutorial.isActive || currentID == addID || movingID != nil ? 0 : 1)
                    .allowsHitTesting(!tutorial.isActive && currentID != addID && movingID == nil)
                    .accessibilityHidden(tutorial.isActive || currentID == addID || movingID != nil)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: currentID == addID)
                }
                .padding(.bottom, bottomPadding)
                .padding(.top, tutorial.isActive ? tutorialTop : 0)
                .frame(width: width, height: viewport.size.height,
                       alignment: tutorial.isActive ? .top : .center)
            }
            // Tutorial palette browsing also uses the space above the carousel;
            // the shared lesson card remains an independent overlay below.
            .ignoresSafeArea(.container, edges: tutorial.isActive ? .vertical : .bottom)
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
                                     including: pendingDeletionID == nil && !tutorial.isActive ? .all : .none)
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
            guard pendingDeletionID == nil, movingID == nil, !tutorial.isActive else { return }
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
        .accessibilityActions {
            if canDeletePalette {
                Button(L10n.text("Delete")) { delete(entry.id) }
            }
        }
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
    private var canDeletePalette: Bool { library.visiblePalettes.count > 1 }
    private var pageIndex: Int { pageIDs.firstIndex(of: currentID) ?? 0 }
    private var pageAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private func selectPage(by step: Int) {
        guard pendingDeletionID == nil, movingID == nil, tutorial.permits([.findNewPalette, .createPalette]) else { return }
        let wasNewPalette = currentID == addID
        let target = min(pageIDs.count - 1, max(0, pageIndex + step))
        withAnimation(pageAnimation) { currentID = pageIDs[target] }
        if wasNewPalette && currentID != addID {
            tutorial.record(.returnedToPalettes)
        } else if currentID == addID {
            tutorial.record(.foundNewPalette)
        }
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
                guard pendingDeletionID == nil, movingID == nil, tutorial.permits([.findNewPalette, .createPalette]) else { return }
                transaction.animation = nil
                if abs(value.translation.height) > abs(value.translation.width) {
                    if canDeletePalette, currentID != addID {
                        translation.height = min(0, value.translation.height)
                    }
                    return
                }
                let atEdge = (pageIndex == 0 && value.translation.width > 0)
                    || (pageIndex == pageIDs.count - 1 && value.translation.width < 0)
                translation.width = value.translation.width * (atEdge ? 0.2 : 1)
            }
            .onEnded { value in
                guard pendingDeletionID == nil, movingID == nil, tutorial.permits([.findNewPalette, .createPalette]) else { return }
                if abs(value.translation.height) > abs(value.translation.width) {
                    if canDeletePalette, currentID != addID, value.translation.height < -30 {
                        withAnimation(pageAnimation) { pendingDeletionID = currentID }
                    }
                    return
                }
                let travel = value.predictedEndTranslation.width
                guard abs(travel) > stride * 0.2 else { return }
                selectPage(by: travel < 0 ? 1 : -1)
            }
    }

    private var showsEmptyPaletteClose: Bool {
        !browsing && !editing && library.palettes.contains {
            $0.id == currentID && $0.palette.allColors.isEmpty
        }
    }

    private func discardEmptyPalette() {
        guard showsEmptyPaletteClose,
              let index = library.palettes.firstIndex(where: { $0.id == currentID }) else { return }
        let discardedID = currentID
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            library.palettes.remove(at: index)
            addedColors.removeAll { $0.paletteID == discardedID }
            if library.activeID == discardedID {
                library.activeID = library.palettes.first(where: { !$0.palette.selectedColors.isEmpty })?.id
                    ?? library.palettes.first?.id ?? InkPaletteLibrary.initial.activeID
            }
            currentID = addID
            browsing = true
        }
    }

    private var canConfirm: Bool {
        library.palettes.contains { $0.id == currentID && !$0.palette.selectedColors.isEmpty }
    }

    private func confirm() {
        guard canConfirm else { return }
        updateGeneratedName()
        library.activeID = currentID
        let palette = library.activePalette
        if let lastAdded = addedColors.reversed().first(where: { entry in
            entry.paletteID == currentID && palette.allColors.contains { $0.id == entry.colorID }
        }), let color = palette.allColors.first(where: { $0.id == lastAdded.colorID }) {
            if let index = library.palettes.firstIndex(where: { $0.id == currentID }),
               !library.palettes[index].palette.selectedIDs.contains(color.id) {
                library.palettes[index].palette.selectedIDs.append(color.id)
            }
            controller.pencilStyle.color = color.rgba
        }
        onSave(library)
        if !tutorial.isActive { dismiss() }
    }

    private func addPalette() {
        let id = UUID().uuidString
        library.palettes.append(SavedInkPalette(id: id,
            palette: InkPalette(baseColors: [], title: "New palette", selectedIDs: [])))
        currentID = id
        editing = false
        browsing = false
        tutorial.record(.createdPalette)
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
        guard canDeletePalette,
              let index = library.palettes.firstIndex(where: { $0.id == id }) else { return }
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
