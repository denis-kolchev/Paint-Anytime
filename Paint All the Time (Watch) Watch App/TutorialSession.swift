import Foundation
import Combine

/// The inactive instance keeps the normal editor free of tutorial restrictions.
@MainActor
final class TutorialSession: ObservableObject {
    static let inactive = TutorialSession()
    @Published private var progress = TutorialProgress()
    var step: TutorialStep { progress.step }
    @Published var showsInstruction = false
    @Published private(set) var remindersPaused = false
    private var lastActivity = Date()
    private var reminderTask: Task<Void, Never>?
    private var zoomIdleTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    private var pendingAdvanceStep: TutorialStep?
    @Published private(set) var showsResult = false
    var isActive: Bool { step != .inactive }
    var acceptsActions: Bool { !isActive || (!showsInstruction && !showsResult) }
    var allowsDrawing: Bool { permits([.firstStrokes, .reedStrokes]) }
    var allowsCanvasZoom: Bool { permits([.zoomCanvas]) }
    var allowsCanvasPan: Bool { permits([.panCanvas]) }
    var allowsGalleryZoom: Bool { permits([.galleryFullscreen]) }
    var allowsGalleryPaging: Bool { permits([.deleteDrawing]) }
    var allowsGalleryDelete: Bool { permits([.deleteDrawing]) }
    var allowsGalleryBack: Bool { permits([.returnToCanvas]) }
    var allowsToolInfo: Bool { permits([.readToolInfo]) }

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
        remindersPaused = false
        zoomIdleTask?.cancel()
        showsInstruction = true
        lastActivity = Date()
        reminderTask?.cancel()
        reminderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isActive else { return }
                if !self.showsInstruction && !self.remindersPaused && self.pendingAdvanceStep == nil && Date().timeIntervalSince(self.lastActivity) >= 5 {
                    TutorialDebug.trace("reminder.showCard", self.debugState)
                    self.showsInstruction = true
                }
            }
        }
    }

    /// Next dismisses a lesson card. It never skips an unfinished exercise.
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
        zoomIdleTask?.cancel()
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

    var canFinishCamera: Bool { !isActive || progress.hasPanned }

    func changedPage(_ page: Int) {
        guard isActive, acceptsActions else { return }
        activity()
        if progress.completesPageChange(page) { advanceAfterResult(lockInput: true) }
    }

    func changedStyle(_ style: PencilStyle) {
        guard isActive, acceptsActions else { return }
        activity()
        guard let matches = progress.matchesStyle(style) else { return }
        // A brief pass over the target does not finish the lesson. The user
        // can keep adjusting; a different value cancels the pending transition.
        if matches { advanceAfterResult(lockInput: false) }
        else { cancelPendingAdvance() }
    }

    func changedZoom() {
        guard isActive, allowsCanvasZoom else { return }
        activity()
        zoomIdleTask?.cancel()
        zoomIdleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.step == .zoomCanvas, !self.showsInstruction, !self.remindersPaused else { return }
            self.advance()
        }
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
        zoomIdleTask?.cancel()
        progress.advance()
        showsInstruction = true
        activity()
    }

    func stop() {
        cancelPendingAdvance()
        reminderTask?.cancel()
        zoomIdleTask?.cancel()
        reminderTask = nil
        zoomIdleTask = nil
        progress.stop()
        showsInstruction = false
    }
}
