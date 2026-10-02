import Foundation
import Combine

/// The inactive instance keeps the normal editor free of tutorial restrictions.
@MainActor
final class TutorialSession: ObservableObject {
    static let inactive = TutorialSession()
    @Published private var progress = TutorialProgress()
    var step: TutorialStep { progress.step }
    @Published private(set) var toolPage = 1
    @Published var galleryIsOpen = false
    @Published var galleryIsFullscreen = false
    var instruction: String {
        switch step {
        case .selectColor where toolPage != 1: return L10n.text("Open Color, then turn the Crown.")
        case .openWidth where toolPage != 1: return L10n.text("Open Width.")
        case .setWidth where toolPage != 0: return L10n.text("Open Width, then turn the Crown.")
        case .openTool where toolPage != 0: return L10n.text("Open Tool.")
        case .selectReed where toolPage != 2: return L10n.text("Open Tool and choose Reed pen.")
        case .openAngle where toolPage != 2: return L10n.text("Open Angle.")
        case .setAngle where toolPage != 4: return L10n.text("Open Angle, then turn the Crown.")
        case .galleryFullscreen where !galleryIsOpen, .deleteDrawing where !galleryIsOpen: return L10n.text("Tap Gallery to see your pictures.")
        case .deleteDrawing where !galleryIsFullscreen:
            return L10n.text("Turn the Crown or double-tap a picture.")
        default: return TutorialLesson.compactInstruction(for: step)
        }
    }
    @Published var showsInstruction = false
    @Published private(set) var remindersPaused = false
    private var lastActivity = Date()
    private var advanceTask: Task<Void, Never>?
    private var pendingAdvanceStep: TutorialStep?
    @Published private(set) var showsResult = false
    var isActive: Bool { step != .inactive }
    var acceptsActions: Bool { !isActive || (!showsInstruction && !showsResult) }
    var allowsDrawing: Bool { permits([.firstStrokes, .openTools, .reedStrokes, .history, .saveDrawing, .openMenu]) }
    var allowsCanvasZoom: Bool { permits([.zoomCanvas, .panCanvas, .finishCamera, .openTools, .reedStrokes, .history, .saveDrawing, .openMenu]) }
    var allowsCanvasPan: Bool { allowsCanvasZoom }
    var allowsGalleryZoom: Bool { permits([.galleryFullscreen, .deleteDrawing, .returnToCanvas]) }
    var allowsGalleryPaging: Bool { permits([.galleryFullscreen, .deleteDrawing, .returnToCanvas]) }
    var allowsGalleryDelete: Bool { permits([.galleryFullscreen, .deleteDrawing, .returnToCanvas]) }
    var allowsGalleryBack: Bool { permits([.galleryFullscreen, .deleteDrawing, .returnToCanvas]) }
    var allowsToolInfo: Bool { acceptsActions }

    var visibleToolPages: Set<Int> { progress.visibleToolPages }

    func permits(_ steps: Set<TutorialStep>) -> Bool {
        !isActive || (acceptsActions && steps.contains(step))
    }

    func allowsToolAdjustment(page: Int) -> Bool {
        !isActive || (acceptsActions && progress.allowsToolAdjustment(page: page))
    }

    func allowsToolPage(_ page: Int) -> Bool {
        !isActive || (acceptsActions && progress.allowsToolPage(page))
    }

    var debugState: String {
        "session=\(ObjectIdentifier(self)) step=\(step) instruction=\(showsInstruction) result=\(showsResult) paused=\(remindersPaused) acceptsActions=\(acceptsActions) allowsDrawing=\(allowsDrawing) count=\(progress.count)"
    }

    func start() {
        cancelPendingAdvance()
        progress.start()
        toolPage = 1
        galleryIsOpen = false
        galleryIsFullscreen = false
        remindersPaused = false
        showsInstruction = false
        lastActivity = Date()
    }

    /// Retained for callers that explicitly resume an exercise; never skips a step.
    func beginExercise() {
        TutorialDebug.trace("beginExercise.beforeHide", debugState)
        showsInstruction = false
        TutorialDebug.trace("beginExercise.afterHide", debugState)
        activity()
        TutorialDebug.trace("beginExercise.exit", debugState)
    }

    func activity() { if isActive { lastActivity = Date() } }

    func pauseReminders() {
        guard isActive else { return }
        remindersPaused = true
        advanceTask?.cancel()
    }

    func resumeReminders() {
        guard isActive else { return }
        remindersPaused = false
        activity()
        if pendingAdvanceStep == step {
            advanceAfterResult(lockInput: showsResult)
        }
    }

    typealias Event = TutorialProgress.Event

    func record(_ event: Event) {
        guard isActive, acceptsActions else { return }
        activity()
        switch progress.record(event) {
        case .none: break
        case .advance: advance()
        case .showResult: advanceAfterResult(lockInput: true)
        case .pauseReminders: pauseReminders()
        case .resumeReminders(let shouldAdvance):
            resumeReminders()
            if shouldAdvance { advance() }
        }
    }

    var canFinishCamera: Bool { !isActive || (step != .zoomCanvas && step != .panCanvas) }
    var showsPanGuide: Bool { step == .panCanvas && !progress.hasPanned }

    func changedPage(_ page: Int) {
        guard isActive, acceptsActions else { return }
        activity()
        toolPage = page
        if progress.completesPageChange(page) { advance() }
    }

    func changedStyle(from old: PencilStyle, to style: PencilStyle, page: Int) {
        guard isActive, acceptsActions else { return }
        activity()
        if progress.changedStyle(from: old, to: style, page: page) { advance() }
    }

    func changedZoom() {
        guard isActive, allowsCanvasZoom else { return }
        activity()
        if step == .zoomCanvas { advance() }
    }

    /// Leave the result visible long enough for animations and visual feedback.
    private func advanceAfterResult(lockInput: Bool) {
        advanceTask?.cancel()
        pendingAdvanceStep = step
        showsResult = lockInput
        activity()
        guard !remindersPaused else { return }
        let completedStep = step
        advanceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            guard let self, !Task.isCancelled, self.step == completedStep,
                  self.pendingAdvanceStep == completedStep,
                  !self.showsInstruction, !self.remindersPaused else { return }
            self.advance()
        }
    }

    private func cancelPendingAdvance() {
        advanceTask?.cancel()
        advanceTask = nil
        pendingAdvanceStep = nil
        showsResult = false
    }

    private func advance() {
        guard step != .inactive, step != .finished else { return }
        cancelPendingAdvance()
        progress.advance()
        showsInstruction = false
        activity()
    }

    func stop() {
        cancelPendingAdvance()
        progress.stop()
        showsInstruction = false
    }
}
