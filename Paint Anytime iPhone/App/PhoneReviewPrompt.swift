import Foundation

/// Decides when the iPhone app asks for an App Store review.
///
/// Each app version counts the calendar days on which the app became active.
/// After `requiredDaysOfUse` such days the review request is due, once per version.
/// StoreKit still decides whether the system sheet appears (at most three times a year).
enum PhoneReviewPrompt {
    static let requiredDaysOfUse = 3

    private static let versionKey = "reviewPrompt.version"
    private static let usageDaysKey = "reviewPrompt.usageDays"
    private static let requestedKey = "reviewPrompt.requested"

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Counts today as a day of use. A new version starts counting from zero.
    static func recordActiveDay(now: Date = .now, defaults: UserDefaults = .standard) {
        let version = currentVersion
        if defaults.string(forKey: versionKey) != version {
            defaults.set(version, forKey: versionKey)
            defaults.set([String](), forKey: usageDaysKey)
            defaults.set(false, forKey: requestedKey)
        }
        let day = dayString(now)
        var days = defaults.stringArray(forKey: usageDaysKey) ?? []
        guard !days.contains(day) else { return }
        days.append(day)
        defaults.set(days, forKey: usageDaysKey)
    }

    /// True when this version has been used on enough days and has not asked yet.
    static func isDue(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: versionKey) == currentVersion,
              !defaults.bool(forKey: requestedKey) else { return false }
        return (defaults.stringArray(forKey: usageDaysKey) ?? []).count >= requiredDaysOfUse
    }

    static func markRequested(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: requestedKey)
    }

    private static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
