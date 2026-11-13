import SwiftUI

struct WatchWelcomeView: View {
    @StateObject private var onboarding = OnboardingController()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var launchRequest: WatchLaunchRequest?
    @State private var welcomePage: WelcomePage = .language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fades the first question in instead of showing it with the first frame.
    @State private var showsWelcomeContent = false
    /// Hole of the black iris as a fraction of the half-diagonal; 1 leaves the screen open.
    @State private var irisFraction: CGFloat = 1
    @State private var irisIsRunning = false
    /// The iris has closed for the guided tour and opens once the tutorial is prepared.
    @State private var irisAwaitsTutorial = false
    /// Hides the clock while the iris closes, before the question and its clock-centering
    /// slots leave. Removing the slots first let the visible clock slide to the trailing
    /// corner on its way out, since the canvas and the tutorial both hide it.
    @State private var hidesClockForIris = false

    /// The list opens first, the detected language on top. A different choice is not
    /// applied yet: the question asks in that language, and only ✓ switches the app.
    private enum WelcomePage { case language, confirmLanguage, offer, later }
    /// The language tapped in the list, awaiting confirmation. Kept after ✓ or ✕ so the
    /// confirmation can still fade out with it.
    @State private var chosenLanguageCode: String?

    var body: some View {
        // One navigation host owns the clock and toolbars throughout onboarding,
        // tutorial confirmations and the return to the preserved editor.
        NavigationStack {
            ZStack {
                // Keep the real editor alive, including its document, undo history and camera.
                ContentView(launchRequest: $launchRequest, isActive: onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil && !onboarding.preparesTutorial)
                    .opacity(onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil ? 1 : 0)
                    .allowsHitTesting(onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil && !onboarding.preparesTutorial)
                    .accessibilityHidden(!onboarding.hasCompletedWelcome || onboarding.tutorialFolder != nil)

                if let tutorialFolder = onboarding.tutorialFolder {
                    // The first-launch run starts with the first chapter and asks before the rest.
                    TutorialPlayerView(folder: tutorialFolder, chapters: onboarding.tutorialChapters,
                                       offersRemainingChapters: true,
                                       onCompleteChapter: onboarding.completeChapter,
                                       onFinish: finishTutorialThroughIris)
                    .id(tutorialFolder)
                    .transition(.opacity)
                } else if !onboarding.hasCompletedWelcome {
                    ZStack {
                        // The backdrop stays put while the pages crossfade above it.
                        Color.black.ignoresSafeArea()
                        welcome
                            .id(listedPage)
                            .transition(pageTransition(for: listedPage))
                        if welcomePage == .confirmLanguage, let chosenLanguage {
                            WelcomeLanguageConfirmation(language: chosenLanguage) {
                                show(.offer)
                            } onReject: {
                                show(.language)
                            }
                            .transition(pageTransition(for: .confirmLanguage))
                        }
                    }
                    .opacity(showsWelcomeContent ? 1 : 0)
                    // On the container, not the pages, so the slots stay put while pages crossfade.
                    .toolbar { centeredClockSlots }
                    .requestsHiddenClock(hidesClockForIris)
                    // The question stays visible while the tutorial prepares, as the menu does.
                    .allowsHitTesting(!onboarding.preparesTutorial)
                    .transition(.opacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.6)) { showsWelcomeContent = true }
                    }
                    .onDisappear { showsWelcomeContent = false }
                }
            }
            // The same crossfade as a tutorial started from the editor menu. Yes on the welcome
            // question sets the folder behind the closed iris, so this fade runs unseen there.
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3), value: onboarding.tutorialFolder)
            // Keep both toolbar hosts in the same scheme when conditional items
            // are removed/reinserted while switching between tools and canvas.
            // A colorScheme environment override on a button only affects its
            // content; declare the scheme for the system bars here as well.
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            // The editor, tutorial and gallery only request a hidden clock;
            // one host applies it so their requests cannot override each other.
            .modifier(ClockVisibilityHost())
            // Each tutorial page owns its top background; forcing a native
            // background here overrides the settings preview’s bounded material.
        }
        // Above the navigation host so the canvas toolbars appear inside the opening circle too.
        .overlay {
            IrisShape(fraction: irisFraction)
                .fill(.black, style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                // Hidden layers are skipped, so the idle iris costs the canvas nothing.
                .opacity(irisIsRunning ? 1 : 0)
                // Block taps only while closing; the canvas responds as soon as it starts to open.
                .allowsHitTesting(irisIsRunning && irisFraction == 0)
                .accessibilityHidden(true)
        }
        .onOpenURL { url in
            guard let request = WatchLaunchRequest(url: url) else { return }
            // A plain app launch preserves the current screen and document.
            launchRequest = request.destination == .app ? nil : request
        }
        // The editor menu owns its own controller, so it restarts the flow through this action.
        .environment(\.restartWelcome, restartWelcome)
        // The editor menu's tutorial opens and closes through the same circle.
        .environment(\.irisTransition, IrisTransitionAction { runThroughIris($0) })
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task(id: onboarding.preparesTutorial) {
            await onboarding.prepareTutorial()
        }
        .onChange(of: onboarding.preparesTutorial) { _, prepares in
            // Ready or failed: open the iris onto the tutorial, or back onto the question
            // so the error alert is readable.
            guard !prepares, irisAwaitsTutorial else { return }
            irisAwaitsTutorial = false
            Task { @MainActor in await openIrisAfterPause() }
        }
        .alert(L10n.text("Tutorial"), isPresented: $onboarding.tutorialError) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: {
            Text(L10n.text("The tutorial could not start. Please try again."))
        }
    }

    private var restartWelcome: RestartWelcomeAction {
        RestartWelcomeAction {
            welcomePage = .language
            chosenLanguageCode = nil
            irisIsRunning = false
            irisAwaitsTutorial = false
            hidesClockForIris = false
            irisFraction = 1
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                onboarding.restartWelcome()
            }
        }
    }

    /// watchOS centers the system clock when both top toolbar corners hold an item,
    /// as on the tutorial's tools page. These slots are invisible and inert.
    @ToolbarContentBuilder private var centeredClockSlots: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { ClockCenteringSlot() }
        ToolbarItem(placement: .topBarTrailing) { ClockCenteringSlot() }
    }

    /// A crossfade: the previous page fades out over most of the time the next one
    /// fades in, so neither vanishes at once nor leaves an empty black gap.
    private func pageTransition(for page: WelcomePage) -> AnyTransition {
        // A scaling page is laid out without its ignored safe area until the transition
        // ends: the List shows black bands and the OK button jumps down on the last frame.
        let scales = !reduceMotion && page != .language && page != .later
        let insertion: AnyTransition = scales ? .opacity.combined(with: .scale(scale: 0.94)) : .opacity
        return .asymmetric(
            insertion: insertion.animation(.easeInOut(duration: reduceMotion ? 0.25 : 0.35).delay(0.05)),
            removal: .opacity.animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.3))
        )
    }

    private func show(_ page: WelcomePage) {
        withAnimation { welcomePage = page }
    }

    /// Closes the screen with a shrinking black circle, then opens it over the canvas.
    private func finishWelcome() {
        guard !irisIsRunning else { return }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.3)) { onboarding.completeWelcome() }
            return
        }
        closeIris {
            // The editor activates and draws its first frames unseen.
            onboarding.completeWelcome()
            Task { @MainActor in await openIrisAfterPause() }
        }
    }

    /// Yes on the tour question: the same iris as No → OK, opening onto the tutorial.
    /// Every chapter is queued, but the player asks after the first one whether to go on,
    /// so nobody has to choose a course before seeing what the tour is like.
    /// The tutorial from the editor menu uses the same circle through `irisTransition`.
    private func startTutorial() {
        guard !irisIsRunning else { return }
        guard !reduceMotion else {
            onboarding.requestTutorial(chapters: TutorialChapter.allCases)
            return
        }
        closeIris {
            // Prepare behind the black screen; `preparesTutorial` turning false opens the iris.
            irisAwaitsTutorial = true
            onboarding.requestTutorial(chapters: TutorialChapter.allCases)
            if !onboarding.preparesTutorial {
                // The request was refused (a run is already in progress): do not stay black.
                irisAwaitsTutorial = false
                Task { @MainActor in await openIrisAfterPause() }
            }
        }
    }

    /// Later after the first chapter, or finishing the tour: the same iris that opened
    /// the tour closes it, and the editor appears behind the black screen.
    private func finishTutorialThroughIris() {
        runThroughIris { onboarding.finishTutorial() }
    }

    /// Switches app modes behind the iris: closes the circle, runs `swap` unseen,
    /// then opens onto the new screen. Reduce Motion, or an iris already running,
    /// crossfades instead.
    private func runThroughIris(_ swap: @escaping @MainActor () -> Void) {
        guard !irisIsRunning, !reduceMotion else {
            withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) { swap() }
            return
        }
        closeIris {
            swap()
            Task { @MainActor in await openIrisAfterPause() }
        }
    }

    /// SwiftUI springs solve m·x″ = −k·x − b·x′; zero bounce is critical damping,
    /// so the circle settles without overshooting past fully closed or fully open.
    private func closeIris(then whenClosed: @escaping @MainActor () -> Void) {
        // Callers can run inside an animation (the lesson card's ✓); the black layer must
        // appear at once with an open hole, not fade in over the whole screen.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            irisFraction = 1
            irisIsRunning = true
            hidesClockForIris = true
        }
        // Wait for the spring to settle, not its logical end, so the circle shrinks
        // all the way instead of stopping at a visible dot.
        withAnimation(Self.irisCloseAnimation, completionCriteria: .removed) {
            irisFraction = 0
        } completion: {
            Task { @MainActor in whenClosed() }
        }
    }

    /// Pauses on black so the next screen draws unseen, then opens with a separate
    /// animation that starts from rest.
    private func openIrisAfterPause() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(Self.irisPauseMilliseconds))
        guard irisIsRunning else { return }
        // Only a failed tutorial start reopens onto the question; its clock returns centered.
        hidesClockForIris = false
        withAnimation(.spring(duration: 0.7, bounce: 0), completionCriteria: .removed) {
            irisFraction = 1
        } completion: {
            irisIsRunning = false
        }
    }

    /// Time the screen stays black between closing and opening.
    private static let irisPauseMilliseconds = 400
    /// Shared with the editor menu's own circle, which closes in step with this one.
    static let irisCloseAnimation = Animation.spring(duration: 0.6, bounce: 0)

    private static let laterButtonInset: CGFloat = 10

    /// The confirmation covers the language list instead of replacing it, so ✕ returns
    /// to the list exactly where it was scrolled.
    private var listedPage: WelcomePage {
        welcomePage == .confirmLanguage ? .language : welcomePage
    }

    private var chosenLanguage: AppLanguage? {
        AppLanguage.supported.first { $0.id == chosenLanguageCode }
    }

    @ViewBuilder private var welcome: some View {
        switch listedPage {
        case .language, .confirmLanguage:
            // No title: a title appearing mid-crossfade would flash and shift both pages.
            // Every welcome page shares the same bar of clock slots, so the layout holds.
            AppLanguageSelectionView(showsTitle: false, pinsCurrentLanguage: true,
                                     // The detected language: nothing to confirm.
                                     onSelection: { _ in show(.offer) },
                                     onChooseWithoutApplying: { code in
                                         chosenLanguageCode = code
                                         show(.confirmLanguage)
                                     },
                                     // Kept alive under the confirmation, so ✕ returns to the same offset.
                                     isCovered: welcomePage == .confirmLanguage)
        case .offer:
            WelcomeQuestion(text: L10n.text("Would you like a short tour?")) {
                startTutorial()
            } onNo: {
                show(.later)
            }
        case .later:
            VStack(spacing: 6) {
                ScrollView {
                    Text(L10n.text("You can start the tutorial anytime: tap the three dots, then Tutorial."))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A little inside the button's edges, as on the tour's continuation card.
                .padding(.horizontal, Self.laterButtonInset + 6)
                Button(L10n.text("OK"), action: finishWelcome)
                    .watchActionButtonStyle()
                    // Inset from the rounded bottom corners of the display.
                    .padding(.horizontal, Self.laterButtonInset)
                    .padding(.bottom, 4)
            }
            // The bar above already spaces the text from the clock.
            .padding(.top, 2)
            // The button moves into the bottom safe area, leaving the text more room.
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// Returns the app to its first-launch questions while the editor stays alive underneath.
struct RestartWelcomeAction {
    let perform: @MainActor () -> Void
    @MainActor func callAsFunction() { perform() }
}

/// Closes the screen with the black iris, runs the change unseen, then opens onto it.
/// Provided by the welcome host, whose overlay sits above the editor and its tutorial.
struct IrisTransitionAction {
    let perform: @MainActor (@escaping @MainActor () -> Void) -> Void
    @MainActor func callAsFunction(_ swap: @escaping @MainActor () -> Void) { perform(swap) }
}

private struct IrisTransitionKey: EnvironmentKey {
    static let defaultValue: IrisTransitionAction? = nil
}

private struct RestartWelcomeKey: EnvironmentKey {
    static let defaultValue: RestartWelcomeAction? = nil
}

extension EnvironmentValues {
    var restartWelcome: RestartWelcomeAction? {
        get { self[RestartWelcomeKey.self] }
        set { self[RestartWelcomeKey.self] = newValue }
    }
    var irisTransition: IrisTransitionAction? {
        get { self[IrisTransitionKey.self] }
        set { self[IrisTransitionKey.self] = newValue }
    }
}

private struct ClockCenteringSlot: View {
    var body: some View {
        Button {} label: {
            Color.clear.frame(width: 18, height: 18)
        }
        .disabled(true)
        .watchToolbarButtonStyle(hidesNativeChrome: true)
        .accessibilityHidden(true)
    }
}

/// A black screen with a centered circular hole; `fraction` 1 reaches the corners.
private struct IrisShape: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(0, fraction) * hypot(rect.width, rect.height) / 2
        // Overfill the rectangle so no edge shows while the hole reaches the corners.
        var path = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
        path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius,
                                   width: radius * 2, height: radius * 2))
        return path
    }
}

/// Asks in the chosen language, which names itself in its own script, while the app
/// keeps its current language. The buttons are icons, so someone who cannot read this
/// language can still tap ✕ to go back; only ✓ applies it, behind a progress overlay.
private struct WelcomeLanguageConfirmation: View {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    let language: AppLanguage
    let onConfirm: () -> Void
    let onReject: () -> Void
    @State private var isApplying = false
    /// Captured in the outgoing language so the overlay never switches mid-change.
    @State private var changingLanguageMessage = ""
    @State private var changingFromCode = AppLanguage.currentCode

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                // The question already names the language; it is the only text on the page.
                Text(verbatim: L10n.format(in: language.id, "Is %@ your language?", language.nativeName))
                    .font(.headline)
                    .typesettingLanguage(.explicit(Locale.Language(identifier: language.id)))
                    .environment(\.locale, Locale(identifier: language.id))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(action: onReject) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .watchActionButtonStyle()
                .accessibilityLabel(L10n.text("No", in: language.id))
                Button(action: confirm) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .watchProminentActionButtonStyle()
                .tint(.green)
                .accessibilityLabel(L10n.text("Yes", in: language.id))
            }
        }
        .padding()
        .disabled(isApplying)
        .accessibilityHidden(isApplying)
        .overlay {
            if isApplying {
                LanguageChangeOverlay(message: changingLanguageMessage, languageCode: changingFromCode)
            }
        }
        .task(id: isApplying) {
            guard isApplying else { return }
            do {
                try await LanguageChangeOverlay.apply { languageCode = language.id }
                onConfirm()
            } catch {
                // SwiftUI cancels this task if the page disappears.
            }
        }
    }

    private func confirm() {
        guard !isApplying else { return }
        guard language.id != AppLanguage.currentCode else { return onConfirm() }
        changingFromCode = AppLanguage.currentCode
        changingLanguageMessage = L10n.text("Changing language…")
        isApplying = true
    }
}

private struct WelcomeQuestion: View {
    let text: String
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(text)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No on the leading side, Yes on the trailing one, like ✕ / ✓ and Later / Continue.
            HStack {
                Button(L10n.text("No"), action: onNo)
                Button(L10n.text("Yes"), action: onYes)
            }
            .watchActionButtonStyle()
        }
        .padding()
    }
}

/// Present the menu and prepare a repeat tutorial before handing it to the editor.
struct TutorialMenuPresentation: View {
    @ObservedObject var controller: CanvasController
    let viewportSize: CGSize
    @ObservedObject var onboarding: OnboardingController
    let onOpenDrawings: () -> Void
    let onFinish: () -> Void
    var opensTutorialChapters = false
    var onCanvasAction: ((CanvasQuickAction) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The system sheet sits above the app's iris, so it closes its own circle in step
    /// with it; the host then removes the sheet behind black. 1 leaves the menu open.
    @State private var irisFraction: CGFloat = 1
    @State private var closesIris = false

    var body: some View {
        WatchAppSettingsView(controller: controller, viewportSize: viewportSize, onOpenDrawings: onOpenDrawings,
                             onStartTutorial: { onboarding.requestTutorial(chapters: $0) },
                             completedTutorialChapters: onboarding.completedChapters,
                             opensTutorialChapters: opensTutorialChapters, onClose: onFinish,
                             onCanvasAction: onCanvasAction)
        // Above the menu's navigation host, so its title and buttons close with the circle.
        .overlay {
            IrisShape(fraction: irisFraction)
                .fill(.black, style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .opacity(closesIris ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // The clock leaves as the circle starts, as it does on the welcome screen.
        ._statusBarHidden(closesIris)
        // Block repeated taps without dimming every menu row before dismissal.
        .allowsHitTesting(!onboarding.preparesTutorial && onboarding.tutorialFolder == nil)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .onChange(of: onboarding.tutorialFolder) { _, folder in
            guard folder != nil else {
                // The run ended while the circle was closing: never leave the menu black.
                closesIris = false
                irisFraction = 1
                return
            }
            // The host starts the app's iris on the same change; Reduce Motion crossfades instead.
            guard !reduceMotion, !closesIris else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { closesIris = true }
            withAnimation(WatchWelcomeView.irisCloseAnimation) { irisFraction = 0 }
        }
        .task(id: onboarding.preparesTutorial) {
            await onboarding.prepareTutorial()
        }
        .alert(L10n.text("Tutorial"), isPresented: $onboarding.tutorialError) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: {
            Text(L10n.text("The tutorial could not start. Please try again."))
        }
    }
}
