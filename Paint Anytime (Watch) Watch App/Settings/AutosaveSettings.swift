enum AutosaveSettings {
    static let enabledKey = "watch.autosave.enabled"
    static let intervalKey = "watch.autosave.minutes"
    /// Countdown above the canvas; on by default, and the user's choice is kept.
    static let showsTimerKey = "watch.autosave.showsTimer"
    static let defaultShowsTimer = true
    static let intervals = [1, 2, 5, 10]
    static let defaultMinutes = 1

    static func minutes(_ storedValue: Int) -> Int {
        intervals.contains(storedValue) ? storedValue : defaultMinutes
    }
}
