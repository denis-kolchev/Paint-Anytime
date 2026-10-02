import Foundation
import Combine

@main
struct TutorialChecks {
    @MainActor static func main() async throws {
        checkProgress()
        try await checkSession()
        try await checkWorkspaceAndOnboarding()
        print("PASS: tutorial rules, exploration, observation, workspace isolation, onboarding persistence")
    }

    static func checkProgress() {
        var progress = TutorialProgress()
        progress.start()
        precondition(TutorialStep.lessonCount == 23)
        precondition(TutorialStep.clearCanvas.rawValue == 23)
        precondition(TutorialStep.finished.rawValue == 24)
        precondition(progress.record(.stroke) == .none)
        precondition(progress.record(.stroke) == .advance)
        progress.advance()
        precondition(progress.step == .zoomCanvas)
        progress.advance()
        precondition(progress.record(.finishedCamera) == .none)
        precondition(progress.record(.panned) == .advance && progress.hasPanned)
        progress.advance()
        precondition(progress.step == .finishCamera)
        precondition(progress.record(.finishedCamera) == .advance)
        progress.advance()
        precondition(progress.record(.openedTools) == .advance)
        progress.advance()
        let original = PencilStyle()
        var style = original
        style.color = SIMD4(0.95, 0.18, 0.22, 1)
        precondition(!progress.changedStyle(from: original, to: original, page: 1))
        precondition(!progress.changedStyle(from: original, to: style, page: 0))
        precondition(progress.changedStyle(from: original, to: style, page: 1))
        precondition(progress.visibleToolPages == [0, 1, 2, 3, 4])
        precondition(progress.allowsToolAdjustment(page: 0) && progress.allowsToolPage(2))
        progress.advance()
        precondition(progress.completesPageChange(0))
        progress.advance()
        style.width = 7
        precondition(progress.changedStyle(from: original, to: style, page: 0))
        progress.advance()
        precondition(progress.completesPageChange(2))
        progress.advance()
        precondition(progress.step == .selectReed, "Tool page goes straight to Reed selection")
        precondition(progress.record(.openedInfo) == .pauseReminders)
        precondition(progress.record(.closedInfo) == .resumeReminders(advance: false))
        precondition(progress.step == .selectReed, "Optional information must not skip Reed selection")
        style.instrument = .reed
        precondition(progress.changedStyle(from: original, to: style, page: 2))
        progress.advance()
        precondition(progress.step == .openAngle)
        precondition(!progress.changedStyle(from: style, to: original, page: 2))
        precondition(progress.step == .selectReed, "Leaving Reed restores its selection hint")
        precondition(progress.changedStyle(from: original, to: style, page: 2))
        progress.advance()
        precondition(progress.completesPageChange(4))
        progress.advance()
        var angled = style
        angled.reedAngle = 35
        precondition(progress.changedStyle(from: style, to: angled, page: 4))
        progress.advance()
        precondition(progress.record(.closedTools) == .advance)
        progress.advance()
        precondition(progress.record(.stroke) == .advance)
        progress.advance()
        precondition(progress.record(.history) == .none)
        precondition(progress.record(.history) == .advance)
        progress.advance()
        for (step, event, effect): (TutorialStep, TutorialProgress.Event, TutorialProgress.Effect) in [
            (.saveDrawing, .saved, .advance), (.shareDrawing, .closedSave, .advance),
            (.openMenu, .openedMenu, .advance), (.openGallery, .openedGallery, .advance),
            (.galleryFullscreen, .galleryFullscreen, .advance), (.deleteDrawing, .deleted, .advance),
            (.returnToCanvas, .returnedToCanvas, .advance), (.clearCanvas, .cleared, .showResult)
        ] {
            precondition(progress.step == step && progress.record(event) == effect)
            progress.advance()
        }
        precondition(progress.step == .finished)
        progress.advance()
        precondition(progress.step == .finished)
        progress.stop()
        progress.start()
        precondition(progress.step == .firstStrokes && !progress.hasPanned)
    }

    @MainActor static func checkSession() async throws {
        let session = TutorialSession()
        var notifications = 0
        let subscription = session.objectWillChange.sink { notifications += 1 }
        defer { session.stop(); withExtendedLifetime(subscription) {} }
        precondition(session.allowsDrawing && session.allowsToolPage(4))
        session.start()
        session.record(.stroke)
        session.record(.stroke)
        precondition(session.step == .zoomCanvas && !session.canFinishCamera)
        session.changedZoom()
        precondition(session.step == .panCanvas && session.showsPanGuide && session.allowsCanvasZoom)
        session.record(.panned)
        precondition(session.step == .finishCamera && !session.showsPanGuide && session.canFinishCamera)
        session.record(.finishedCamera)
        precondition(session.step == .openTools && session.allowsDrawing)
        session.record(.openedTools)
        precondition(session.step == .selectColor && session.acceptsActions)
        var style = PencilStyle()
        let old = style
        style.color = SIMD4(0.95, 0.18, 0.22, 1)
        session.changedStyle(from: old, to: style, page: 1)
        precondition(session.step == .openWidth && session.allowsToolAdjustment(page: 1))
        session.changedPage(0)
        precondition(session.step == .setWidth && session.allowsToolPage(1))
        session.stop()
        session.start()
        session.record(.stroke)
        session.record(.stroke)
        session.changedZoom()
        session.stop()
        try await Task.sleep(for: .milliseconds(650))
        precondition(session.step == .inactive)
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
        precondition(ToolSynchronization().width && ToolSynchronization().color)
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
