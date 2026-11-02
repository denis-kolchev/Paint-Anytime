import SwiftUI

/// Presented full screen: a white canvas preview whose circles sit where the
/// real controls do. Changes stay in a draft until the checkmark is tapped.
struct CanvasLayoutEditorView: View {
    @AppStorage(CanvasControlLayout.storageKey) private var storedLayout = Data()
    @AppStorage(CanvasControlLayout.enabledKey) private var customLayoutEnabled = false
    @AppStorage("experimental.morphToolbar") private var usesMorphToolbar = true
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CanvasControlLayout.standard
    @State private var editingSlot: Int?
    @State private var resetsToOriginal = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            center
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.ignoresSafeArea())
                // Native toolbar slots, as on the canvas: the system clock
                // centres between the top buttons before it is hidden.
                .toolbar {
                    // Taking the cancellation slot also removes the cover's close button.
                    ToolbarItem(placement: .cancellationAction) {
                        slotButton(CanvasControlLayout.topLeadingSlot)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        slotButton(0)
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
                    CanvasSlotEditorView(assignment: $draft.slots[slot],
                                         keepsMore: !otherSlotsContainMore(slot))
                }
            }
        }
        .requestsHiddenClock(editingSlot == nil)
        // The cover is its own presentation, so the root host never sees this request.
        .modifier(ClockVisibilityHost())
        .onAppear {
            guard !loaded else { return }
            draft = CanvasControlLayout.decode(storedLayout) ?? .standard
            loaded = true
        }
    }

    private var center: some View {
        HStack(spacing: 10) {
            Button(action: { dismiss() }) {
                CanvasLayoutCircle {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Cancel"))
            // Previews the original layout; the checkmark makes it permanent.
            Button {
                draft = .standard
                resetsToOriginal = true
            } label: {
                CanvasLayoutCircle {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Use standard layout"))
            Button(action: save) {
                CanvasLayoutCircle {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Save and apply"))
        }
    }

    private func slotButton(_ index: Int) -> some View {
        let assignment = draft.slots[index]
        return Button {
            editingSlot = index
        } label: {
            CanvasQuickActionIcon(action: assignment.actions[0], instrument: .monoline,
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

    private func otherSlotsContainMore(_ index: Int) -> Bool {
        draft.slots.indices.contains { $0 != index && draft.slots[$0].actions.contains(.more) }
    }

    private func save() {
        // Untouched after a reset: restore the original interface itself,
        // not a custom layout that merely copies it.
        if resetsToOriginal && draft == .standard {
            storedLayout = Data()
            customLayoutEnabled = false
            usesMorphToolbar = true
            dismiss()
            return
        }
        guard let data = try? JSONEncoder().encode(draft),
              CanvasControlLayout.decode(data) != nil else { return }
        storedLayout = data
        usesMorphToolbar = false
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
    /// This slot holds the last More, so every choice here must keep it.
    let keepsMore: Bool

    var body: some View {
        List {
            NavigationLink {
                CanvasMorphSelectionView(assignment: $assignment, keepsMore: keepsMore)
            } label: {
                HStack {
                    Label("Morph", systemImage: "square.grid.2x2")
                    Spacer()
                    if assignment.isMorph {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            ForEach(CanvasQuickAction.allCases) { action in
                Button {
                    // Stays open to show the choice; the sheet's close button dismisses it.
                    assignment = .single(action)
                } label: {
                    HStack {
                        CanvasQuickActionLabel(action: action)
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
    let keepsMore: Bool
    @State private var selection: [CanvasQuickAction] = []
    @State private var icon = CanvasMorphIcon.standard
    @State private var loaded = false

    var body: some View {
        List {
            Section(L10n.text("Icon")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 6) {
                    ForEach(CanvasMorphIcon.symbols, id: \.self) { symbol in
                        Button {
                            icon = symbol
                            commit()
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
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(CanvasQuickAction.allCases.filter { $0 != .nothing }) { action in
                    Button {
                        if selection.contains(action) { selection.removeAll { $0 == action } }
                        else if selection.count < 4 { selection.append(action) }
                        commit()
                    } label: {
                        HStack {
                            CanvasQuickActionLabel(action: action)
                            Spacer()
                            // The number is the action's row in the opened morph, from the top.
                            if let order = selection.firstIndex(of: action) {
                                Image(systemName: "\(order + 1).circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled((selection.count == 4 && !selection.contains(action))
                              || (keepsMore && action == .more))
                    .accessibilityAddTraits(selection.contains(action) ? .isSelected : [])
                }
            } header: {
                Text("\(selection.count)/4")
            } footer: {
                Text(L10n.text("Choose up to four actions. Their order follows your selection."))
            }
        }
        .navigationTitle("Morph")
        .onAppear {
            guard !loaded else { return }
            selection = assignment.actions
            if keepsMore && !selection.contains(.more) { selection.insert(.more, at: 0) }
            icon = CanvasMorphIcon.resolve(assignment.icon)
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

struct CanvasQuickActionLabel: View {
    let action: CanvasQuickAction

    var body: some View {
        Label {
            Text(L10n.text(action.title))
        } icon: {
            if action == .clear { BroomIcon() }
            else { Image(systemName: action.symbol) }
        }
    }
}
