import Foundation
import Combine

@main
struct TutorialChecks {
    @MainActor static func main() async throws {
        checkProgress()
        try await checkSession()
        try await checkWorkspaceAndOnboarding()
        print("PASS: tutorial rules, delayed transitions, cancellation, observation, workspace isolation, onboarding persistence")
    }

    static func checkProgress() {
        var progress = TutorialProgress()
        progress.advance()
        precondition(progress.step == .inactive)
        progress.start()
        precondition(progress.record(.saved) == .none)
        precondition(progress.record(.stroke) == .none)
        precondition(progress.record(.stroke) == .advance)
        progress.advance()
        precondition(progress.step == .openTools && progress.record(.openedTools) == .showResult)
        progress.advance()
        var style = PencilStyle()
        precondition(progress.matchesStyle(style) == false)
        style.color = SIMD4(0.2, 0.7, 0.35, 1)
        precondition(progress.matchesStyle(style) == true)
        precondition(progress.visibleToolPages == [1] && progress.allowsToolAdjustment(page: 1))
        precondition(!progress.allowsToolAdjustment(page: 0))
        progress.advance()
        precondition(progress.step == .openWidth && progress.completesPageChange(0))
        precondition(!progress.completesPageChange(1) && progress.allowsToolPage(0))
        progress.advance()
        style.width = 10
        precondition(progress.step == .setWidth && progress.matchesStyle(style) == true)
        progress.advance()
        style.instrument = .reed
        precondition(progress.step == .selectReed && progress.matchesStyle(style) == true)
        progress.advance()
        precondition(progress.record(.closedInfo) == .resumeReminders(advance: false))
        precondition(progress.record(.openedInfo) == .pauseReminders)
        precondition(progress.record(.closedInfo) == .resumeReminders(advance: true))
        progress.advance()
        style.reedAngle = 20
        precondition(progress.step == .setAngle && progress.matchesStyle(style) == true)
        progress.advance()
        precondition(progress.record(.stroke) == .none && progress.count == 0)
        precondition(progress.record(.closedTools) == .none)
        precondition(progress.record(.stroke) == .none)
        precondition(progress.record(.stroke) == .advance)
        progress.advance()
        precondition(progress.step == .zoomCanvas)
        progress.advance()
        precondition(progress.record(.finishedCamera) == .none)
        precondition(progress.record(.panned) == .none && progress.hasPanned)
        precondition(progress.record(.finishedCamera) == .advance)
        progress.advance()
        precondition(progress.record(.history) == .none)
        precondition(progress.record(.history) == .showResult)
        progress.advance()
        for (step, event, effect): (TutorialStep, TutorialProgress.Event, TutorialProgress.Effect) in [
            (.saveDrawing, .saved, .advance), (.shareDrawing, .closedSave, .advance),
            (.openGallery, .openedGallery, .showResult), (.galleryFullscreen, .galleryFullscreen, .advance),
            (.deleteDrawing, .deleted, .advance), (.returnToCanvas, .returnedToCanvas, .showResult),
            (.clearCanvas, .cleared, .showResult)
        ] {
            precondition(progress.step == step && progress.record(event) == effect)
            progress.advance()
        }
        precondition(progress.step == .finished)
        progress.advance()
        precondition(progress.step == .finished)
        progress.stop()
        progress.start()
        precondition(progress.step == .firstStrokes && progress.count == 0 && !progress.hasPanned)
    }

    @MainActor static func checkSession() async throws {
        let session = TutorialSession()
        var notifications = 0
        let subscription = session.objectWillChange.sink { notifications += 1 }
        defer { session.stop(); withExtendedLifetime(subscription) {} }
        precondition(session.allowsDrawing && session.allowsToolPage(4))
        session.start()
        precondition(session.allowsDrawing && session.step == .firstStrokes)
        session.beginExercise()
        session.record(.stroke)
        precondition(session.step == .firstStrokes)
        session.record(.stroke)
        precondition(session.step == .openTools && !session.showsInstruction)
        session.beginExercise()
        session.record(.openedTools)
        precondition(session.showsResult && !session.acceptsActions)
        session.pauseReminders()
        try await Task.sleep(for: .milliseconds(1400))
        precondition(session.step == .openTools)
        session.resumeReminders()
        try await Task.sleep(for: .milliseconds(1400))
        precondition(session.step == .selectGreen && !session.showsInstruction)
        session.beginExercise()
        var style = PencilStyle()
        style.color = SIMD4(0.2, 0.7, 0.35, 1)
        session.changedStyle(style)
        style.color = SIMD4(0, 0, 0, 1)
        session.changedStyle(style)
        try await Task.sleep(for: .milliseconds(1400))
        precondition(session.step == .selectGreen, "Passing over a target must not complete the lesson")
        style.color = SIMD4(0.2, 0.7, 0.35, 1)
        session.changedStyle(style)
        session.stop()
        try await Task.sleep(for: .milliseconds(1400))
        precondition(session.step == .inactive && !session.showsInstruction && !session.showsResult)
        precondition(notifications > 0)
    }

    @MainActor static func checkWorkspaceAndOnboarding() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("originals", isDirectory: true)
        let root = base.appendingPathComponent("practice", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = source.appendingPathComponent("sample.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: original)
        let workspace = TutorialWorkspace(root: root, source: source)
        let first = try workspace.prepare()
        try Data([4]).write(to: first.appendingPathComponent("sample.png"))
        let originalBytes = try Data(contentsOf: original)
        precondition(originalBytes == bytes)
        do {
            try workspace.remove(source)
            preconditionFailure("Must reject deletion outside the workspace")
        } catch { precondition(FileManager.default.fileExists(atPath: original.path)) }
        let second = try workspace.prepare()
        precondition(!FileManager.default.fileExists(atPath: first.path))
        precondition(FileManager.default.fileExists(atPath: second.path))
        try workspace.remove(second)
        let suite = "TutorialChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = OnboardingController(defaults: defaults, workspace: workspace)
        precondition(!onboarding.hasCompletedWelcome)
        onboarding.requestTutorial()
        precondition(onboarding.preparesTutorial)
        await onboarding.prepareTutorial()
        precondition(!onboarding.preparesTutorial && !onboarding.tutorialError)
        let folder = onboarding.tutorialFolder!
        onboarding.finishTutorial()
        precondition(onboarding.hasCompletedWelcome && onboarding.tutorialFolder == nil)
        precondition(!FileManager.default.fileExists(atPath: folder.path))
        precondition(OnboardingController(defaults: defaults, workspace: workspace).hasCompletedWelcome)
        onboarding.requestTutorial()
        await onboarding.prepareTutorial()
        precondition(onboarding.tutorialFolder != nil, "A completed tour can be repeated")
        onboarding.finishTutorial()
        let unavailable = OnboardingController(defaults: defaults,
            workspace: TutorialWorkspace(root: root, source: nil))
        unavailable.requestTutorial()
        await unavailable.prepareTutorial()
        precondition(unavailable.tutorialError && unavailable.tutorialFolder == nil && !unavailable.preparesTutorial)
    }
}
