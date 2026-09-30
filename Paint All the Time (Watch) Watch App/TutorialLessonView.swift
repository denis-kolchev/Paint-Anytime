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

                ScrollView(.vertical) {
                    Text(TutorialLesson.compactInstruction(for: tutorial.step))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Keep the Crown available for the current drawing exercise.
                .focusable(false)
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
