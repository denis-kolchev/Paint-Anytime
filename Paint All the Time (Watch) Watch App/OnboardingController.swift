import Combine
import Foundation

@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var hasCompletedWelcome: Bool
    @Published private(set) var tutorialFolder: URL?
    @Published private(set) var preparesTutorial = false
    @Published var tutorialError = false
    private let defaults: UserDefaults
    private let workspace: TutorialWorkspace
    private static let completionKey = "onboarding.completed.v1"

    init(defaults: UserDefaults = .standard, workspace: TutorialWorkspace? = nil) {
        self.defaults = defaults
        self.workspace = workspace ?? TutorialWorkspace()
        hasCompletedWelcome = defaults.bool(forKey: Self.completionKey)
    }

    func requestTutorial() {
        guard tutorialFolder == nil, !preparesTutorial else { return }
        tutorialError = false
        preparesTutorial = true
    }

    /// Called by the view's task so preparation shares the presentation's lifetime.
    func prepareTutorial() async {
        guard preparesTutorial else { return }
        defer { preparesTutorial = false }
        await Task.yield()
        guard !Task.isCancelled else { return }
        do { tutorialFolder = try workspace.prepare() }
        catch { tutorialError = true }
    }

    func completeWelcome() {
        hasCompletedWelcome = true
        defaults.set(true, forKey: Self.completionKey)
    }

    func finishTutorial() {
        let folder = tutorialFolder
        tutorialFolder = nil
        completeWelcome()
        // Cleanup remains best-effort; the next preparation removes stale sessions too.
        if let folder { try? workspace.remove(folder) }
    }
}
