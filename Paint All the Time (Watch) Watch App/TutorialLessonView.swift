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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(completedLessons)/20")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))

                TutorialInstructionText(
                    text: TutorialLesson.compactInstruction(for: tutorial.step),
                    isPaused: confirmsFinish
                )
                .id(tutorial.step)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(height: screenHeight * 0.32)
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

    // Reserve the same share of the display for every lesson, including on SE.
    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: screenWidth * 0.09, style: .continuous)
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
