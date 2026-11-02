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
                Stepper(value: $guides.viewAngle, in: PerspectiveGuides.viewAngleRange, step: 5) {
                    Text(L10n.format("View angle: %d°", Int(guides.viewAngle)))
                        .monospacedDigit()
                }
            } footer: {
                Text(L10n.text("A wider angle brings the vanishing points closer and makes the lines steeper. With one point, it sets the spacing between lines."))
            }
            Section {
                Stepper(value: Binding(
                    get: { (guides.rotation * 180 / .pi).rounded() },
                    set: {
                        guides.rotation = PerspectiveGuides.normalizedRotation($0 * .pi / 180)
                        guides.savePlacement()
                    }
                ), in: -180...180, step: 5) {
                    Text(L10n.format("Tilt: %d°", Int((guides.rotation * 180 / .pi).rounded())))
                        .monospacedDigit()
                }
                Button(L10n.text("Reset position")) { guides.resetPlacement() }
            }
        }
        .navigationTitle(L10n.text("Perspective"))
    }
}
