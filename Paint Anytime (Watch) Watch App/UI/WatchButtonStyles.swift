import SwiftUI
import WatchKit

/// Answers a tap on Undo, Redo or Clear while it has nothing to do. Firmer than the
/// `.click` of canvas snapping, so a refused tap does not read as a successful one.
enum UnavailableActionFeedback {
    static func play() { WKInterfaceDevice.current().play(.retry) }
}

private struct CanvasActionUnavailableKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The Button looks disabled but stays enabled, so its action can play
    /// `UnavailableActionFeedback`; a disabled Button never receives the tap.
    var isCanvasActionUnavailable: Bool {
        get { self[CanvasActionUnavailableKey.self] }
        set { self[CanvasActionUnavailableKey.self] = newValue }
    }
}

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

    /// The suggested action of a choice: filled with the view's tint.
    @ViewBuilder
    func watchProminentActionButtonStyle() -> some View {
        if #available(watchOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
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
        if hidesNativeChrome {
            // Morph supplies the visible surface on the canvas. Keep only the
            // toolbar hit target and layout slot on EVERY supported watchOS;
            // another glass/material here covers the overlay's icons.
            sizedButton(content)
        } else if #available(watchOS 27, *), !usesCanvasMaterial {
            // Match native toolbar chrome (including the sheet's close button).
            // The toolbar owns the material, edge treatment and shadow here.
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
/// The zoom lesson of the basic course always opens with a mini watch at the centre of the screen that then
/// flies into the pill beside the physical Crown, so the pill reads as "that wheel".
struct TutorialCrownHint: ViewModifier {
    @ObservedObject var tutorial: TutorialSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var intro = Intro.hidden
    /// Keeps a pause or a return from the background from replaying it within the same lesson.
    @State private var introPlayed = false

    private enum Intro { case hidden, shown, collapsing }

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
                    let crown = TutorialCrownPlacement.position(
                        screenBounds: WKInterfaceDevice.current().screenBounds,
                        overlayFrame: screen.frame(in: .global),
                        crownOnLeft: WKInterfaceDevice.current().crownOrientation == .left
                    )
                    if eligible && intro != .hidden {
                        let collapsing = intro == .collapsing
                        TutorialCrownWatchIntro()
                            // Left-Crown orientation turns the physical case by 180 degrees.
                            .rotationEffect(.degrees(
                                WKInterfaceDevice.current().crownOrientation == .left ? 180 : 0))
                            .scaleEffect(collapsing ? 0.2 : 1)
                            .opacity(collapsing ? 0 : 1)
                            .position(collapsing ? crown
                                      : CGPoint(x: screen.size.width / 2, y: screen.size.height * 0.4))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    if eligible && revealed {
                        TutorialCrownMotion(subtle: tutorial.crownHintIsSubtle)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.8), in: Capsule())
                            .position(crown)
                            .transition(.opacity)
                    }
                }
                // Turning the Crown ends eligibility outside any animation; fade the
                // pill and the mini watch out instead of cutting them off.
                .animation(.easeOut(duration: reduceMotion ? 0.2 : 0.4), value: eligible)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .task(id: Request(eligible: eligible, step: tutorial.step)) {
                // A step change that keeps the hint eligible also fades it, rather than blinking.
                withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.4)) {
                    revealed = false
                    intro = .hidden
                }
                let introLesson = tutorial.chapter == .basic && tutorial.step == .zoomCanvas
                if !introLesson { introPlayed = false }
                guard eligible else { return }
                do {
                    try await Task.sleep(for: .milliseconds(550))
                    try Task.checkCancellation()
                    if introLesson && !introPlayed {
                        introPlayed = true
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3)) {
                            intro = .shown
                        }
                        try await Task.sleep(for: .milliseconds(4500))
                        try Task.checkCancellation()
                        withAnimation(.easeIn(duration: reduceMotion ? 0.2 : 0.45)) { intro = .collapsing }
                        try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 400))
                        try Task.checkCancellation()
                        intro = .hidden
                        withAnimation(.easeOut(duration: 0.2)) { revealed = true }
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) { revealed = true }
                    }
                } catch {
                    intro = .hidden
                }
            }
    }
}

private struct TutorialCrownMotion: View {
    var subtle: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let turn = TutorialCrownTurn.phase(at: timeline.date.timeIntervalSince(startedAt),
                                               cycle: subtle ? 3.5 : 2.8, still: reduceMotion)
            VStack(spacing: 2) {
                Image(systemName: "chevron.up")
                    .opacity(reduceMotion || turn.turningUp ? 1 : 0.3)
                TutorialCrownCylinder(travel: turn.travel)
                    .frame(width: 13, height: 18)
                Image(systemName: "chevron.down")
                    .opacity(reduceMotion || turn.turningDown ? 1 : 0.3)
            }
            .font(.system(size: 8, weight: .bold))
        }
        .frame(width: 20, height: 38)
        .opacity(subtle ? 0.75 : 1)
    }
}
