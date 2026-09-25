import SwiftUI

extension View {
    /// Apply the native primitive style directly so toolbar hosts can recognize it.
    /// Leave sizing, press feedback and material composition to the system.
    @ViewBuilder
    func watchActionButtonStyle() -> some View {
        if #available(watchOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// All toolbar icons, including Information, use one explicit circle size.
    func watchToolbarButtonStyle() -> some View {
        modifier(WatchToolbarButtonModifier())
    }
}

private struct WatchToolbarButtonModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    // The reference is the SMALL Information button after returning from Width,
    // not its oversized initial presentation. Keep every canvas button at this
    // same compact diameter. Do not rely on controlSize: toolbar hosts can
    // resolve it differently when a conditional item is first inserted.
    private let diameter: CGFloat = 32

    func body(content: Content) -> some View {
        if #available(watchOS 27, *) {
            // Match native toolbar chrome (including the sheet's close button).
            // Do not layer a standalone glassEffect over the system button:
            // the toolbar owns the material, edge treatment and shadow here.
            content
                .buttonStyle(.automatic)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        } else if #available(watchOS 26, *) {
            sizedButton(content)
                // Apply material AFTER the fixed frame: no GlassButtonStyle
                // padding or host-dependent intrinsic diameter around the label.
                .glassEffect(.regular.interactive(isEnabled), in: Circle())
                .environment(\.colorScheme, .dark)
        } else {
            sizedButton(content)
                // Older borderless toolbar buttons inherit the app accent for
                // SF Symbols. Use white to match the custom canvas icons.
                .tint(.white)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func sizedButton(_ content: Content) -> some View {
        content
            // Preserve native Button activation, cancellation and disabled feedback.
            .buttonStyle(.borderless)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
    }
}
