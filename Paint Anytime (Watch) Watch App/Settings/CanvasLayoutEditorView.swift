import SwiftUI

/// Presented full screen: a white canvas preview whose circles sit where the
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
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Color.white
                .ignoresSafeArea()
                .overlay { saveButton }
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
        GeometryReader { proxy in
            Button(action: save) {
                CanvasLayoutCircle {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Save and apply"))
            .position(x: proxy.size.width / 2,
                      y: (topControlMidY ?? MorphPanelGeometry.buttonDiameter) - proxy.frame(in: .global).minY)
        }
        .ignoresSafeArea()
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
        .accessibilityLabel(slotLabel(index))
        .accessibilityValue(assignment.isMorph ? "Morph" : L10n.text(assignment.actions[0].title))
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

    var body: some View {
        Label {
            Text(L10n.text(action.title))
        } icon: {
            switch action {
            case .clear: BroomIcon()
            case .brush: ToolIcon(instrument: instrument)
            case .eraserToggle: ToolIcon(instrument: .eraser)
            case .canvasEditor: CanvasLayoutIcon()
            default: Image(systemName: action.symbol)
            }
        }
    }
}
