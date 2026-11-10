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

    private enum WelcomePage { case language, chooseLanguage, offer, later }

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
                    TutorialPlayerView(folder: tutorialFolder, chapters: onboarding.tutorialChapters,
                                       onCompleteChapter: onboarding.completeChapter) {
                        onboarding.finishTutorial()
                    }
                    .id(tutorialFolder)
                    .transition(.opacity)
                } else if !onboarding.hasCompletedWelcome {
                    ZStack {
                        // The backdrop stays put while the pages crossfade above it.
                        Color.black.ignoresSafeArea()
                        welcome
                            .id(welcomePage)
                            .transition(pageTransition(for: welcomePage))
                    }
                    .opacity(showsWelcomeContent ? 1 : 0)
                    // On the container, not the pages, so the slots stay put while pages crossfade.
                    .toolbar { centeredClockSlots }
                    // The question stays visible while the tutorial prepares, as the menu does.
                    .allowsHitTesting(!onboarding.preparesTutorial)
                    .transition(.opacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.6)) { showsWelcomeContent = true }
                    }
                    .onDisappear { showsWelcomeContent = false }
                }
            }
            // The same crossfade as a tutorial started from the editor menu.
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
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task(id: onboarding.preparesTutorial) {
            await onboarding.prepareTutorial()
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
            irisIsRunning = false
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
        // Scaling a List shrinks its scroll frame and shows black bands above and below it.
        let scales = !reduceMotion && page != .chooseLanguage
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
    /// SwiftUI springs solve m·x″ = −k·x − b·x′; zero bounce is critical damping,
    /// so the circle settles without overshooting past fully closed or fully open.
    private func finishWelcome() {
        guard !irisIsRunning else { return }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.3)) { onboarding.completeWelcome() }
            return
        }
        irisFraction = 1
        irisIsRunning = true
        // 1. Close: wait for the spring to settle, not its logical end, so the
        //    circle shrinks all the way instead of stopping at a visible dot.
        withAnimation(.spring(duration: 0.6, bounce: 0), completionCriteria: .removed) {
            irisFraction = 0
        } completion: {
            Task { @MainActor in
                // 2. Pause on black: the editor activates and draws its first frames unseen.
                onboarding.completeWelcome()
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(Self.irisPauseMilliseconds))
                // 3. Open: a separate animation that starts from rest.
                withAnimation(.spring(duration: 0.7, bounce: 0), completionCriteria: .removed) {
                    irisFraction = 1
                } completion: {
                    irisIsRunning = false
                }
            }
        }
    }

    /// Time the screen stays black between closing and opening.
    private static let irisPauseMilliseconds = 400

    @ViewBuilder private var welcome: some View {
        switch welcomePage {
        case .language:
            let name = AppLanguage.supported.first { $0.id == AppLanguage.currentCode }?.nativeName ?? "English"
            WelcomeQuestion(text: L10n.format("Is %@ your language?", name)) {
                show(.offer)
            } onNo: {
                show(.chooseLanguage)
            }
        case .chooseLanguage:
            // No title: a title appearing mid-crossfade would flash and shift both pages.
            // Every welcome page shares the same bar of clock slots, so the layout holds.
            AppLanguageSelectionView(showsTitle: false, onSelection: { show(.language) })
        case .offer:
            WelcomeQuestion(text: L10n.text("Would you like a guided tour?")) {
                onboarding.requestTutorial()
            } onNo: {
                show(.later)
            }
        case .later:
            VStack(spacing: 8) {
                ScrollView {
                    Text(L10n.text("You can start the tutorial anytime: tap the three dots, then Tutorial."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.text("OK"), action: finishWelcome)
                    .watchActionButtonStyle()
            }
            // No bottom padding: the button sits at the bottom of the safe area.
            .padding([.horizontal, .top])
        }
    }
}

/// Returns the app to its first-launch questions while the editor stays alive underneath.
struct RestartWelcomeAction {
    let perform: @MainActor () -> Void
    @MainActor func callAsFunction() { perform() }
}

private struct RestartWelcomeKey: EnvironmentKey {
    static let defaultValue: RestartWelcomeAction? = nil
}

extension EnvironmentValues {
    var restartWelcome: RestartWelcomeAction? {
        get { self[RestartWelcomeKey.self] }
        set { self[RestartWelcomeKey.self] = newValue }
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
            HStack {
                Button(L10n.text("Yes"), action: onYes)
                Button(L10n.text("No"), action: onNo)
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
    var body: some View {
        WatchAppSettingsView(controller: controller, viewportSize: viewportSize, onOpenDrawings: onOpenDrawings,
                             onStartTutorial: { onboarding.requestTutorial(chapters: $0) },
                             completedTutorialChapters: onboarding.completedChapters,
                             opensTutorialChapters: opensTutorialChapters, onClose: onFinish,
                             onCanvasAction: onCanvasAction)
        // Block repeated taps without dimming every menu row before dismissal.
        .allowsHitTesting(!onboarding.preparesTutorial)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
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
