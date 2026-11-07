//
//  PaintAnytimeWatchApp.swift
//  Paint Anytime (Watch) Watch App
//
//  Created by Denis Kolchev on 19.09.2026.
//

import SwiftUI

@main
struct PaintAnytimeWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    init() {
        #if targetEnvironment(simulator)
        SimulatorGallerySeed.installIfNeeded()
        #endif
        WatchPhotoTransfer.shared.start()
        // Remove the retired activity history and publish existing gallery previews.
        for defaults in [UserDefaults.standard, UserDefaults(suiteName: GalleryWidgetStore.groupID)] {
            for key in ["drawing.activity.v1", "drawing.activity.dates.v2", "drawing.activity.pending.v2"] {
                defaults?.removeObject(forKey: key)
            }
        }
        CanvasControlLayout.migrateEverythingAtHand()
        try? CanvasExportStore.refreshWidgets()
    }

    var body: some Scene {
        // Observe the selection so the locale refreshes when the language changes.
        let code = AppLanguage.resolvedSavedCode(languageCode, preferences: Locale.preferredLanguages)
        return WindowGroup {
            WatchWelcomeView()
                .environment(\.locale, Locale(identifier: code))
                .typesettingLanguage(.explicit(Locale.Language(identifier: code)))
                .environment(\.layoutDirection, .leftToRight)
                // Debug only: the outermost touch probe, above navigation and the native
                // toolbar. Counts touches the canvas screen probe ("root") never sees.
                .modifier(RenderTouchProbe(isEnabled: RenderDebug.isEnabled && RenderDebugSettings.shared.showsHUD,
                    began: { RenderDiagnostics.appTouch(ended: false, location: $0) },
                    ended: { RenderDiagnostics.appTouch(ended: true, location: .zero) }))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { try? CanvasExportStore.refreshWidgets() }
                }
        }
    }
}
