import SwiftUI
import WatchKit

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
    func watchToolbarButtonStyle(diameter: CGFloat = 32, usesCanvasMaterial: Bool = false, hidesNativeChrome: Bool = false) -> some View {
        modifier(WatchToolbarButtonModifier(diameter: diameter, usesCanvasMaterial: usesCanvasMaterial, hidesNativeChrome: hidesNativeChrome))
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
    let hidesNativeChrome: Bool

    func body(content: Content) -> some View {
        if #available(watchOS 27, *), !usesCanvasMaterial {
            if hidesNativeChrome {
                // Opacity alone leaves the toolbar-owned background visible.
                // Keep the same slot size for the clock, without native chrome;
                // the caller hides content and disables interaction separately.
                sizedButton(content)
            } else {
                // Match native toolbar chrome (including the sheet's close button).
                // Do not layer a standalone glassEffect over the system button:
                // the toolbar owns the material, edge treatment and shadow here.
                content
                    .buttonStyle(.automatic)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
            }
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
        content.modifier(TutorialAttentionMotion(isActive: isActive))
    }
}

/// Keep the label and its toolbar host alive on watchOS 10 as well.
struct TutorialAttentionMotion: ViewModifier {
    let isActive: Bool
    var rotates = false
    @State private var emphasized = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && emphasized ? 1.15 : 1)
            .offset(y: isActive && emphasized && !rotates ? -3 : 0)
            .rotationEffect(.degrees(isActive && emphasized && rotates ? 30 : 0))
            .task(id: isActive) {
                emphasized = false
                guard isActive else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(900))
                        try Task.checkCancellation()
                        withAnimation(.easeOut(duration: 0.25)) { emphasized = true }
                        try await Task.sleep(for: .milliseconds(250))
                        try Task.checkCancellation()
                        withAnimation(.easeInOut(duration: 0.3)) { emphasized = false }
                    }
                } catch {
                    emphasized = false
                }
            }
    }
}

/// A tutorial-owned overlay remains visible independently of the system Crown indicator.
struct TutorialCrownHint: ViewModifier {
    @ObservedObject var tutorial: TutorialSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealed = false

    private var eligible: Bool {
        tutorial.showsCrownHint && !tutorial.remindersPaused
            && scenePhase == .active
    }

    private struct Request: Equatable {
        var eligible: Bool
        var step: TutorialStep
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { screen in
                    if eligible && revealed {
                        TutorialCrownMotion(subtle: tutorial.crownHintIsSubtle)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.8), in: Capsule())
                            .position(TutorialCrownPlacement.position(
                                screenBounds: WKInterfaceDevice.current().screenBounds,
                                overlayFrame: screen.frame(in: .global),
                                crownOnLeft: WKInterfaceDevice.current().crownOrientation == .left
                            ))
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .task(id: Request(eligible: eligible, step: tutorial.step)) {
                revealed = false
                guard eligible else { return }
                do {
                    try await Task.sleep(for: .milliseconds(550))
                    try Task.checkCancellation()
                    revealed = true
                } catch {}
            }
    }
}

private struct TutorialCrownMotion: View {
    var subtle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let cycle = subtle ? 3.5 : 2.8
            let time = max(0, timeline.date.timeIntervalSince(startedAt))
                .truncatingRemainder(dividingBy: cycle)
            let turningUp = !reduceMotion && time < 0.85
            let turningDown = !reduceMotion && time >= 1 && time < 1.85
            let travel = reduceMotion ? 0 : time < 0.85 ? time / 0.85
                : time < 1 ? 1 : time < 1.85 ? 1 - (time - 1) / 0.85 : 0

            VStack(spacing: 2) {
                Image(systemName: "chevron.up")
                    .opacity(reduceMotion || turningUp ? 1 : 0.3)
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.45), .white.opacity(0.15)],
                                             startPoint: .top, endPoint: .bottom))
                    // Project ribs around a cylinder. They emerge at one edge,
                    // cross its face, and disappear around the other edge.
                    Canvas { context, size in
                        for rib in 0..<10 {
                            let angle = Double(rib) * .pi / 5 - travel * .pi * 1.2
                            let depth = cos(angle)
                            guard depth > 0 else { continue }
                            let y = size.height / 2 + sin(angle) * (size.height / 2 - 1)
                            var line = Path()
                            line.move(to: CGPoint(x: 2, y: y))
                            line.addLine(to: CGPoint(x: size.width - 2, y: y))
                            context.stroke(line, with: .color(.white.opacity(0.3 + 0.7 * depth)),
                                           lineWidth: 0.7 + 0.5 * depth)
                        }
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                }
                .frame(width: 13, height: 18)
                Image(systemName: "chevron.down")
                    .opacity(reduceMotion || turningDown ? 1 : 0.3)
            }
            .font(.system(size: 8, weight: .bold))
        }
        .frame(width: 20, height: 38)
        .opacity(subtle ? 0.75 : 1)
    }
}
