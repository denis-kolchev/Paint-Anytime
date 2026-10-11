//
//  PaintAnytimeWatchApp.swift
//  Paint Anytime (Watch) Watch App
//
//  Created by Denis Kolchev on 19.09.2026.
//

import SwiftUI

@main
struct PaintAnytimeWatchApp: App {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    init() { WatchPhotoTransfer.shared.start() }

    var body: some Scene {
        // Observe the selection so the locale refreshes when the language changes.
        let code = AppLanguage.resolvedSavedCode(languageCode, preferences: Locale.preferredLanguages)
        return WindowGroup {
            WatchWelcomeView()
                .environment(\.locale, Locale(identifier: code))
                .typesettingLanguage(.explicit(Locale.Language(identifier: code)))
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
