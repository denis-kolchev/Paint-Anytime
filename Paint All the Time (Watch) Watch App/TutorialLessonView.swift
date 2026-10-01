import SwiftUI
import WatchKit

/// A floating coach card that leaves the exercise's layout unchanged.
struct TutorialLessonView: View {
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void
    let screenWidth: CGFloat
    let screenHeight: CGFloat
    @State private var confirmsFinish = false
    @State private var didConfirmFinish = false
    @State private var greenDotCount = 0
    @State private var showsCompletionCheckmark = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TutorialHintLayout(maximumHeight: screenHeight * 0.32) {
            TutorialInstructionText(
                text: tutorial.instruction,
                isPaused: confirmsFinish
            )
            .id(tutorial.step)

            Button(role: showsCompletionCheckmark ? nil : .destructive) {
                if showsCompletionCheckmark {
                    onFinish()
                } else {
                    tutorial.pauseReminders()
                    confirmsFinish = true
                }
            } label: {
                ZStack {
                    Image(systemName: "xmark")
                        .foregroundStyle(.red)
                        .opacity(showsCompletionCheckmark ? 0 : 1)
                        .scaleEffect(showsCompletionCheckmark && !reduceMotion ? 0.6 : 1)
                    // Completion uses the neutral tint of the other toolbar controls.
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .opacity(showsCompletionCheckmark ? 1 : 0)
                        .scaleEffect(showsCompletionCheckmark || reduceMotion ? 1 : 0.6)
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .tint(showsCompletionCheckmark ? .white : .red)
            .watchToolbarButtonStyle(diameter: 24)
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .overlay {
                TutorialProgressDots(completedLessons: completedLessons, greenDotCount: greenDotCount)
                    .frame(width: 32, height: 32)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Finish tutorial")
            .accessibilityValue("\(completedLessons) of \(TutorialStep.lessonCount) lessons completed")

            // Measure the full copy independently of the scroll viewport.
            Text(tutorial.instruction)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)
        }
        .background(.regularMaterial, in: cardShape)
        .overlay {
            cardShape.stroke(.white.opacity(0.16), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .padding(edgeGap)
        .task(id: tutorial.step) {
            await animateCompletion()
        }
        .onChange(of: showsCompletionCheckmark) { _, isShowing in
            if isShowing {
                WKInterfaceDevice.current().play(.success)
            }
        }
        .fullScreenCover(isPresented: $confirmsFinish, onDismiss: {
            if didConfirmFinish {
                didConfirmFinish = false
                onFinish()
            } else {
                tutorial.resumeReminders()
            }
        }) {
            DestructiveConfirmationView(
                title: "Finish the tutorial?",
                confirmTitle: "Yes",
                cancelTitle: "No"
            ) {
                confirmsFinish = false
            } onConfirm: {
                didConfirmFinish = true
                confirmsFinish = false
            }
        }
    }

    @MainActor
    private func animateCompletion() async {
        guard tutorial.step == .finished else {
            greenDotCount = 0
            showsCompletionCheckmark = false
            return
        }
        guard !showsCompletionCheckmark else { return }
        if reduceMotion {
            greenDotCount = TutorialStep.lessonCount
            showsCompletionCheckmark = true
            return
        }
        do {
            // Start at twelve o'clock and sweep clockwise in about 0.7 seconds.
            // Retain progress if the view's task is interrupted and resumed.
            while greenDotCount < TutorialStep.lessonCount {
                try await Task.sleep(for: .milliseconds(35))
                try Task.checkCancellation()
                greenDotCount += 1
            }
            // Let the last dot finish lighting before replacing the cross.
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            withAnimation(.easeInOut(duration: 0.2)) {
                showsCompletionCheckmark = true
            }
        } catch {
            // Leaving the card or changing lessons cancels the sequence.
        }
    }

    private var completedLessons: Int {
        tutorial.step == .finished ? TutorialStep.lessonCount : max(0, tutorial.step.rawValue - 1)
    }

    private let edgeGap: CGFloat = 10

    private var cardShape: TutorialHintShape {
        TutorialHintShape(expandedRadius: screenWidth * 0.09)
    }
}

private struct TutorialProgressDots: View {
    let completedLessons: Int
    let greenDotCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let radius = min(size.width, size.height) / 2 - 2
            ZStack {
                ForEach(0..<TutorialStep.lessonCount) { index in
                    let angle = Double(index) * .pi * 2 / Double(TutorialStep.lessonCount) - .pi / 2
                    Circle()
                        .fill(Color(white: index < completedLessons ? 0.8 : 0.3))
                        .overlay {
                            Circle()
                                .fill(.green)
                                .opacity(index < greenDotCount ? 1 : 0)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.1),
                                           value: index < greenDotCount)
                        }
                        .frame(width: 2.5, height: 2.5)
                        .position(x: size.width / 2 + CGFloat(cos(angle)) * radius,
                                  y: size.height / 2 + CGFloat(sin(angle)) * radius)
                }
            }
        }
    }
}

private struct TutorialHintShape: Shape {
    let expandedRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Short instructions use the original notification capsule.
        let radius = rect.height <= 52 ? rect.height / 2 : expandedRadius
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

/// Shrink to the actual text; only overflowing lessons use the full height budget.
private struct TutorialHintLayout: Layout {
    let maximumHeight: CGFloat
    private let leadingInset: CGFloat = 18
    private let trailingInset: CGFloat = 8
    private let verticalInset: CGFloat = 10
    private let buttonDiameter: CGFloat = 32
    private let buttonSpacing: CGFloat = 8

    private func textWidth(_ width: CGFloat) -> CGFloat {
        max(1, width - leadingInset - trailingInset - buttonDiameter - buttonSpacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 180
        guard subviews.count == 3 else { return CGSize(width: width, height: 0) }
        let textProposal = ProposedViewSize(width: textWidth(width), height: nil)
        let textHeight = subviews[2].sizeThatFits(textProposal).height
        let naturalHeight = max(buttonDiameter + trailingInset * 2,
                                textHeight + verticalInset * 2)
        return CGSize(width: width, height: min(naturalHeight, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = textWidth(bounds.width)
        let textProposal = ProposedViewSize(width: width, height: nil)
        let instructionHeight = min(subviews[2].sizeThatFits(textProposal).height,
                                    max(1, bounds.height - verticalInset * 2))
        let top = bounds.midY - instructionHeight / 2
        subviews[0].place(at: CGPoint(x: bounds.minX + leadingInset, y: top),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: instructionHeight))
        subviews[1].place(at: CGPoint(x: bounds.maxX - trailingInset - buttonDiameter / 2, y: bounds.midY),
                          anchor: .center,
                          proposal: ProposedViewSize(width: buttonDiameter, height: buttonDiameter))
        subviews[2].place(at: bounds.origin, anchor: .topLeading, proposal: textProposal)
    }
}

/// Scroll overflowing copy at reading speed without taking Crown focus.
private struct TutorialInstructionText: View {
    let text: String
    let isPaused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var contentHeight: CGFloat = 0
    @State private var isManualScrolling = false

    private struct Playback: Equatable {
        let overflow: CGFloat
        let isEnabled: Bool
    }

    var body: some View {
        GeometryReader { viewport in
            let playback = Playback(
                overflow: max(0, contentHeight - viewport.size.height),
                isEnabled: !isPaused && scenePhase == .active && !reduceMotion
                    && !voiceOverEnabled && !isManualScrolling
            )
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: TutorialInstructionHeight.self,
                                                       value: content.size.height)
                            }
                        }
                        .id("instruction")
                }
                .scrollBounceBehavior(.basedOnSize)
                .modifier(TutorialScrollEdgeModifier())
                .clipped()
                .focusable(false)
                .onPreferenceChange(TutorialInstructionHeight.self) { contentHeight = $0 }
                .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in
                    // Let the reader control this lesson after a manual swipe.
                    isManualScrolling = true
                })
                .task(id: playback) {
                    guard playback.isEnabled, playback.overflow > 1 else { return }
                    let duration = max(3, Double(playback.overflow) / 8)
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(1.5))
                            withAnimation(.linear(duration: duration)) {
                                proxy.scrollTo("instruction", anchor: .bottom)
                            }
                            try await Task.sleep(for: .seconds(duration))
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo("instruction", anchor: .top)
                            }
                        }
                    } catch {
                        // Disappearance, a new lesson or manual scrolling cancels playback.
                    }
                }
            }
        }
    }
}

/// The instruction viewport supplies its own boundary inside the material card.
private struct TutorialScrollEdgeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 26, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

private struct TutorialInstructionHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Reserve space for controls without resizing the canvas or its artwork.
private struct TutorialHintReservedHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var tutorialHintReservedHeight: CGFloat {
        get { self[TutorialHintReservedHeightKey.self] }
        set { self[TutorialHintReservedHeightKey.self] = newValue }
    }
}
