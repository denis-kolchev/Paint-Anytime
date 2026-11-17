enum AutosaveSettings {
    static let enabledKey = "watch.autosave.enabled"
    static let intervalKey = "watch.autosave.minutes"
    /// Countdown above the canvas; on by default, and the user's choice is kept.
    static let showsTimerKey = "watch.autosave.showsTimer"
    static let defaultShowsTimer = true
    static let intervals = [1, 2, 5, 10]
    static let defaultMinutes = 1

    /// One icon for the menu row and the canvas countdown. The badged symbol needs
    /// watchOS 11; watchOS 10 shows the plain save symbol.
    static var symbolName: String {
        if #available(watchOS 11.0, *) {
            return "square.and.arrow.down.badge.clock"
        }
        return "square.and.arrow.down"
    }

    static func minutes(_ storedValue: Int) -> Int {
        intervals.contains(storedValue) ? storedValue : defaultMinutes
    }
}
