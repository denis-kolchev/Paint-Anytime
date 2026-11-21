import SwiftUI

struct AutosaveSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @AppStorage(AutosaveSettings.enabledKey) private var isEnabled = false
    @AppStorage(AutosaveSettings.intervalKey) private var minutes = AutosaveSettings.defaultMinutes
    @AppStorage(AutosaveSettings.showsTimerKey) private var showsTimer = AutosaveSettings.defaultShowsTimer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True from the Autosave flip until Show timer has grown in: its switch is built
    /// without animation, so the knob does not slide from off to on as the row appears.
    @State private var insertsOptions = false
    /// The tour shows only the switch, bound to its own simulated autosave.
    @ObservedObject var tutorial = TutorialSession.inactive
    var tutorialIsEnabled = false
    var onTutorialEnable: (() -> Void)? = nil
    /// The tour's own Show timer, on by default; never asked for, but honored on its canvas.
    var tutorialShowsTimer: Binding<Bool> = .constant(true)

    var body: some View {
        if tutorial.isActive {
            tutorialList
        } else {
            settingsList
        }
    }

    private var settingsList: some View {
        List {
            Toggle(L10n.text("Autosave"), isOn: Binding(get: { isEnabled }, set: { on in
                insertsOptions = true
                isEnabled = on
            }))
            // Like the iPhone settings, the options appear only while autosave is on.
            // Every row below the switch grows in and fades together, in both directions.
            // The transition sits on each row: List ignores transitions on Group/Section.
            if isEnabled {
                Toggle(L10n.text("Show timer"), isOn: $showsTimer)
                    .withoutInsertionAnimation(insertsOptions)
                    .transition(optionsTransition)
                intervalSection
            }
        }
        // Value-driven animation: @AppStorage writes go through UserDefaults and
        // drop the transaction of a `Binding.animation(_:)`, so the rows would snap.
        .animation(toggleAnimation, value: isEnabled)
        .task(id: isEnabled) { await settleOptions() }
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

    /// The same switch and title, and Show timer growing in once it is on, as in the settings;
    /// without the interval or the information link: the link would push over the whole
    /// lesson, and the tour saves at its own moments.
    private var tutorialList: some View {
        List {
            Toggle(isOn: Binding(get: { tutorialIsEnabled }, set: { on in
                guard on else { return }
                insertsOptions = true
                onTutorialEnable?()
            })) {
                Text(L10n.text("Autosave"))
                    .tutorialHint(tutorial, steps: [.enableAutosave])
            }
            // Turned on once; the lesson never offers turning it off. Not disabled: a dimmed
            // switch would look unlike the setting.
            .allowsHitTesting(!tutorialIsEnabled && tutorial.permits([.enableAutosave]))
            // No lesson step asks for it; the user may still hide the canvas countdown.
            if tutorialIsEnabled {
                Toggle(L10n.text("Show timer"), isOn: tutorialShowsTimer)
                    .withoutInsertionAnimation(insertsOptions)
                    .allowsHitTesting(tutorial.acceptsActions)
                    .transition(optionsTransition)
            }
        }
        .animation(toggleAnimation, value: tutorialIsEnabled)
        .task(id: tutorialIsEnabled) { await settleOptions() }
        .navigationTitle(L10n.text("Autosave"))
        .toolbarTitleDisplayMode(.inline)
    }

    /// Ends the window once the rows have grown in, so tapping Show timer animates again.
    private func settleOptions() async {
        guard insertsOptions else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        insertsOptions = false
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

private extension View {
    /// The row still grows in through the transition applied outside this modifier, but the
    /// switch inside is built without the insertion's animation: otherwise watchOS slides its
    /// knob from off to on as it appears, as if the option were being turned on right then.
    /// Only while `isInserting`: `transaction(value:)` would not apply here, since a row just
    /// inserted has no previous value to compare. Tapping the switch later still animates.
    func withoutInsertionAnimation(_ isInserting: Bool) -> some View {
        transaction { transaction in
            if isInserting {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}
