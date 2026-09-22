import SwiftUI

@main
struct PaintAnytimeiPhoneApp: App {
    @StateObject private var photoInbox = WatchPhotoInbox.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { WatchPhotoInbox.shared.start() }

    var body: some Scene {
        WindowGroup {
            PhoneHomeView(photoInbox: photoInbox)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { photoInbox.refresh() }
                }
        }
    }
}
