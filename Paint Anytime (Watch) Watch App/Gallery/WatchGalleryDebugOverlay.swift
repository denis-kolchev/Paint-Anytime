#if DEBUG
import SwiftUI

/// Poll isolated diagnostic state; never invalidate the gallery for a label tick.
struct WatchGalleryDebugOverlay: View {
    let snapshot: () -> String
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = "Input —"

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize(horizontal: true, vertical: true)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: scenePhase) {
                guard scenePhase == .active, GalleryDebug.isEnabled else { return }
                while !Task.isCancelled {
                    text = snapshot()
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
    }
}
#endif
