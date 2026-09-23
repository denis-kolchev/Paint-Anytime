import SwiftUI

struct WatchWelcomeView: View {
    @AppStorage("onboarding.completed.v1") private var hasCompletedWelcome = false
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode
    @State private var welcomePage: WelcomePage = .language
    @State private var tutorialFolder: URL?
    @State private var preparesTutorial = false
    @State private var tutorialError = false

    private enum WelcomePage { case language, chooseLanguage, offer, later }

    var body: some View {
        ZStack {
            // Keep the real editor alive, including its document, undo history and camera.
            ContentView(isActive: hasCompletedWelcome && tutorialFolder == nil && !preparesTutorial,
                        onStartTutorial: { preparesTutorial = true })
                .opacity(hasCompletedWelcome && tutorialFolder == nil ? 1 : 0)
                .allowsHitTesting(hasCompletedWelcome && tutorialFolder == nil && !preparesTutorial)
                .accessibilityHidden(!hasCompletedWelcome || tutorialFolder != nil)

            if let tutorialFolder {
                TutorialPlayerView(folder: tutorialFolder) {
                    self.tutorialFolder = nil
                    hasCompletedWelcome = true
                    try? FileManager.default.removeItem(at: tutorialFolder)
                }
                .id(tutorialFolder)
            } else if !hasCompletedWelcome {
                welcome
                    .background(Color.black.ignoresSafeArea())
            }

            if preparesTutorial {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: preparesTutorial) {
            guard preparesTutorial else { return }
            await Task.yield()
            do { tutorialFolder = try TutorialGallery.prepare() }
            catch { tutorialError = true }
            preparesTutorial = false
        }
        .alert(L10n.text("Tutorial"), isPresented: $tutorialError) {
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
            NavigationStack {
                AppLanguageSelectionView(onSelection: { welcomePage = .offer })
            }
        case .offer:
            WelcomeQuestion(text: L10n.text("Would you like a guided tour?")) {
                preparesTutorial = true
            } onNo: {
                welcomePage = .later
            }
        case .later:
            VStack(spacing: 8) {
                ScrollView {
                    Text(L10n.text("You can start the tutorial anytime: tap the three dots, then Tutorial."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.text("OK")) { hasCompletedWelcome = true }
                    .buttonStyle(.glass)
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
            .buttonStyle(.glass)
        }
        .padding()
    }
}

struct TutorialLessonView: View {
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.format("Lesson %d of 20", tutorial.step))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(TutorialLesson.description(for: tutorial.step))
                    Text(L10n.text("When you are ready, tap Next."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            Button(L10n.text("Next")) {
                if tutorial.step == 20 {
                    tutorial.stop()
                    onFinish()
                } else { tutorial.beginExercise() }
            }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .vertical)
    }
}
