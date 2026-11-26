import SwiftUI

/// Attach custom Crown behavior to the native scroller itself while it owns
/// interaction. The presentation host takes over only while that grid is hidden.
struct GalleryCrownInput: ViewModifier {
    enum Target: Hashable { case grid, presentation }

    let target: Target
    let enabled: Bool
    let focus: FocusState<Target?>.Binding
    let position: Binding<Double>
    let onChange: (DigitalCrownEvent) -> Void
    let onIdle: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focused(focus, equals: target)
            .digitalCrownRotation(position, from: -1000, through: 1000,
                                  sensitivity: .low, isContinuous: false,
                                  isHapticFeedbackEnabled: false,
                                  onChange: onChange, onIdle: onIdle)
    }
}
