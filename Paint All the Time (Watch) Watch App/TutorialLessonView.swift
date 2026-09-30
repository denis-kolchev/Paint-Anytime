import SwiftUI

/// A floating coach card that leaves the exercise's layout unchanged.
struct TutorialLessonView: View {
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void
    let screenWidth: CGFloat
    let screenHeight: CGFloat
    @State private var confirmsFinish = false
    @State private var didConfirmFinish = false

    var body: some View {
        TutorialHintLayout(maximumHeight: screenHeight * 0.32) {
            Text("\(completedLessons)/20")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))

            TutorialInstructionText(
                text: TutorialLesson.compactInstruction(for: tutorial.step),
                isPaused: confirmsFinish
            )
            .id(tutorial.step)

            Button(role: .destructive) {
                tutorial.pauseReminders()
                confirmsFinish = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .watchToolbarButtonStyle()
            .accessibilityLabel("Finish tutorial")

            // Measure the full copy independently of the scroll viewport.
            Text(TutorialLesson.compactInstruction(for: tutorial.step))
                .font(.system(size: 12, weight: .medium))
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
        .fullScreenCover(isPresented: $confirmsFinish, onDismiss: {
            if didConfirmFinish {
                didConfirmFinish = false
                tutorial.stop()
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

    private var completedLessons: Int {
        tutorial.step == .finished ? 20 : max(0, tutorial.step.rawValue - 1)
    }

    private let edgeGap: CGFloat = 10

    private var cardShape: TutorialHintShape {
        TutorialHintShape(expandedRadius: screenWidth * 0.09)
    }
}

private struct TutorialHintShape: Shape {
    let expandedRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Progress and one instruction line use the original notification capsule.
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
    private let textSpacing: CGFloat = 3

    private func textWidth(_ width: CGFloat) -> CGFloat {
        max(1, width - leadingInset - trailingInset - buttonDiameter - buttonSpacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 180
        guard subviews.count == 4 else { return CGSize(width: width, height: 0) }
        let textProposal = ProposedViewSize(width: textWidth(width), height: nil)
        let textHeight = subviews[0].sizeThatFits(textProposal).height + textSpacing
            + subviews[3].sizeThatFits(textProposal).height
        let naturalHeight = max(buttonDiameter + trailingInset * 2,
                                textHeight + verticalInset * 2)
        return CGSize(width: width, height: min(naturalHeight, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let width = textWidth(bounds.width)
        let textProposal = ProposedViewSize(width: width, height: nil)
        let progressHeight = subviews[0].sizeThatFits(textProposal).height
        let instructionHeight = min(subviews[3].sizeThatFits(textProposal).height,
                                    max(1, bounds.height - verticalInset * 2 - progressHeight - textSpacing))
        let top = bounds.midY - (progressHeight + textSpacing + instructionHeight) / 2
        subviews[0].place(at: CGPoint(x: bounds.minX + leadingInset, y: top),
                          anchor: .topLeading, proposal: textProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX + leadingInset, y: top + progressHeight + textSpacing),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: instructionHeight))
        subviews[2].place(at: CGPoint(x: bounds.maxX - trailingInset - buttonDiameter / 2, y: bounds.midY),
                          anchor: .center,
                          proposal: ProposedViewSize(width: buttonDiameter, height: buttonDiameter))
        subviews[3].place(at: bounds.origin, anchor: .topLeading, proposal: textProposal)
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
                        .font(.system(size: 12, weight: .medium))
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
