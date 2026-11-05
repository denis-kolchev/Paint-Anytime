import SwiftUI

struct AutosaveSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(AutosaveSettings.enabledKey) private var isEnabled = false
    @AppStorage(AutosaveSettings.intervalKey) private var minutes = AutosaveSettings.defaultMinutes
    @AppStorage(AutosaveSettings.showsTimerKey) private var showsTimer = AutosaveSettings.defaultShowsTimer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            Toggle(L10n.text("Autosave"), isOn: $isEnabled.animation(toggleAnimation))
            // Like the iPhone settings, the options appear only while autosave is on.
            // Every row below the switch grows in and fades together, in both directions.
            if isEnabled {
                Group {
                    Toggle(L10n.text("Show timer"), isOn: $showsTimer)
                    intervalSection
                }
                .transition(optionsTransition)
            }
        }
        .navigationTitle(L10n.text("Autosave"))
        .toolbarTitleDisplayMode(.inline)
    }

    private var toggleAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.8)
    }

    private var optionsTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .top).combined(with: .opacity)
    }

    private var intervalSection: some View {
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
}
