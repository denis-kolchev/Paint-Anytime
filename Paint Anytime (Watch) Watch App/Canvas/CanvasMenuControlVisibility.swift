import SwiftUI

/// Retain toolbar slots while fading every canvas control behind the menu.
struct CanvasMenuControlVisibility: ViewModifier {
    let isHidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isHidden ? 0 : 1)
            .animation(.easeInOut(duration: reduceMotion ? 0.1 : 0.22), value: isHidden)
            .allowsHitTesting(!isHidden)
            .accessibilityHidden(isHidden)
    }
}
