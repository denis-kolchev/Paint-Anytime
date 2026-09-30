import SwiftUI

struct WatchWelcomeView: View {
    @StateObject private var onboarding = OnboardingController()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var welcomePage: WelcomePage = .language

    private enum WelcomePage { case language, chooseLanguage, offer, later }

    var body: some View {
        // One navigation host owns the clock and toolbars throughout onboarding,
        // tutorial confirmations and the return to the preserved editor.
        NavigationStack {
            ZStack {
                // Keep the real editor alive, including its document, undo history and camera.
                ContentView(isActive: onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil && !onboarding.preparesTutorial,
                            onStartTutorial: { onboarding.requestTutorial() })
                    .opacity(onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil ? 1 : 0)
                    .allowsHitTesting(onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil && !onboarding.preparesTutorial)
                    .accessibilityHidden(!onboarding.hasCompletedWelcome || onboarding.tutorialFolder != nil)

                if let tutorialFolder = onboarding.tutorialFolder {
                    TutorialPlayerView(folder: tutorialFolder) {
                        onboarding.finishTutorial()
                    }
                    .id(tutorialFolder)
                } else if !onboarding.hasCompletedWelcome {
                    welcome
                        .background(Color.black.ignoresSafeArea())
                }

                if onboarding.preparesTutorial {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.ignoresSafeArea())
                }
            }
            // Keep both toolbar hosts in the same scheme when conditional items
            // are removed/reinserted while switching between tools and canvas.
            // A colorScheme environment override on a button only affects its
            // content; declare the scheme for the system bars here as well.
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbarBackground(onboarding.tutorialFolder != nil ? .visible : .automatic,
                               for: .navigationBar)
        }
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

    @ViewBuilder private var welcome: some View {
        switch welcomePage {
        case .language:
            let name = AppLanguage.supported.first { $0.id == AppLanguage.currentCode }?.nativeName ?? "English"
            WelcomeQuestion(text: L10n.format("Is %@ your language?", name)) {
                welcomePage = .offer
            } onNo: {
                welcomePage = .chooseLanguage
            }
        case .chooseLanguage:
            AppLanguageSelectionView(onSelection: { welcomePage = .offer })
        case .offer:
            WelcomeQuestion(text: L10n.text("Would you like a guided tour?")) {
                onboarding.requestTutorial()
            } onNo: {
                welcomePage = .later
            }
        case .later:
            VStack(spacing: 8) {
                ScrollView {
                    Text(L10n.text("You can start the tutorial anytime: tap the three dots, then Tutorial."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.text("OK")) { onboarding.completeWelcome() }
                    .watchActionButtonStyle()
            }
            .padding()
        }
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
