import Foundation
import Observation

/// The autosave countdown and its save-with-progress cycle. The canvas screen
/// supplies its state through closures, read again after every suspension.
@MainActor
@Observable
final class CanvasAutosave {
    /// The countdown shown in place of the hidden clock; nil while not counting.
    var timerRange: ClosedRange<Date>?
    var showsProgress = false
    var completed = false
    @ObservationIgnored private var scheduleID: String?

    /// - Parameters:
    ///   - configurationID: A new value restarts the countdown.
    ///   - canRun: Autosave is enabled and the screen is active.
    ///   - isBusy: Interaction or a presentation that a save must wait for.
    ///   - prepare: Returns false when there is nothing to save.
    ///   - save: Saves the drawing; returns true once a save completed.
    func run(configurationID: String, seconds: Int,
             canRun: () -> Bool, isBusy: () -> Bool,
             prepare: () -> Bool, save: () -> Bool) async {
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
                try await saveWithProgress(canRun: canRun, prepare: prepare, save: save)
                timerRange = nil
            }
        } catch {
            // Cancellation stops execution, but keeps the deadline for activation.
        }
    }

    private func saveWithProgress(canRun: () -> Bool, prepare: () -> Bool,
                                  save: () -> Bool) async throws {
        guard prepare() else { return }
        completed = false
        showsProgress = true
        defer {
            // Retain the checkmark while the overlay fades out.
            showsProgress = false
        }
        // Present the overlay before the existing synchronous exporter starts.
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        guard canRun() else { return }
        guard save() else { return }
        // The save is complete even if sleep cancels the checkmark animation.
        timerRange = nil
        completed = true
        try await Task.sleep(for: .milliseconds(300))
    }
}
