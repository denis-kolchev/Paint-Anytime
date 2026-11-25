import SwiftUI

@main
struct PaintAnytimeiPhoneApp: App {
    @StateObject private var photoInbox = WatchPhotoInbox.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Written when the watch shares its language; until then the system language applies.
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.defaultCode

    var body: some Scene {
        let code = AppLanguage.resolvedSavedCode(languageCode, preferences: Locale.preferredLanguages)
        let language = Locale.Language(identifier: code)
        return WindowGroup {
            PhoneHomeView(photoInbox: photoInbox)
                .modifier(SketchAssistSheet(assist: PhoneSketchAssist.shared))
                .environment(\.locale, Locale(identifier: code))
                .typesettingLanguage(.explicit(language))
                .environment(\.layoutDirection, language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .task { photoInbox.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        photoInbox.refresh(); photoInbox.synchronize()
                        PhoneSketchAssist.shared.publishAvailability()
                        PhoneSketchAssist.shared.reportProgressIfOnScreen()
                    }
                }
        }
    }
}
