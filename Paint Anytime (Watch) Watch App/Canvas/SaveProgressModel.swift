import Foundation
import Observation

/// Estimated progress of one running save, for the save overlay or the autosave capsule.
/// Separate from `DrawingSessionController` so its updates (a few per second) redraw
/// only the small views that read it, not the canvas screen.
///
/// The estimate is not predicted from the drawing alone (layer costs differ too much):
/// it follows the save's own progress (`RenderProgress`). Before that says much, it
/// starts from the timing of earlier saves on this watch: seconds per layer unit and the
/// share of the save that rendering takes. Hidden for quick saves.
@MainActor
@Observable
final class SaveProgressModel {
    /// Overall progress 0…1 while shown; nil hides the indicator.
    private(set) var fraction: Double?
    /// Estimated seconds left while shown.
    private(set) var remaining: Double?
    /// Whether the time left is shown; changes only when it appears or goes, so a
    /// layout that depends on it is not re-evaluated on every update.
    private(set) var isShown = false

    /// Shown only after this long, and only when the whole save looks longer than
    /// `minimumShownTotal`: a short save keeps the plain spinner.
    static let showsAfter = 0.8
    static let minimumShownTotal = 1.5
    static let pollInterval = Duration.milliseconds(250)

    @ObservationIgnored private let timingKey: String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var progress: RenderProgress?
    /// Elapsed seconds at the previous update, for the indicator's step.
    @ObservationIgnored private var lastElapsed: Double?

    /// - Parameter timingKey: Manual saves and autosaves (lower priority) keep separate timings.
    init(timingKey: String) {
        self.timingKey = timingKey
    }

    private var secondsPerUnitKey: String { "saveTiming.\(timingKey).secondsPerUnit" }
    private var renderShareKey: String { "saveTiming.\(timingKey).renderShare" }

    private var secondsPerUnit: Double? {
        let value = UserDefaults.standard.double(forKey: secondsPerUnitKey)
        return value > 0 && value.isFinite ? value : nil
    }

    private var renderShare: Double {
        let value = UserDefaults.standard.double(forKey: renderShareKey)
        return value > 0.05 && value <= 1 ? value : 0.8
    }

    func track(_ progress: RenderProgress) {
        task?.cancel()
        self.progress = progress
        fraction = nil
        remaining = nil
        lastElapsed = nil
        if isShown { isShown = false }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.update(progress.snapshot)
            }
        }
    }

    /// Stops the indicator; a completed save teaches the next estimate its timing.
    func finish(succeeded: Bool) {
        task?.cancel()
        task = nil
        if succeeded, let snapshot = progress?.snapshot, let render = snapshot.renderSeconds,
           snapshot.units > 0, snapshot.elapsed > 0.05 {
            // Smoothed, so one unusual save does not swing the next estimate.
            let unit = render / snapshot.units
            let share = min(1, max(0.05, render / snapshot.elapsed))
            let defaults = UserDefaults.standard
            defaults.set(secondsPerUnit.map { $0 * 0.5 + unit * 0.5 } ?? unit, forKey: secondsPerUnitKey)
            defaults.set(renderShare * 0.5 + share * 0.5, forKey: renderShareKey)
        }
        progress = nil
        fraction = nil
        remaining = nil
        lastElapsed = nil
        if isShown { isShown = false }
    }

    private func update(_ snapshot: RenderProgress.Snapshot) {
        let share = renderShare
        let overall: Double
        switch snapshot.phase {
        case .rendering: overall = snapshot.renderFraction * share
        case .encoding: overall = share + (1 - share) * 0.5
        case .writing: overall = share + (1 - share) * 0.85
        case .finished: overall = 1
        }
        // Earlier saves' pace for this much work, then the save's own pace as it shows.
        let prior = snapshot.units > 0 ? secondsPerUnit.map { snapshot.units * $0 / share } : nil
        let measured = overall > 0.03 ? snapshot.elapsed / overall : nil
        let total: Double?
        switch (prior, measured) {
        case let (prior?, measured?):
            let trust = min(1, overall * 2)
            total = prior * (1 - trust) + measured * trust
        case let (prior?, nil): total = prior
        case let (nil, measured?): total = measured
        default: total = nil
        }
        guard let total, snapshot.elapsed >= Self.showsAfter || fraction != nil,
              total >= Self.minimumShownTotal || fraction != nil else { return }
        let left = max(0, total - snapshot.elapsed)
        // Count down steadily; rise only when the estimate clearly grew.
        if let shown = remaining, left > shown, left < shown * 1.3 + 1 {
            remaining = max(0, shown - 0.25)
        } else {
            remaining = left
        }
        // Never moves back (the save bar and the autosave ring both read it). Each update
        // it covers the share of its unfilled part that this step is of the time left, so
        // it slows down when the estimate grows and would end with the save; it jumps
        // forward when the estimate shrinks.
        let timeLeft = max(0.001, remaining ?? 0)
        let timeShare = min(1, snapshot.elapsed / (snapshot.elapsed + timeLeft))
        if let shown = fraction, let last = lastElapsed {
            let step = max(0, snapshot.elapsed - last)
            let advanced = shown + (1 - shown) * min(1, step / timeLeft)
            fraction = min(1, max(advanced, timeShare))
        } else {
            fraction = timeShare
        }
        lastElapsed = snapshot.elapsed
        if !isShown { isShown = true }
    }
}
