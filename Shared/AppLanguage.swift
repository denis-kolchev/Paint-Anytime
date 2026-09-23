import Foundation

/// Add a language here after translating Localizable.xcstrings in Xcode.
struct AppLanguage: Identifiable {
    let id: String
    let nativeName: String

    static let storageKey = "app.language"
    // Keep English first for language negotiation; sort the picker separately.
    static let supported: [AppLanguage] = [
        .init(id: "en", nativeName: "English"),
        .init(id: "ru", nativeName: "Русский"),
        .init(id: "ar", nativeName: "العربية"),
        .init(id: "fr", nativeName: "Français"),
        .init(id: "de", nativeName: "Deutsch"),
        .init(id: "hi", nativeName: "हिन्दी"),
        .init(id: "it", nativeName: "Italiano"),
        .init(id: "ja", nativeName: "日本語"),
        .init(id: "ko", nativeName: "한국어"),
        .init(id: "pt", nativeName: "Português"),
        .init(id: "zh-Hans", nativeName: "简体中文"),
        .init(id: "es", nativeName: "Español"),
        .init(id: "tr", nativeName: "Türkçe"),
        .init(id: "zh-Hant", nativeName: "繁體中文"),
        .init(id: "pl", nativeName: "Polski"),
        .init(id: "nl", nativeName: "Nederlands"),
        .init(id: "sv", nativeName: "Svenska"),
        .init(id: "da", nativeName: "Dansk"),
        .init(id: "nb", nativeName: "Norsk"),
        .init(id: "fi", nativeName: "Suomi"),
        .init(id: "ta", nativeName: "தமிழ்"),
        .init(id: "te", nativeName: "తెలుగు"),
        .init(id: "mr", nativeName: "मराठी"),
        .init(id: "gu", nativeName: "ગુજરાતી"),
        .init(id: "pa", nativeName: "ਪੰਜਾਬੀ"),
        .init(id: "bn", nativeName: "বাংলা"),
        .init(id: "id", nativeName: "Bahasa Indonesia"),
        .init(id: "ur", nativeName: "اردو"),
        .init(id: "vi", nativeName: "Tiếng Việt"),
        .init(id: "th", nativeName: "ไทย"),
        .init(id: "ms", nativeName: "Bahasa Melayu")
    ]

    /// Use system collation for native names, independent of the in-app language.
    static var displayOrder: [AppLanguage] {
        supported.sorted {
            let order = $0.nativeName.localizedStandardCompare($1.nativeName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static var defaultCode: String {
        preferredCode(for: Locale.preferredLanguages)
    }

    /// Match regional variants (ru-RU, en-GB) in the user's preference order.
    /// English is the development language when none of them is supported.
    static func preferredCode(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: supported.map(\.id),
                                      forPreferences: preferences).first ?? "en"
    }

    static var currentCode: String {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? defaultCode
        return supported.contains { $0.id == saved } ? saved : defaultCode
    }
}

/// Explicit bundle selection also localizes model titles and error messages.
/// Missing translations fall back to English, then to the readable English key.
enum L10n {
    static func text(_ key: String) -> String {
        let fallback = bundle(for: "en")?.localizedString(forKey: key, value: key, table: nil) ?? key
        return bundle(for: AppLanguage.currentCode)?
            .localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: AppLanguage.currentCode), arguments: arguments)
    }

    private static func bundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
