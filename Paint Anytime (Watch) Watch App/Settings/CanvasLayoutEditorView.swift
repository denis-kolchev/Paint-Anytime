import SwiftUI

/// Presented as a sheet: a white canvas preview whose circles sit where the
/// real controls do. Changes stay in a draft until the checkmark is tapped.
struct CanvasLayoutEditorView: View {
    /// The current tool, shown wherever Tool settings appears.
    let instrument: DrawingInstrument
    @AppStorage(CanvasControlLayout.storageKey) private var storedLayout = Data()
    @AppStorage(CanvasControlLayout.enabledKey) private var customLayoutEnabled = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CanvasControlLayout.standard
    @State private var editingSlot: Int?
    @State private var topControlMidY: CGFloat?
    /// Global frames of the slot circles, for drawing morph contents beside them.
    @State private var slotFrames: [Int: CGRect] = [:]
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Color.white
                .ignoresSafeArea()
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
        .overlay { saveButton }
        // Slides up like Layers and the More menu instead of a zooming push.
        .sheet(isPresented: Binding(
            get: { editingSlot != nil },
            set: { if !$0 { editingSlot = nil } }
        )) {
            if let slot = editingSlot {
                NavigationStack {
                    CanvasSlotEditorView(assignment: $draft.slots[slot], instrument: instrument,
                                         keepsMore: !otherSlotsContainMore(slot),
                                         usedMorphIcons: morphIcons(excluding: slot))
                }
            }
        }
        .requestsHiddenClock(editingSlot == nil)
        // The cover is its own presentation, so the root host never sees this request.
        .modifier(ClockVisibilityHost())
        .onAppear {
            guard !loaded else { return }
            // Show the canvas as it is now: the custom layout or the original menus.
            draft = (customLayoutEnabled ? CanvasControlLayout.decode(storedLayout) : nil) ?? .original
            loaded = true
        }
    }

    /// watchOS has no centre toolbar placement, so the checkmark sits in the
    /// clock's place, level with the measured top buttons.
    private var saveButton: some View {
        CanvasLayoutSaveButton(topControlMidY: topControlMidY, action: save)
    }

    private func slotButton(_ index: Int) -> some View {
        let assignment = draft.slots[index]
        return Button {
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
            ? "Morph: " + assignment.actions.map { L10n.text($0.title) }.joined(separator: ", ")
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
        .foregroundStyle(.white)
        .padding(.vertical, MorphPreviewLayout.padding)
        .padding(.horizontal, layout.columns > 1 ? MorphPreviewLayout.padding : 0)
        .background(Color.black.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: (layout.row + MorphPreviewLayout.padding * 2) / 2))
        .environment(\.colorScheme, .dark)
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

    private func otherSlotsContainMore(_ index: Int) -> Bool {
        draft.slots.indices.contains { $0 != index && draft.slots[$0].actions.contains(.more) }
    }

    private func save() {
        // Restore the original interface itself, not a custom layout that merely copies it.
        if draft == .original {
            storedLayout = Data()
            customLayoutEnabled = false
            dismiss()
            return
        }
        guard let data = try? JSONEncoder().encode(draft),
              CanvasControlLayout.decode(data) != nil else { return }
        storedLayout = data
        customLayoutEnabled = true
        dismiss()
    }
}

/// The checkmark is no toolbar item, so it plays the bottom bar's entrance itself.
private struct CanvasLayoutSaveButton: View {
    let topControlMidY: CGFloat?
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Button(action: action) {
                CanvasLayoutCircle {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Save and apply"))
            .modifier(CanvasLayoutEntrance())
            .position(x: proxy.size.width / 2,
                      y: (topControlMidY ?? MorphPanelGeometry.buttonDiameter) - proxy.frame(in: .global).minY)
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
    /// This slot holds the last More, so every choice here must keep it.
    let keepsMore: Bool
    let usedMorphIcons: Set<String>

    var body: some View {
        List {
            NavigationLink {
                CanvasMorphSelectionView(assignment: $assignment, instrument: instrument, keepsMore: keepsMore,
                                         usedMorphIcons: usedMorphIcons)
            } label: {
                HStack {
                    Label("Morph", systemImage: "square.grid.2x2")
                        .labelStyle(CenteredMenuLabelStyle())
                    Spacer()
                    if assignment.isMorph {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            ForEach(CanvasQuickAction.menuOrder(inMorph: false)) { action in
                Button {
                    // Stays open to show the choice; the sheet's close button dismisses it.
                    assignment = .single(action)
                } label: {
                    HStack {
                        CanvasQuickActionLabel(action: action, instrument: instrument)
                        Spacer()
                        if !assignment.isMorph && assignment.actions == [action] {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(keepsMore && action != .more)
            }
            if keepsMore {
                Text(L10n.text("This is the last More button. Keep it here or inside Morph."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(L10n.text("Action"))
    }
}

private struct CanvasMorphSelectionView: View {
    @Binding var assignment: CanvasControlAssignment
    let instrument: DrawingInstrument
    let keepsMore: Bool
    /// Icons of the other morph slots, avoided when this one gets its first icon.
    let usedMorphIcons: Set<String>
    @State private var selection: [CanvasQuickAction] = []
    @State private var icon = CanvasMorphIcon.standard
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach(CanvasQuickAction.menuOrder(inMorph: true)) { action in
                    Button {
                        if selection.contains(action) { selection.removeAll { $0 == action } }
                        else if selection.count < CanvasControlAssignment.maxMorphActions { selection.append(action) }
                        commit()
                    } label: {
                        HStack {
                            CanvasQuickActionLabel(action: action, instrument: instrument)
                            Spacer()
                            // The number is the action's row in the opened morph, from the top.
                            if let order = selection.firstIndex(of: action) {
                                Image(systemName: "\(order + 1).circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled((selection.count == CanvasControlAssignment.maxMorphActions && !selection.contains(action))
                              || (keepsMore && action == .more))
                    .accessibilityAddTraits(selection.contains(action) ? .isSelected : [])
                }
            } header: {
                Text("\(selection.count)/\(CanvasControlAssignment.maxMorphActions)")
            } footer: {
                Text(L10n.text("Choose up to five actions. Their order follows your selection."))
            }
        }
        .navigationTitle("Morph")
        .toolbar {
            // Shows the current icon and opens the full icon list.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CanvasMorphIconPicker(icon: $icon, onSelect: commit)
                } label: {
                    Image(systemName: icon)
                }
                .accessibilityLabel(L10n.text("Icon"))
            }
        }
        .onAppear {
            guard !loaded else { return }
            selection = assignment.actions
            if keepsMore && !selection.contains(.more) { selection.insert(.more, at: 0) }
            icon = assignment.isMorph ? CanvasMorphIcon.resolve(assignment.icon)
                : CanvasMorphIcon.symbols.filter { !usedMorphIcons.contains($0) }.randomElement()
                    ?? CanvasMorphIcon.standard
            loaded = true
        }
    }

    /// No Done button: each tap applies at once, so Back keeps it. An empty
    /// selection keeps the previous assignment rather than an invalid morph.
    private func commit() {
        guard !selection.isEmpty, !keepsMore || selection.contains(.more) else { return }
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
    @AppStorage(WatchSketchAssist.phoneAvailabilityKey) private var sketchAssistOnPhone = false

    var body: some View {
        Label {
            Text(L10n.text(action.title))
        } icon: {
            switch action {
            case .clear: BroomIcon()
            case .brush, .eraserToggle: ToolIcon(instrument: instrument)
            case .canvasEditor: CanvasLayoutIcon()
            case .sketchAssist:
                Image(systemName: action.symbol).modifier(SketchAssistLock(isLocked: !sketchAssistOnPhone))
            default: Image(systemName: action.symbol)
            }
        }
        // Keeps the icon centred on titles that wrap to several lines.
        .labelStyle(CenteredMenuLabelStyle())
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
