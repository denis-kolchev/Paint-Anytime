import SwiftUI

/// A floating coach card that leaves the exercise's layout unchanged.
struct TutorialLessonView: View {
    @ObservedObject var tutorial: TutorialSession
    let onFinish: () -> Void
    let screenWidth: CGFloat
    @State private var confirmsFinish = false
    @State private var didConfirmFinish = false

    var body: some View {
        TutorialCardLayout {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(completedLessons)/20")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))

                Text(TutorialLesson.compactInstruction(for: tutorial.step))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .fixedSize(horizontal: false, vertical: true)
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

    private var cardShape: TutorialCardShape {
        TutorialCardShape(expandedRadius: screenWidth * 0.09)
    }
}

/// A notification capsule for one instruction line plus progress.
/// Taller cards retain the same corner radius as their content grows.
private struct TutorialCardShape: Shape {
    let expandedRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = rect.height <= TutorialCardLayout.compactHeight
            ? rect.height / 2 : expandedRadius
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

private struct TutorialCardLayout: Layout {
    // Allow one instruction line plus progress and padding. A second instruction
    // line exceeds this height and uses the fixed-radius rectangular shape.
    static let compactHeight: CGFloat = 52
    private let buttonDiameter: CGFloat = 32
    private let textInset: CGFloat = 18
    private let buttonInset: CGFloat = 8
    private let spacing: CGFloat = 8
    private let verticalInset: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 180
        guard subviews.count == 2 else { return CGSize(width: width, height: 0) }
        let textHeight = subviews[0].sizeThatFits(
            ProposedViewSize(width: textWidth(for: width), height: nil)
        ).height
        return CGSize(width: width, height: max(buttonDiameter + buttonInset * 2,
                                               textHeight + verticalInset * 2))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX + textInset, y: bounds.midY),
                          anchor: .leading,
                          proposal: ProposedViewSize(width: textWidth(for: bounds.width), height: nil))
        subviews[1].place(at: CGPoint(x: bounds.maxX - buttonInset - buttonDiameter / 2,
                                     y: bounds.midY),
                          anchor: .center,
                          proposal: ProposedViewSize(width: buttonDiameter, height: buttonDiameter))
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(1, width - textInset - spacing - buttonDiameter - buttonInset)
    }
}
