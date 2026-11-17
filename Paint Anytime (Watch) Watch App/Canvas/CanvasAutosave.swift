import Foundation
import Observation

/// The autosave countdown and its quiet save cycle. The canvas screen supplies its
/// state through closures, read again after every suspension. Saving does not block
/// the canvas: the session renders and writes in the background.
@MainActor
@Observable
final class CanvasAutosave {
    /// The countdown shown in place of the hidden clock; nil while not counting.
    var timerRange: ClosedRange<Date>?
    /// A countdown save is writing; the countdown shows a loading wheel.
    private(set) var isSaving = false
    @ObservationIgnored private var scheduleID: String?

    /// - Parameters:
    ///   - configurationID: A new value restarts the countdown.
    ///   - canRun: Autosave is enabled and the screen is active.
    ///   - isBusy: Interaction or a presentation that a save must wait for.
    ///   - prepare: Returns false when there is nothing to save.
    ///   - save: Saves the drawing; returns true once a save completed.
    func run(configurationID: String, seconds: Int,
             canRun: () -> Bool, isBusy: () -> Bool,
             prepare: () -> Bool, save: () async -> Bool) async {
        guard !Task.isCancelled else { return }
        if scheduleID != configurationID {
            scheduleID = configurationID
            timerRange = nil
        }
        guard canRun() else { return }
        // Every exit (cancellation, a disabled autosave) brings the clock icon back.
        defer { isSaving = false }
        do {
            while !Task.isCancelled {
                // Preserve the deadline across wrist-down and background transitions.
                // An overdue save runs on activation once the canvas is idle.
                if timerRange == nil {
                    let start = Date()
                    timerRange = start...start.addingTimeInterval(TimeInterval(seconds))
                }
                if let deadline = timerRange?.upperBound {
                    let remaining = deadline.timeIntervalSinceNow
                    if remaining > 0 {
                        // A tight tolerance: with the default one a sleep of minutes could end
                        // seconds late, leaving the countdown at 0:00 with its clock icon.
                        try await Task.sleep(until: .now + .seconds(remaining),
                                             tolerance: .milliseconds(20), clock: .continuous)
                    }
                }
                try Task.checkCancellation()
                guard canRun() else { return }
                // 0:00: the wheel replaces the clock icon at once, also while the save waits
                // for the canvas below. Kept long enough to read as a save, not a flicker.
                let shownUntil = ContinuousClock.now.advanced(by: .milliseconds(700))
                isSaving = true
                // Let the icon's 0.25 s transition play before the save: its main-actor
                // part holds frames.
                try await Task.sleep(for: .milliseconds(300))
                // Wait for interaction and presentations to finish without cancelling a stroke
                // or saving a temporary selection state. Retry promptly once the canvas is idle.
                while isBusy() {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                guard canRun() else { return }
                if prepare() {
                    // The write is not tied to this task, so wrist-down does not interrupt it.
                    _ = await save()
                }
                // Nothing to save: the countdown restarts after the same short wheel.
                try? await Task.sleep(until: shownUntil, clock: .continuous)
                isSaving = false
                timerRange = nil
            }
        } catch {
            // Cancellation stops execution, but keeps the deadline for activation.
        }
    }

    /// A save outside the countdown (on wrist-down) restarts it on activation.
    func restartCountdown() {
        timerRange = nil
    }
}
