import Foundation

/// Add a language here after translating Localizable.xcstrings in Xcode.
struct AppLanguage: Identifiable {
    let id: String
    let nativeName: String

    static let storageKey = "app.language"
    private static let preferredCodeCache = NSCache<NSString, NSString>()
    // Keep English first for language negotiation; sort the picker separately.
    static let supported: [AppLanguage] = [
        .init(id: "en", nativeName: "English"),
        .init(id: "ru", nativeName: "Русский"),
        .init(id: "ar", nativeName: "العربية"),
        .init(id: "fr", nativeName: "Français"),
        .init(id: "de", nativeName: "Deutsch"),
        .init(id: "it", nativeName: "Italiano"),
        .init(id: "ja", nativeName: "日本語"),
        .init(id: "ko", nativeName: "한국어"),
        .init(id: "pt-PT", nativeName: "Português (Portugal)"),
        .init(id: "pt-BR", nativeName: "Português (Brasil)"),
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
        .init(id: "id", nativeName: "Bahasa Indonesia"),
        .init(id: "vi", nativeName: "Tiếng Việt"),
        .init(id: "th", nativeName: "ไทย"),
        .init(id: "uk", nativeName: "Українська"),
        .init(id: "cs", nativeName: "Čeština"),
        .init(id: "hu", nativeName: "Magyar"),
        .init(id: "el", nativeName: "Ελληνικά"),
        .init(id: "he", nativeName: "עברית")
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
        let key = preferences.joined(separator: "\u{001F}") as NSString
        if let cached = preferredCodeCache.object(forKey: key) { return cached as String }
        let code = Bundle.preferredLocalizations(from: supported.map(\.id),
                                                forPreferences: preferences).first ?? "en"
        preferredCodeCache.setObject(code as NSString, forKey: key)
        return code
    }

    static var currentCode: String {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? defaultCode
        return resolvedSavedCode(saved, preferences: Locale.preferredLanguages)
    }

    /// Preserve the previous generic Portuguese selection after adding regional variants.
    static func resolvedSavedCode(_ saved: String, preferences: [String]) -> String {
        if saved == "pt" {
            let portuguesePreferences = preferences.filter {
                $0.replacingOccurrences(of: "_", with: "-")
                    .split(separator: "-").first?.lowercased() == "pt"
            }
            return preferredCode(for: portuguesePreferences + ["pt-PT"])
        }
        return supported.contains { $0.id == saved } ? saved : preferredCode(for: preferences)
    }
}

/// Explicit bundle selection also localizes model titles and error messages.
/// Missing translations fall back to English, then to the readable English key.
enum L10n {
    // Cache by language as well as key so switching languages never reuses old text.
    private static let bundles = NSCache<NSString, Bundle>()
    private static let strings: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()

    static func text(_ key: String) -> String {
        let code = AppLanguage.currentCode
        let cacheKey = (code + "\u{001F}" + key) as NSString
        if let cached = strings.object(forKey: cacheKey) { return cached as String }
        let fallback = bundle(for: "en")?.localizedString(forKey: key, value: key, table: nil) ?? key
        let result = bundle(for: code)?
            .localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        strings.setObject(result as NSString, forKey: cacheKey)
        return result
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: AppLanguage.currentCode), arguments: arguments)
    }

    private static func bundle(for code: String) -> Bundle? {
        if let cached = bundles.object(forKey: code as NSString) { return cached }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        bundles.setObject(bundle, forKey: code as NSString)
        return bundle
    }
}
