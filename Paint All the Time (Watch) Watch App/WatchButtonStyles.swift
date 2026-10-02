import SwiftUI

/// Tutorial overlays do not have a native toolbar host to supply a hit target.
/// Size the label inside ButtonStyle so the whole circle activates the Button;
/// an outer frame around a borderless Button only sizes its layout container.
struct TutorialOverlayButtonStyle: ButtonStyle {
    var diameter: CGFloat = 32
    var hitDiameter: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        decoratedLabel(configuration.label)
            .frame(width: hitDiameter, height: hitDiameter)
            .contentShape(Circle())
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.6 : 1)
    }

    @ViewBuilder private func decoratedLabel(_ label: Configuration.Label) -> some View {
        if #available(watchOS 26, *) {
            label
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular, in: Circle())
                .environment(\.colorScheme, .dark)
        } else {
            label
                .frame(width: diameter, height: diameter)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

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
    func watchToolbarButtonStyle(diameter: CGFloat = 32, usesCanvasMaterial: Bool = false) -> some View {
        modifier(WatchToolbarButtonModifier(diameter: diameter, usesCanvasMaterial: usesCanvasMaterial))
    }
}

private struct WatchToolbarButtonModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    // The reference is the SMALL Information button after returning from Width,
    // not its oversized initial presentation. Keep every canvas button at this
    // same compact diameter. Do not rely on controlSize: toolbar hosts can
    // resolve it differently when a conditional item is first inserted.
    let diameter: CGFloat
    let usesCanvasMaterial: Bool

    func body(content: Content) -> some View {
        if #available(watchOS 27, *), !usesCanvasMaterial {
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

extension View {
    /// Apply to the label so native button chrome and hit targets stay unchanged.
    func tutorialHint(_ tutorial: TutorialSession, steps: Set<TutorialStep>, isSuggested: Bool = true) -> some View {
        modifier(TutorialButtonHint(tutorial: tutorial, steps: steps, isSuggested: isSuggested))
    }
}

private struct TutorialButtonHint: ViewModifier {
    @ObservedObject var tutorial: TutorialSession
    let steps: Set<TutorialStep>
    let isSuggested: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    private var isActive: Bool {
        isSuggested && tutorial.isActive && tutorial.permits(steps) && !tutorial.remindersPaused
            && isEnabled && !reduceMotion && scenePhase == .active
    }

    func body(content: Content) -> some View {
        if #available(watchOS 11, *) {
            content.phaseAnimator(isActive ? [false, true] : [false]) { label, emphasized in
                label
                    .scaleEffect(emphasized ? 1.2 : 1)
                    .brightness(emphasized ? 0.2 : 0)
                    .opacity(isActive && !emphasized ? 0.65 : 1)
                    .offset(y: emphasized ? -2 : 0)
            } animation: { emphasized in
                .easeInOut(duration: 0.35).delay(emphasized ? 0.7 : 0)
            }
        } else {
            // A static emphasis avoids a repeating phase animator inside the
            // watchOS 10 toolbar while its action changes the tutorial lesson.
            content.brightness(isActive ? 0.2 : 0)
        }
    }
}
