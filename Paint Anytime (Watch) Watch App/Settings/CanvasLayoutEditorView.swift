import SwiftUI

/// Presented full screen: a white canvas preview whose circles sit where the
/// real controls do. Changes stay in a draft until the checkmark is tapped.
struct CanvasLayoutEditorView: View {
    /// The current tool, shown wherever Tool settings appears.
    let instrument: DrawingInstrument
    @AppStorage(CanvasControlLayout.storageKey) private var storedLayout = Data()
    @AppStorage(CanvasControlLayout.enabledKey) private var customLayoutEnabled = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = CanvasControlLayout.standard
    @State private var editingSlot: Int?
    @State private var topControlMidY: CGFloat?
    /// Global frames of the slot circles, for drawing morph contents beside them.
    @State private var slotFrames: [Int: CGRect] = [:]
    @State private var loaded = false
    /// The checkmark was tapped and the layout is being applied.
    @State private var isSaving = false
    /// Debug builds: on-screen touch readout for Reset and the checkmark.
    @State private var touchDebug: CanvasLayoutTouchDebug? = RenderDebug.isEnabled ? CanvasLayoutTouchDebug() : nil
    /// Global frames of Reset and the checkmark.
    @State private var topActionFrames: [CanvasLayoutTopAction: CGRect] = [:]
    /// The tutorial shows the editor as its own page: the draft starts from the original
    /// menus and the checkmark hands it back instead of storing it.
    @ObservedObject var tutorial = TutorialSession.inactive
    var onTutorialSave: ((CanvasControlLayout) -> Void)? = nil
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight

    @ViewBuilder var body: some View {
        if tutorial.isActive, let onTutorialSave {
            tutorialEditor(onSave: onTutorialSave)
        } else {
            editor
        }
    }

    private var editor: some View {
        NavigationStack {
            Color.white
                .ignoresSafeArea()
                // Most taps on Reset and the checkmark reach this content under them instead of
                // their Buttons (device readout: touches inside the checkmark's frame recorded
                // here, its Button saw none, though the glass still flashed). Do what they do,
                // like `forwardCanvasTap` on the canvas.
                .onTapGesture(coordinateSpace: .global) { forwardTopActionTap(at: $0) }
                .canvasLayoutTouchProbe("bg", debug: touchDebug)
                .overlay { morphPreviews }
                // Native toolbar slots, as on the canvas: the system clock
                // centres between the top buttons before it is hidden.
                .toolbar {
                    // Taking the cancellation slot also removes the cover's close button.
                    ToolbarItem(placement: .cancellationAction) {
                        slotButton(CanvasControlLayout.topLeadingSlot)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        slotButton(0)
                            // Toolbar items live in another coordinate space.
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: {
                                topControlMidY = $0
                                touchDebug?.topControlMidY = $0
                            }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        slotButton(1)
                        Spacer(minLength: 0)
                        slotButton(2)
                        Spacer(minLength: 0)
                        slotButton(3)
                        Spacer(minLength: 0)
                        slotButton(4)
                    }
                }
        }
        // Above the navigation bar: on watchOS 26 its clock area takes the
        // taps of anything drawn beneath it inside the stack.
        .overlay { topActions }
        .overlay {
            if let touchDebug {
                CanvasLayoutTouchDebugPanel(debug: touchDebug, isClockHiddenRequested: editingSlot == nil)
                    .padding(.horizontal, 30)
            }
        }
        // The shared loading state, centred over the whole editor; it also takes the taps
        // while the layout is applied.
        .overlay {
            if isSaving {
                LoadingDimOverlay()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        // Slides up like Layers and the More menu instead of a zooming push.
        .sheet(isPresented: Binding(
            get: { editingSlot != nil },
            set: { if !$0 { editingSlot = nil } }
        )) {
            if let slot = editingSlot {
                NavigationStack {
                    CanvasSlotEditorView(assignment: $draft.slots[slot], instrument: instrument,
                                         keptActions: lastCopies(in: slot),
                                         usedMorphIcons: morphIcons(excluding: slot),
                                         otherSlotNumbers: slotNumbers(excluding: slot))
                }
            }
        }
        .requestsHiddenClock(editingSlot == nil)
        // The cover is its own presentation, so the root host never sees this request.
        .modifier(ClockVisibilityHost())
        .onAppear {
            guard !loaded else { return }
            // Show the canvas as it is now: the custom layout or the original menus.
            draft = CanvasControlLayout.current(from: storedLayout, enabled: customLayoutEnabled)
            loaded = true
        }
    }

    /// The top row's circles centre `top + 18` from the screen's top and 30 pt from its sides,
    /// as on the canvas and in the editor.
    static let tutorialRowTop = MorphPanelGeometry(size: .zero, layoutDirection: .leftToRight).top
        + 18 - MorphPanelGeometry.buttonDiameter / 2
    static let tutorialRowInset: CGFloat = 30 - MorphPanelGeometry.buttonDiameter / 2

    /// Reset in the lesson empties both top circles, so the lesson starts the group from nothing.
    private static let tutorialEmptyLayout = CanvasControlLayout(
        slots: Array(repeating: .single(.nothing), count: CanvasControlLayout.original.slots.count))

    /// The lesson's editor: the original top menus with Reset and the checkmark between them,
    /// as in the editor, and no bottom row. Reset empties both circles, and an empty one then
    /// becomes a group; the action list replaces the page instead of a sheet, so the lesson
    /// card stays over it.
    private func tutorialEditor(onSave: @escaping (CanvasControlLayout) -> Void) -> some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: MorphPreviewLayout.gap) {
                HStack {
                    tutorialSlot(CanvasControlLayout.topLeadingSlot)
                    Spacer(minLength: 0)
                    tutorialResetButton
                    Spacer(minLength: 0)
                    Button {
                        guard tutorial.permits([.saveCanvasLayout]) else { return }
                        onSave(draft)
                    } label: {
                        CanvasLayoutCircle {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                                .tutorialHint(tutorial, steps: [.saveCanvasLayout])
                        }
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(tutorial.permits([.saveCanvasLayout]))
                    .accessibilityLabel(L10n.text("Save and apply"))
                    Spacer(minLength: 0)
                    tutorialSlot(0)
                }
                // Each group's actions in a column below its circle, as in the editor.
                HStack(alignment: .top) {
                    tutorialMorphPreview(CanvasControlLayout.topLeadingSlot)
                    Spacer(minLength: 0)
                    tutorialMorphPreview(0)
                }
                Spacer(minLength: 0)
            }
            // Where the canvas draws its top circles (`MorphPanelGeometry`): the clock band is
            // hidden, so the row ignores the safe area like the editor's toolbar buttons do.
            .padding(.horizontal, Self.tutorialRowInset)
            .padding(.top, Self.tutorialRowTop)
            .ignoresSafeArea()
            // No colour scheme of its own: like the editor's, the glass follows the app's.

            if let slot = editingSlot {
                CanvasSlotEditorView(assignment: $draft.slots[slot], instrument: instrument,
                                     keptActions: [], usedMorphIcons: morphIcons(excluding: slot),
                                     otherSlotNumbers: slotNumbers(excluding: slot), tutorial: tutorial,
                                     onTutorialClose: {
                                         withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                                             editingSlot = nil
                                         }
                                     })
                    // The list runs under the floating lesson card, like the tour's other lists.
                    .background(Color.black.ignoresSafeArea())
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // The editor's canvas hides the clock; the action list shows it between ✕ and the
        // icon button, as the editor's sheet does.
        .requestsHiddenClock(editingSlot == nil)
        .onAppear {
            guard !loaded else { return }
            draft = .original
            loaded = true
        }
        .onChange(of: tutorial.step) { _, step in
            // The chosen action has been shown; the list closes on the editor's canvas.
            guard step == .saveCanvasLayout, editingSlot != nil else { return }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { editingSlot = nil }
        }
    }

    private func tutorialSlot(_ index: Int) -> some View {
        let assignment = draft.slots[index]
        let choosable = assignment.isEmpty && tutorial.permits([.chooseEditorSlot])
        return Button {
            guard choosable else { return }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { editingSlot = index }
            tutorial.record(.choseEditorSlot)
        } label: {
            CanvasQuickActionIcon(action: assignment.actions[0], instrument: instrument,
                                  isMorph: assignment.isMorph, morphIcon: assignment.icon)
                .tutorialHint(tutorial, steps: [.chooseEditorSlot], isSuggested: assignment.isEmpty)
        }
        // The editor's slot style, so each watchOS draws the circles as the editor does there.
        .watchToolbarButtonStyle(diameter: MorphPanelGeometry.buttonDiameter, usesCanvasMaterial: true)
        // Not disabled: a dimmed circle would look unlike the editor's.
        .allowsHitTesting(choosable)
        .accessibilityLabel(slotLabel(index))
    }

    /// Dimmed like the editor's Reset with nothing to reset, until the lesson asks for it.
    private var tutorialResetButton: some View {
        let permitted = tutorial.permits([.resetEditorLayout])
        return Button {
            guard permitted else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { draft = Self.tutorialEmptyLayout }
            tutorial.record(.resetEditorLayout)
        } label: {
            CanvasLayoutCircle {
                Image(systemName: "arrow.counterclockwise")
                    .opacity(permitted ? 1 : 0.4)
                    .tutorialHint(tutorial, steps: [.resetEditorLayout])
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(permitted)
        .accessibilityLabel(L10n.text("Reset interface"))
    }

    /// A slot's group column, or an empty column of the circle's width.
    @ViewBuilder private func tutorialMorphPreview(_ index: Int) -> some View {
        let assignment = draft.slots[index]
        Group {
            if assignment.isMorph {
                morphPreview(assignment, layout: MorphPreviewLayout(row: MorphPreviewLayout.maximumRow, columns: 1))
                    .transition(.opacity)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .frame(width: MorphPanelGeometry.buttonDiameter)
        .accessibilityHidden(true)
    }

    /// watchOS has no centre toolbar placement, so Reset and the checkmark sit
    /// level with the measured top buttons, above the second and third bottom circles.
    private var topActions: some View {
        CanvasLayoutTopActions(topControlMidY: topControlMidY,
                               resetMidX: slotFrames[2]?.midX, saveMidX: slotFrames[3]?.midX,
                               canReset: draft != .original && !isSaving,
                               debug: touchDebug,
                               onReset: { perform(.reset, source: "action") },
                               onSave: { perform(.save, source: "action") },
                               onFrame: { topActionFrames[$0] = $1 })
    }

    /// Finger slop around the circles for forwarded taps; the two stay ~46 pt apart.
    private static let forwardedTapSlop: CGFloat = 6

    private func forwardTopActionTap(at location: CGPoint) {
        let nearest = topActionFrames
            .map { (action: $0.key, frame: $0.value,
                    distance: hypot(location.x - $0.value.midX, location.y - $0.value.midY)) }
            .filter { $0.distance <= $0.frame.width / 2 + Self.forwardedTapSlop }
            .min { $0.distance < $1.distance }
        guard let nearest else { return }
        perform(nearest.action, source: "fwd")
    }

    /// `source`: "action" from the Button, "fwd" from a tap forwarded by the content.
    private func perform(_ action: CanvasLayoutTopAction, source: String) {
        switch action {
        case .reset:
            touchDebug?.record("reset", source)
            // The Button is disabled then; a forwarded tap must not bypass that.
            guard draft != .original, !isSaving else { return }
            reset()
        case .save:
            touchDebug?.record("save", source)
            requestSave()
        }
    }

    /// Applying the layout rebuilds the canvas controls behind the cover on the main thread,
    /// and the dismissal waits for that work, so the tap looked ignored. Show the loading
    /// overlay first and apply once it is on screen.
    private func requestSave() {
        guard !isSaving else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isSaving = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if !save() {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isSaving = false }
            }
        }
    }

    /// Previews the original interface; like any edit it applies only with the checkmark.
    private func reset() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { draft = .original }
    }

    private func slotButton(_ index: Int) -> some View {
        let assignment = draft.slots[index]
        return Button {
            touchDebug?.record("slot\(index)", "action")
            guard !isSaving else { return }
            editingSlot = index
        } label: {
            CanvasQuickActionIcon(action: assignment.actions[0], instrument: instrument,
                                  isMorph: assignment.isMorph, morphIcon: assignment.icon)
        }
        .watchToolbarButtonStyle(diameter: MorphPanelGeometry.buttonDiameter, usesCanvasMaterial: true)
        // The system animates only the bottom bar in; the top buttons share the
        // checkmark's entrance. Inside the measurement, so frames stay unscaled.
        .modifier(CanvasLayoutEntrance(isEnabled: CustomCanvasControls.isTop(index)))
        // Toolbar items live in another coordinate space.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { slotFrames[index] = $0 }
        .accessibilityLabel(slotLabel(index))
        .accessibilityValue(assignment.isMorph
            ? L10n.format("Morph: %@", assignment.actions.map { L10n.text($0.title) }.joined(separator: ", "))
            : L10n.text(assignment.actions[0].title))
    }

    /// A small column of each morph's actions, on the side it opens towards on the
    /// canvas: below the top circles and above the bottom row.
    private var morphPreviews: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ForEach(draft.slots.indices.filter { draft.slots[$0].isMorph }, id: \.self) { index in
                if let frame = slotFrames[index], let layout = previewLayout(for: index) {
                    let height = layout.height(count: draft.slots[index].actions.count)
                    let isTop = CustomCanvasControls.isTop(index)
                    let gap = MorphPreviewLayout.gap
                    morphPreview(draft.slots[index], layout: layout)
                        .position(x: frame.midX - origin.x,
                                  y: (isTop ? frame.maxY + gap + height / 2 : frame.minY - gap - height / 2) - origin.y)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One layout per column, so a top and a bottom morph that share it never
    /// overlap. Icons wrap into two columns before they get too small to read.
    private func previewLayout(for index: Int) -> MorphPreviewLayout? {
        guard let frame = slotFrames[index] else { return nil }
        let isTop = CustomCanvasControls.isTop(index)
        // The circle across the canvas in the same column, if any.
        let opposite = draft.slots.indices
            .filter { CustomCanvasControls.isTop($0) != isTop }
            .compactMap { other in slotFrames[other].map { (other, $0) } }
            .filter { abs($0.1.midX - frame.midX) < frame.width / 2 }
            .min { abs($0.1.midX - frame.midX) < abs($1.1.midX - frame.midX) }
        guard let opposite else { return MorphPreviewLayout(row: MorphPreviewLayout.maximumRow, columns: 1) }
        let top = isTop ? frame : opposite.1
        let bottom = isTop ? opposite.1 : frame
        var counts = [draft.slots[index].actions.count]
        if draft.slots[opposite.0].isMorph { counts.append(draft.slots[opposite.0].actions.count) }
        let room = bottom.minY - top.maxY - MorphPreviewLayout.gap * 3
            - MorphPreviewLayout.padding * 2 * CGFloat(counts.count)
        func layout(columns: Int) -> MorphPreviewLayout {
            let lines = counts.reduce(0) { $0 + ($1 + columns - 1) / columns }
            return MorphPreviewLayout(row: max(0, min(MorphPreviewLayout.maximumRow, room / CGFloat(lines))),
                                      columns: columns)
        }
        let single = layout(columns: 1)
        return single.row >= MorphPreviewLayout.minimumSingleColumnRow ? single : layout(columns: 2)
    }

    private func morphPreview(_ assignment: CanvasControlAssignment, layout: MorphPreviewLayout) -> some View {
        let lines = stride(from: 0, to: assignment.actions.count, by: layout.columns).map {
            Array(assignment.actions[$0..<min($0 + layout.columns, assignment.actions.count)])
        }
        return VStack(spacing: 0) {
            ForEach(lines.indices, id: \.self) { line in
                HStack(spacing: 0) {
                    ForEach(lines[line]) { action in
                        CanvasQuickActionIcon(action: action, instrument: instrument)
                            .scaleEffect(layout.row / 26)
                            .frame(width: layout.row + 4, height: layout.row)
                    }
                }
            }
        }
        .padding(.vertical, MorphPreviewLayout.padding)
        .padding(.horizontal, layout.columns > 1 ? MorphPreviewLayout.padding : 0)
        .modifier(MorphPreviewSurface(cornerRadius: (layout.row + MorphPreviewLayout.padding * 2) / 2))
    }

    private func slotLabel(_ index: Int) -> String {
        switch index {
        case CanvasControlLayout.topLeadingSlot: L10n.text("Top left control")
        case 0: L10n.text("Top right control") + " 1"
        default: L10n.text("Bottom control") + " \(index)"
        }
    }

    private func morphIcons(excluding index: Int) -> Set<String> {
        Set(draft.slots.indices.filter { $0 != index && draft.slots[$0].isMorph }
            .map { CanvasMorphIcon.resolve(draft.slots[$0].icon) })
    }

    /// Slots numbered in reading order: top left 1, top right 2, bottom row 3...6.
    private static func displayNumber(of index: Int) -> Int {
        index == CanvasControlLayout.topLeadingSlot ? 1 : index + 2
    }

    /// Where each action already sits outside this slot, as sorted slot numbers.
    /// Nothing and Close are skipped: they are no feature placed on the canvas.
    private func slotNumbers(excluding index: Int) -> [CanvasQuickAction: [Int]] {
        var numbers: [CanvasQuickAction: [Int]] = [:]
        for other in draft.slots.indices where other != index {
            for action in Set(draft.slots[other].actions) where action != .nothing && action != .closeMorph {
                numbers[action, default: []].append(Self.displayNumber(of: other))
            }
        }
        return numbers.mapValues { $0.sorted() }
    }

    /// Required actions this slot holds that no other slot does: every choice here must keep them.
    /// An action already missing from the canvas, as in a layout saved without Undo, binds no slot.
    private func lastCopies(in index: Int) -> [CanvasQuickAction] {
        CanvasControlLayout.requiredActions.filter { action in
            draft.slots[index].actions.contains(action)
                && !draft.slots.indices.contains { $0 != index && draft.slots[$0].actions.contains(action) }
        }
    }

    /// Returns false when the draft could not be stored and the editor stays open.
    private func save() -> Bool {
        // Restore the original interface itself, not a custom layout that merely copies it.
        if draft == .original {
            storedLayout = Data()
            customLayoutEnabled = false
            dismiss()
            return true
        }
        guard let data = try? JSONEncoder().encode(draft),
              CanvasControlLayout.decode(data) != nil else { return false }
        storedLayout = data
        customLayoutEnabled = true
        dismiss()
        return true
    }
}

private enum CanvasLayoutTopAction { case reset, save }

/// Reset and the checkmark are no toolbar items, so they play the bottom bar's entrance themselves.
private struct CanvasLayoutTopActions: View {
    let topControlMidY: CGFloat?
    /// Global centres of the bottom circles to align with; unmeasured, they fall back to fixed fractions.
    let resetMidX: CGFloat?
    let saveMidX: CGFloat?
    let canReset: Bool
    let debug: CanvasLayoutTouchDebug?
    let onReset: () -> Void
    let onSave: () -> Void
    /// Global frames, for the editor to forward taps that miss these Buttons.
    let onFrame: (CanvasLayoutTopAction, CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let y = (topControlMidY ?? MorphPanelGeometry.buttonDiameter) - frame.minY
            Button(action: onReset) {
                CanvasLayoutCircle {
                    Image(systemName: "arrow.counterclockwise")
                        // Dim only the symbol: a translucent circle washes out to white on the preview.
                        .opacity(canReset ? 1 : 0.4)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canReset)
            .accessibilityLabel(L10n.text("Reset interface"))
            .canvasLayoutTouchProbe("reset", debug: debug)
            // Inside the entrance, so the frame stays unscaled.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame(.reset, $0) }
            .modifier(CanvasLayoutEntrance())
            .position(x: resetMidX.map { $0 - frame.minX } ?? proxy.size.width * 0.375, y: y)

            Button(action: onSave) {
                CanvasLayoutCircle {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            // `requestSave` ignores repeated taps.
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Save and apply"))
            .canvasLayoutTouchProbe("save", debug: debug)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame(.save, $0) }
            .modifier(CanvasLayoutEntrance())
            .position(x: saveMidX.map { $0 - frame.minX } ?? proxy.size.width * 0.625, y: y)
        }
        .ignoresSafeArea()
    }
}

/// Grows and fades a control in like the system bottom bar does. Its own state
/// keeps the animation from rebuilding the editor's toolbar, which would cancel
/// the system entrance of the bottom buttons.
private struct CanvasLayoutEntrance: ViewModifier {
    var isEnabled = true
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isShown || reduceMotion || !isEnabled ? 1 : 0.5)
            .opacity(isShown || !isEnabled ? 1 : 0)
            .onAppear {
                guard isEnabled, !isShown else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)) {
                    isShown = true
                }
            }
    }
}

/// Same glass as the canvas controls, so the preview matches the real canvas.
private struct CanvasLayoutCircle<Icon: View>: View {
    @ViewBuilder let icon: Icon

    var body: some View {
        icon.font(.system(size: 17, weight: .semibold))
            .frame(width: MorphPanelGeometry.buttonDiameter, height: MorphPanelGeometry.buttonDiameter)
            .contentShape(Circle())
            .modifier(CanvasMorphGlass(adaptsToCanvas: true))
    }
}

private struct CanvasSlotEditorView: View {
    @Binding var assignment: CanvasControlAssignment
    let instrument: DrawingInstrument
    /// More, Undo or Redo this slot holds as the last copy on the canvas, so every
    /// choice here must keep them. Two or more fit only in a group.
    let keptActions: [CanvasQuickAction]
    /// Icons of the other morph slots, avoided when this one gets its first icon.
    let usedMorphIcons: Set<String>
    /// Numbers of the other slots that already hold each action.
    let otherSlotNumbers: [CanvasQuickAction: [Int]]
    /// The lesson groups the eyedropper and the eraser toggle and lists only those two.
    @ObservedObject var tutorial = TutorialSession.inactive
    /// The lesson's ✕: the list is a page of the lesson, not a sheet with its own close button.
    var onTutorialClose: (() -> Void)? = nil
    @Environment(\.tutorialHintReservedHeight) private var tutorialHintReservedHeight
    /// The lesson's actions, in the order the lesson names them.
    private static let tutorialActions: [CanvasQuickAction] = [.eyedropper, .eraserToggle]
    /// The lesson shows the icon list in place, as it shows this list: it has no navigation bar.
    @State private var showsTutorialIconPicker = false
    @State private var isGrouped = false
    /// The group's actions in tap order; the first is the one kept when ungrouping.
    @State private var selection: [CanvasQuickAction] = []
    @State private var icon = CanvasMorphIcon.standard
    @State private var loaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { isGrouped }, set: setGrouped)) {
                    Text(L10n.text("Group actions"))
                        .tutorialHint(tutorial, steps: [.groupEditorActions])
                }
                .disabled((isGrouped && keptActions.count > 1)
                          || (tutorial.isActive && !tutorial.permits([.groupEditorActions])))
            } footer: {
                if isGrouped && keptActions.count > 1 {
                    Text(L10n.text("Some of these actions are nowhere else on the canvas, so the group stays."))
                }
            }
            Section {
                // Stays open to show the choice; the sheet's close button dismisses it.
                ForEach(tutorial.isActive ? Self.tutorialActions : CanvasQuickAction.menuOrder(inMorph: isGrouped)) { action in
                    Button { select(action) } label: {
                        HStack {
                            CanvasQuickActionLabel(action: action, instrument: instrument,
                                                   caption: placementCaption(for: action))
                            Spacer()
                            marker(for: action)
                        }
                        .tutorialHint(tutorial, steps: [.chooseEditorActions], isSuggested: !selection.contains(action))
                    }
                    .disabled(isDisabled(action))
                    .accessibilityAddTraits(selection.contains(action) ? .isSelected : [])
                }
            } header: {
                // The lesson's group holds only its two actions.
                if isGrouped {
                    Text("\(selection.count)/\(tutorial.isActive ? Self.tutorialActions.count : CanvasControlAssignment.maxMorphActions)")
                }
            } footer: {
                if isGrouped {
                    Text(L10n.text("Choose up to five actions. Their order follows your selection."))
                } else if let kept = keptActions.first {
                    Text(L10n.format("This is the last %@ button. Keep it here or in a group.",
                                     L10n.text(kept.title)))
                }
            }
        }
        // The lesson's card floats over the list; the last rows still scroll above it.
        .contentMargins(.bottom, tutorial.isActive ? tutorialHintReservedHeight : 0, for: .scrollContent)
        .overlay {
            // The lesson shows the icon list in place of a pushed page, with the same title
            // and Back. Choosing an icon keeps it open, as the editor's pushed list does.
            if showsTutorialIconPicker {
                CanvasMorphIconPicker(icon: $icon) {
                    commit()
                    tutorial.record(.choseGroupIcon)
                }
                .contentMargins(.bottom, tutorialHintReservedHeight, for: .scrollContent)
                .background(Color.black.ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .navigationTitle(L10n.text(showsTutorialIconPicker ? "Icon" : "Action"))
        .toolbar {
            if tutorial.isActive { tutorialToolbar }
            // Shows the group's icon and opens the full icon list. Always installed,
            // so the title keeps its place; ungrouped, it fades and shrinks away.
            if !tutorial.isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CanvasMorphIconPicker(icon: $icon, onSelect: commit)
                    } label: {
                        // The circle is part of the label, so it fades with the icon: the
                        // toolbar's own chrome ignores opacity on watchOS 27 and stays visible.
                        CanvasLayoutCircle {
                            Image(systemName: icon)
                        }
                    }
                    .watchToolbarButtonStyle(diameter: MorphPanelGeometry.buttonDiameter, hidesNativeChrome: true)
                    .accessibilityLabel(L10n.text("Icon"))
                    .scaleEffect(isGrouped || reduceMotion ? 1 : 0.5)
                    .opacity(isGrouped ? 1 : 0)
                    .allowsHitTesting(isGrouped)
                    .accessibilityHidden(!isGrouped)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            isGrouped = assignment.isMorph
            selection = assignment.actions.filter { $0 != .nothing }
            icon = assignment.isMorph ? CanvasMorphIcon.resolve(assignment.icon)
                : CanvasMorphIcon.symbols.filter { !usedMorphIcons.contains($0) }.randomElement()
                    ?? CanvasMorphIcon.standard
            loaded = true
        }
    }

    /// The editor's sheet bar in the lesson: ✕ (Back in the icon list) and the group's icon.
    /// Both stay installed, so the clock and the title keep their places.
    @ToolbarContentBuilder private var tutorialToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let back: Set<TutorialStep> = showsTutorialIconPicker ? [.leaveIconPicker] : [.closeActionList]
            let permitted = tutorial.permits(back)
            Button {
                guard permitted else { return }
                if showsTutorialIconPicker {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { showsTutorialIconPicker = false }
                    tutorial.record(.leftIconPicker)
                } else {
                    tutorial.record(.closedActionList)
                    onTutorialClose?()
                }
            } label: {
                Image(systemName: showsTutorialIconPicker ? "chevron.backward" : "xmark")
                    .tutorialHint(tutorial, steps: back)
                    .frame(width: 32, height: 32, alignment: .center)
                    .contentShape(Circle())
            }
            .watchToolbarButtonStyle()
            .disabled(!permitted)
            .accessibilityLabel(L10n.text(showsTutorialIconPicker ? "Back" : "Close"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            let shown = isGrouped && !showsTutorialIconPicker
            let permitted = tutorial.permits([.chooseGroupIcon])
            Button {
                guard permitted else { return }
                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { showsTutorialIconPicker = true }
            } label: {
                CanvasLayoutCircle {
                    Image(systemName: icon)
                        .tutorialHint(tutorial, steps: [.chooseGroupIcon])
                }
            }
            // The editor's icon button style.
            .watchToolbarButtonStyle(diameter: MorphPanelGeometry.buttonDiameter, hidesNativeChrome: true)
            .accessibilityLabel(L10n.text("Icon"))
            .scaleEffect(shown || reduceMotion ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown && permitted)
            .accessibilityHidden(!shown)
        }
    }

    /// A group shows its order as numbers; a single action shows one checkmark.
    @ViewBuilder private func marker(for action: CanvasQuickAction) -> some View {
        if isGrouped {
            // The number is the action's row in the opened morph, from the top.
            if let order = selection.firstIndex(of: action) {
                Image(systemName: "\(order + 1).circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        } else if assignment.actions == [action] {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    /// Text, not colour: green already marks this slot's own choice.
    private func placementCaption(for action: CanvasQuickAction) -> String? {
        guard let numbers = otherSlotNumbers[action], !numbers.isEmpty else { return nil }
        if numbers.count == 1 { return L10n.format("In slot %d", numbers[0]) }
        return L10n.format("In slots %@", numbers.map(String.init).joined(separator: ", "))
    }

    private func isDisabled(_ action: CanvasQuickAction) -> Bool {
        if tutorial.isActive { return !tutorial.permits([.chooseEditorActions]) }
        if isGrouped {
            return (selection.count == CanvasControlAssignment.maxMorphActions && !selection.contains(action))
                || keptActions.contains(action)
        }
        return keptActions.first.map { action != $0 } ?? false
    }

    /// Grouping keeps the current action as number one; ungrouping keeps only the first.
    private func setGrouped(_ grouped: Bool) {
        // The lesson only turns grouping on, once.
        if tutorial.isActive {
            guard grouped, tutorial.permits([.groupEditorActions]) else { return }
        }
        // One spring for the counter, the markers, the rows and the icon button,
        // in both directions.
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)) {
            applyGrouped(grouped)
        }
        if tutorial.isActive { tutorial.record(.groupedEditorActions) }
    }

    private func applyGrouped(_ grouped: Bool) {
        isGrouped = grouped
        if grouped {
            selection = assignment.actions.filter { $0 != .nothing }
            for kept in keptActions.reversed() where !selection.contains(kept) { selection.insert(kept, at: 0) }
            commit()
        } else {
            // A single circle never offers Close, and a last required action must stay.
            // The toggle is disabled while the group holds two of them.
            let first = keptActions.first ?? selection.first(where: { $0 != .closeMorph }) ?? .nothing
            selection = first == .nothing ? [] : [first]
            assignment = .single(first)
        }
    }

    private func select(_ action: CanvasQuickAction) {
        if tutorial.isActive {
            guard isGrouped, tutorial.permits([.chooseEditorActions]) else { return }
            if selection.contains(action) { selection.removeAll { $0 == action } } else { selection.append(action) }
            commit()
            if Set(selection) == Set(Self.tutorialActions) { tutorial.record(.choseEditorActions) }
            return
        }
        if isGrouped {
            if selection.contains(action) { selection.removeAll { $0 == action } }
            else if selection.count < CanvasControlAssignment.maxMorphActions { selection.append(action) }
            commit()
        } else {
            selection = action == .nothing ? [] : [action]
            assignment = .single(action)
        }
    }

    /// Each tap applies at once. An empty group keeps the previous assignment
    /// rather than an invalid morph.
    private func commit() {
        guard isGrouped, !selection.isEmpty, keptActions.allSatisfy({ selection.contains($0) }) else { return }
        assignment = .group(selection, icon: icon == CanvasMorphIcon.standard ? nil : icon)
    }
}

private struct CanvasMorphIconPicker: View {
    @Binding var icon: String
    let onSelect: () -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 6) {
                ForEach(CanvasMorphIcon.symbols, id: \.self) { symbol in
                    Button {
                        icon = symbol
                        onSelect()
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(icon == symbol ? Color.green : Color.gray.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(L10n.text("Icon"))
    }
}

struct CanvasQuickActionLabel: View {
    let action: CanvasQuickAction
    let instrument: DrawingInstrument
    /// A secondary line under the title, such as the other slots holding this action.
    var caption: String? = nil
    @AppStorage(WatchSketchAssist.phoneAvailabilityKey) private var sketchAssistOnPhone = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text(action.title))
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            switch action {
            case .clear: BroomIcon()
            case .brush, .eraserToggle: ToolIcon(instrument: instrument)
            case .canvasEditor: CanvasLayoutIcon()
            case .palettes: CurrentPaletteIcon()
            case .sketchAssist:
                Image(systemName: action.symbol).modifier(SketchAssistLock(isLocked: !sketchAssistOnPhone))
            default: Image(systemName: action.symbol)
            }
        }
        // Keeps the icon centred on titles that wrap to several lines.
        .labelStyle(CenteredMenuLabelStyle())
    }
}

/// The plate behind a morph preview. It only shows what a morph holds, so on every
/// watchOS it stays flat and low-contrast: no glass or material that would make it
/// read as a button like the circles.
private struct MorphPreviewSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.black.opacity(0.35))
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius))
            // The editor's canvas is always white, whatever the system appearance.
            .environment(\.colorScheme, .light)
    }
}

private struct MorphPreviewLayout {
    static let gap: CGFloat = 4
    static let padding: CGFloat = 3
    static let maximumRow: CGFloat = 18
    static let minimumSingleColumnRow: CGFloat = 14

    let row: CGFloat
    let columns: Int

    func height(count: Int) -> CGFloat {
        row * CGFloat((count + columns - 1) / columns) + Self.padding * 2
    }
}
