#if DEBUG
import SwiftUI

/// Sample animation state in this label, without subscribing the gallery body
/// to every presentation tick. The overlay never intercepts gallery gestures.
struct PhoneGalleryGeometryDebugOverlay: View {
    let snapshot: () -> String
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = "Geometry —"

    var body: some View {
        Text(verbatim: text)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    text = snapshot()
                    do { try await Task.sleep(for: .milliseconds(200)) }
                    catch { return }
                }
            }
    }
}
#endif
