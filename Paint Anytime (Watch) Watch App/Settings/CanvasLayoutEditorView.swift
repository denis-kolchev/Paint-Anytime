import SwiftUI

struct CanvasLayoutEditorView: View {
    @AppStorage(CanvasControlLayout.storageKey) private var storedLayout = Data()
    @AppStorage(CanvasControlLayout.enabledKey) private var customLayoutEnabled = false
    @AppStorage("experimental.morphToolbar") private var usesMorphToolbar = true
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CanvasControlLayout.standard
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CanvasLayoutMap(slots: $draft.slots)
                    .frame(height: 148)
                Text(L10n.text("Tap a circle to choose its action. More stays at the top left."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(L10n.text("Save and apply")) {
                    guard let data = try? JSONEncoder().encode(draft),
                          CanvasControlLayout.decode(data) != nil else { return }
                    storedLayout = data
                    usesMorphToolbar = false
                    customLayoutEnabled = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.text("Use standard layout")) {
                    customLayoutEnabled = false
                    dismiss()
                }
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(L10n.text("Canvas editor"))
        .onAppear {
            guard !loaded else { return }
            draft = CanvasControlLayout.decode(storedLayout) ?? .standard
            loaded = true
        }
    }
}

private struct CanvasLayoutMap: View {
    @Binding var slots: [CanvasControlAssignment]
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        GeometryReader { geometry in
            let map = MorphPanelGeometry(size: geometry.size, layoutDirection: layoutDirection)
            let diameter = min(MorphPanelGeometry.buttonDiameter, (geometry.size.width - 16) / 4)
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.secondary.opacity(0.4))
                Circle().fill(.gray.opacity(0.55))
                    .frame(width: diameter, height: diameter)
                    .position(x: map.leadingX, y: map.top + 18)
                    .accessibilityLabel(L10n.text("More — fixed position"))
                ForEach(0..<5) { index in
                    NavigationLink {
                        CanvasSlotEditorView(assignment: $slots[index])
                    } label: {
                        Circle().fill(.gray.opacity(0.55))
                            .frame(width: diameter, height: diameter)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(index == 0 ? "Top right control" : "Bottom control") + " \(index == 0 ? 1 : index)")
                    .accessibilityValue(slots[index].isMorph ? "Morph" : L10n.text(slots[index].actions[0].title))
                    .position(position(index, map: map))
                }
            }
        }
    }

    private func position(_ index: Int, map: MorphPanelGeometry) -> CGPoint {
        if index == 0 { return CGPoint(x: map.trailingX, y: map.top + 18) }
        // Four equal-width toolbar slots, without shrinking the gaps into
        // overlapping circles on the smaller watches.
        let column = layoutDirection == .rightToLeft ? 4 - index : index - 1
        return CGPoint(x: (CGFloat(column) + 0.5) * map.size.width / 4,
                       y: map.bottom - 18)
    }
}

private struct CanvasSlotEditorView: View {
    @Binding var assignment: CanvasControlAssignment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            NavigationLink {
                CanvasMorphSelectionView(assignment: $assignment)
            } label: {
                Label("Morph", systemImage: "ellipsis.circle")
            }
            ForEach(CanvasQuickAction.allCases) { action in
                Button {
                    assignment = .single(action)
                    dismiss()
                } label: {
                    HStack {
                        CanvasQuickActionLabel(action: action)
                        Spacer()
                        if !assignment.isMorph && assignment.actions == [action] {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("Action"))
    }
}

private struct CanvasMorphSelectionView: View {
    @Binding var assignment: CanvasControlAssignment
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [CanvasQuickAction] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach(CanvasQuickAction.allCases) { action in
                    Button {
                        if selection.contains(action) { selection.removeAll { $0 == action } }
                        else if selection.count < 4 { selection.append(action) }
                    } label: {
                        HStack {
                            CanvasQuickActionLabel(action: action)
                            Spacer()
                            Image(systemName: selection.contains(action) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(action) ? Color.green : Color.secondary)
                        }
                    }
                    .disabled(selection.count == 4 && !selection.contains(action))
                    .accessibilityAddTraits(selection.contains(action) ? .isSelected : [])
                }
            } header: {
                Text("\(selection.count)/4")
            } footer: {
                Text(L10n.text("Choose up to four actions. Their order follows your selection."))
            }
            Button(L10n.text("Done")) {
                assignment = .group(selection)
                dismiss()
            }
            .disabled(selection.isEmpty)
        }
        .navigationTitle("Morph")
        .onAppear {
            guard !loaded else { return }
            selection = assignment.actions
            loaded = true
        }
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
