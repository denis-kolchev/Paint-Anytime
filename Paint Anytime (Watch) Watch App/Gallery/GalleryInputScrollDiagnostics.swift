import SwiftUI

extension View {
    @ViewBuilder
    func galleryInputScrollDiagnostics() -> some View {
        #if DEBUG
        if #available(watchOS 11.0, *), GalleryDebug.isEnabled {
            onScrollPhaseChange { _, phase in
                let label: String
                switch phase {
                case .idle: label = "idle"
                case .tracking: label = "tracking"
                case .interacting: label = "drag"
                case .decelerating: label = "inertia"
                case .animating: label = "animation"
                @unknown default: label = "unknown"
                }
                WatchGalleryDiagnostics.shared.scrollPhase = label
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
