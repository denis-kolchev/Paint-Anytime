import SwiftUI

struct PerspectiveGuidesSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @ObservedObject var guides = PerspectiveGuides.shared

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Show guides"), isOn: $guides.isEnabled)
            } footer: {
                Text(L10n.text("A stroke that starts on a guide follows it or runs toward a vanishing point. Drag the round handles on the horizon to move or rotate the guides."))
            }
            Section {
                ForEach(PerspectivePreset.allCases) { preset in
                    Button {
                        guides.preset = preset
                    } label: {
                        HStack {
                            Text(preset.title)
                            Spacer()
                            if guides.preset == preset {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityAddTraits(guides.preset == preset ? .isSelected : [])
                }
            }
            Section {
                CompactDegreeStepper(title: L10n.text("View angle"), value: $guides.viewAngle,
                                     range: PerspectiveGuides.viewAngleRange)
            } footer: {
                Text(L10n.text("A wider angle brings the vanishing points closer and makes the lines steeper. With one point, it sets the spacing between lines."))
            }
            Section {
                CompactDegreeStepper(title: L10n.text("Tilt"), value: Binding(
                    get: { (guides.rotation * 180 / .pi).rounded() },
                    set: {
                        guides.rotation = PerspectiveGuides.normalizedRotation($0 * .pi / 180)
                        guides.savePlacement()
                    }
                ), range: -180...180)
                Button(L10n.text("Reset position")) { guides.resetPlacement() }
            }
        }
        .navigationTitle(L10n.text("Perspective"))
    }
}

/// The system Stepper centres its label between large buttons, so longer
/// translations wrap letter by letter. Keep the label small above the value.
private struct CompactDegreeStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 5

    var body: some View {
        HStack(spacing: 4) {
            button("minus", by: -step)
            VStack(spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("\(Int(value))°")
                    .font(.headline)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            button("plus", by: step)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(value))°")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(by: step)
            case .decrement: change(by: -step)
            @unknown default: break
            }
        }
    }

    private func button(_ symbol: String, by delta: Double) -> some View {
        Button { change(by: delta) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(value + delta))
    }

    private func change(by delta: Double) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }
}
