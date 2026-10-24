import SwiftUI

@main
struct PaintAnytimeiPhoneApp: App {
    @StateObject private var photoInbox = WatchPhotoInbox.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneHomeView(photoInbox: photoInbox)
                .task { photoInbox.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { photoInbox.refresh(); photoInbox.synchronize() }
                }
        }
    }
}
