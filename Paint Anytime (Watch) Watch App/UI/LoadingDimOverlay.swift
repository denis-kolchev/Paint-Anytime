import SwiftUI

/// Dimmed backdrop with a white spinner. Shared by opening a gallery drawing
/// and by explicit Save so both loading states look identical.
struct LoadingDimOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            ProgressView().tint(.white)
        }
        .contentShape(Rectangle())
    }
}
