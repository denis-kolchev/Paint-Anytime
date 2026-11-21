import Combine
import Foundation

@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var hasCompletedWelcome: Bool
    @Published private(set) var tutorialFolder: URL?
    @Published private(set) var preparesTutorial = false
    /// Chapters of the requested run: the full tour or one chapter from the menu.
    @Published private(set) var tutorialChapters = TutorialChapter.allCases
    /// The saved place the requested run continues from; nil starts at the beginning.
    @Published private(set) var tutorialResume: TutorialResumeSnapshot?
    @Published var tutorialError = false
    private let defaults: UserDefaults
    private let workspace: TutorialWorkspace
    let resumeStore: TutorialResumeStore
    /// The chapter whose saved place the requested run loads while it prepares.
    private var requestedResume: TutorialChapter?
    private static let completionKey = "onboarding.completed.v1"

    init(defaults: UserDefaults = .standard, workspace: TutorialWorkspace? = nil) {
        self.defaults = defaults
        self.workspace = workspace ?? TutorialWorkspace()
        resumeStore = TutorialResumeStore(defaults: defaults)
        hasCompletedWelcome = defaults.bool(forKey: Self.completionKey)
    }

    /// Read on demand: the welcome flow and the editor menu own separate controllers.
    var completedChapters: Set<TutorialChapter> { TutorialChapter.completed(in: defaults) }

    /// Chapters left part-way through, with a place to continue from.
    var inProgressChapters: Set<TutorialChapter> {
        Set(TutorialChapter.allCases.filter { resumeStore.point(for: $0.rawValue)?.isValid == true })
    }

    /// `resumes` continues a single chapter where it was left; a single chapter started
    /// without it begins again and forgets that place.
    func requestTutorial(chapters: [TutorialChapter] = TutorialChapter.allCases, resumes: Bool = false) {
        guard tutorialFolder == nil, !preparesTutorial else { return }
        tutorialChapters = chapters.isEmpty ? TutorialChapter.allCases : chapters
        requestedResume = nil
        tutorialResume = nil
        if chapters.count == 1, let chapter = chapters.first {
            if resumes { requestedResume = chapter } else { resumeStore.clear(chapter.rawValue) }
        }
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
        let resumeStore = resumeStore
        let resumedChapter = requestedResume?.rawValue
        do {
            // The saved canvas is read in the same background pass as the copies.
            let (folder, resume) = try await Task.detached(priority: .userInitiated) {
                (try workspace.prepare(), resumedChapter.flatMap { resumeStore.load($0) })
            }.value
            guard !Task.isCancelled else {
                try? workspace.remove(folder)
                return
            }
            tutorialResume = resume
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
        tutorialResume = nil
        requestedResume = nil
        completeWelcome()
        // Cleanup remains best-effort; the next preparation removes stale sessions too.
        if let folder { try? workspace.remove(folder) }
    }
}
