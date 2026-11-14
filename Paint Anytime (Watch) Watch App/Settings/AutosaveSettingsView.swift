import SwiftUI

struct AutosaveSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(AutosaveSettings.enabledKey) private var isEnabled = false
    @AppStorage(AutosaveSettings.intervalKey) private var minutes = AutosaveSettings.defaultMinutes
    @AppStorage(AutosaveSettings.showsTimerKey) private var showsTimer = AutosaveSettings.defaultShowsTimer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tour shows only the switch, bound to its own simulated autosave.
    @ObservedObject var tutorial = TutorialSession.inactive
    var tutorialIsEnabled = false
    var onTutorialEnable: (() -> Void)? = nil

    var body: some View {
        if tutorial.isActive {
            tutorialList
        } else {
            settingsList
        }
    }

    private var settingsList: some View {
        List {
            Toggle(L10n.text("Autosave"), isOn: $isEnabled)
            // Like the iPhone settings, the options appear only while autosave is on.
            // Every row below the switch grows in and fades together, in both directions.
            // The transition sits on each row: List ignores transitions on Group/Section.
            if isEnabled {
                Toggle(L10n.text("Show timer"), isOn: $showsTimer)
                    .transition(optionsTransition)
                intervalSection
            }
        }
        // Value-driven animation: @AppStorage writes go through UserDefaults and
        // drop the transaction of a `Binding.animation(_:)`, so the rows would snap.
        .animation(toggleAnimation, value: isEnabled)
        .navigationTitle(L10n.text("Autosave"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            SettingsInformationButton(
                accessibilityKey: "About autosave",
                titleKey: "Autosave",
                messageKey: "Saves artwork to the gallery at the selected interval while the app is active."
            )
        }
    }

    /// The same switch and title, without the timer, the interval or the information link:
    /// the link would push over the whole lesson, and the tour saves at its own moments.
    private var tutorialList: some View {
        List {
            Toggle(isOn: Binding(get: { tutorialIsEnabled }, set: { on in if on { onTutorialEnable?() } })) {
                Text(L10n.text("Autosave"))
                    .tutorialHint(tutorial, steps: [.enableAutosave])
            }
            // Turned on once; the lesson never offers turning it off. Not disabled: a dimmed
            // switch would look unlike the setting.
            .allowsHitTesting(!tutorialIsEnabled && tutorial.permits([.enableAutosave]))
        }
        .animation(toggleAnimation, value: tutorialIsEnabled)
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
                .transition(optionsTransition)
            }
        } header: {
            Text(L10n.text("Save every"))
        }
    }
}
