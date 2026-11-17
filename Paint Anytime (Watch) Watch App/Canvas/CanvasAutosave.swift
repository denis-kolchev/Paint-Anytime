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
                        try await Task.sleep(for: .seconds(remaining))
                    }
                }
                // Wait for interaction and presentations to finish without cancelling a stroke
                // or saving a temporary selection state. Retry promptly once the canvas is idle.
                while isBusy() {
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                guard canRun() else { return }
                guard prepare() else {
                    timerRange = nil
                    continue
                }
                // The write is not tied to this task, so wrist-down does not interrupt it.
                _ = await save()
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
