import Combine
import Foundation

@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var hasCompletedWelcome: Bool
    @Published private(set) var tutorialFolder: URL?
    @Published private(set) var preparesTutorial = false
    /// Chapters of the requested run: the full tour or one chapter from the menu.
    @Published private(set) var tutorialChapters = TutorialChapter.allCases
    @Published var tutorialError = false
    private let defaults: UserDefaults
    private let workspace: TutorialWorkspace
    private static let completionKey = "onboarding.completed.v1"

    init(defaults: UserDefaults = .standard, workspace: TutorialWorkspace? = nil) {
        self.defaults = defaults
        self.workspace = workspace ?? TutorialWorkspace()
        hasCompletedWelcome = defaults.bool(forKey: Self.completionKey)
    }

    /// Read on demand: the welcome flow and the editor menu own separate controllers.
    var completedChapters: Set<TutorialChapter> { TutorialChapter.completed(in: defaults) }

    func requestTutorial(chapters: [TutorialChapter] = TutorialChapter.allCases) {
        guard tutorialFolder == nil, !preparesTutorial else { return }
        tutorialChapters = chapters.isEmpty ? TutorialChapter.allCases : chapters
        tutorialError = false
        preparesTutorial = true
    }

    /// Called by the view's task so preparation shares the presentation's lifetime.
    func prepareTutorial() async {
        guard preparesTutorial else { return }
        defer { preparesTutorial = false }
        await Task.yield()
        guard !Task.isCancelled else { return }
        // Copying the preset photos is file I/O; off the main actor it cannot hitch
        // the menu's tap or the black pause before the iris opens.
        let workspace = workspace
        do {
            let folder = try await Task.detached(priority: .userInitiated) { try workspace.prepare() }.value
            guard !Task.isCancelled else {
                try? workspace.remove(folder)
                return
            }
            tutorialFolder = folder
        } catch { tutorialError = true }
    }

    func completeWelcome() {
        hasCompletedWelcome = true
        defaults.set(true, forKey: Self.completionKey)
    }

    /// Shows the first-launch questions again. Drawings, the open document and
    /// settings are untouched; only the welcome flag is cleared.
    func restartWelcome() {
        guard tutorialFolder == nil, !preparesTutorial else { return }
        hasCompletedWelcome = false
        defaults.set(false, forKey: Self.completionKey)
    }

    func completeChapter(_ chapter: TutorialChapter) {
        objectWillChange.send()
        chapter.markCompleted(in: defaults)
    }

    func finishTutorial() {
        let folder = tutorialFolder
        tutorialFolder = nil
        completeWelcome()
        // Cleanup remains best-effort; the next preparation removes stale sessions too.
        if let folder { try? workspace.remove(folder) }
    }
}
