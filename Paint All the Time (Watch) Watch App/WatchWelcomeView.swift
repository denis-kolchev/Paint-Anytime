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
        // One navigation host owns the clock and toolbars throughout onboarding,
        // tutorial confirmations and the return to the preserved editor.
        NavigationStack {
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
            // Keep both toolbar hosts in the same scheme when conditional items
            // are removed/reinserted while switching between tools and canvas.
            // A colorScheme environment override on a button only affects its
            // content; declare the scheme for the system bars here as well.
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task(id: preparesTutorial) {
            guard preparesTutorial else { return }
            await Task.yield()
            do { tutorialFolder = try TutorialGallery.prepare() }
            catch {
                tutorialError = true
            }
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
            AppLanguageSelectionView(onSelection: { welcomePage = .offer })
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

struct TutorialLessonView: View {
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void
    @State private var confirmsFinish = false
    @State private var didConfirmFinish = false

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
            .hideTopScrollEdgeEffectIfAvailable()
            HStack(spacing: 8) {
                Button {
                    tutorial.pauseReminders()
                    confirmsFinish = true
                } label: {
                    Text(L10n.text("Finish"))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .watchActionButtonStyle()
                .tint(.red)
                .foregroundStyle(.red)

                Button {
                    if tutorial.step == 2 { TutorialDebug.startNextTrace() }
                    TutorialDebug.trace("next.action.enter", tutorial.debugState)
                    defer { TutorialDebug.trace("next.action.exit", tutorial.debugState) }
                    if tutorial.step == 20 {
                        tutorial.stop()
                        onFinish()
                    } else { tutorial.beginExercise() }
                } label: {
                    Text(L10n.text("Next"))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .watchActionButtonStyle()
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .vertical)
        .onDisappear { TutorialDebug.trace("lessonCard.disappear", tutorial.debugState) }
        .fullScreenCover(isPresented: $confirmsFinish, onDismiss: {
            if didConfirmFinish {
                didConfirmFinish = false
                tutorial.stop()
                onFinish()
            } else {
                tutorial.resumeReminders()
            }
        }) {
            DestructiveConfirmationView(
                title: L10n.text("Are you sure you want to finish the tutorial?"),
                confirmTitle: L10n.text("Yes")
            ) {
                confirmsFinish = false
            } onConfirm: {
                didConfirmFinish = true
                confirmsFinish = false
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func hideTopScrollEdgeEffectIfAvailable() -> some View {
        if #available(watchOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
