//
//  Paint_All_the_Time__Watch_App.swift
//  Paint All the Time (Watch) Watch App
//
//  Created by Denis Kolchev on 19.09.2026.
//

import SwiftUI

@main
struct Paint_All_the_Time__Watch__Watch_AppApp: App {
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    init() { WatchPhotoTransfer.shared.start() }

    var body: some Scene {
        WindowGroup {
            WatchWelcomeView()
                .environment(\.locale, Locale(identifier: AppLanguage.currentCode))
                .environment(\.layoutDirection,
                             Locale.Language(identifier: AppLanguage.currentCode).characterDirection == .rightToLeft
                             ? .rightToLeft : .leftToRight)
        }
    }
}
