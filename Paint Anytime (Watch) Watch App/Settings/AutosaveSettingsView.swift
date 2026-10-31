import SwiftUI

struct AutosaveSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(AutosaveSettings.enabledKey) private var isEnabled = false
    @AppStorage(AutosaveSettings.intervalKey) private var minutes = AutosaveSettings.defaultMinutes

    var body: some View {
        List {
            Toggle(L10n.text("Autosave"), isOn: $isEnabled)
            Section {
                ForEach(AutosaveSettings.intervals, id: \.self) { interval in
                    Button {
                        minutes = interval
                    } label: {
                        HStack {
                            Text(L10n.format("%d min", interval))
                            Spacer()
                            if AutosaveSettings.minutes(minutes) == interval {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .accessibilityAddTraits(AutosaveSettings.minutes(minutes) == interval ? .isSelected : [])
                }
            } header: {
                Text(L10n.text("Save every"))
            } footer: {
                Text(L10n.text("Saves artwork to the gallery at the selected interval while the app is active."))
            }
        }
        .navigationTitle(L10n.text("Autosave"))
        .toolbarTitleDisplayMode(.inline)
    }
}
